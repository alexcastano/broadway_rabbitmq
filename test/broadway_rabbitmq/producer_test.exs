defmodule BroadwayRabbitMQ.ProducerTest do
  use ExUnit.Case

  import ExUnit.CaptureLog
  import ExUnit.CaptureIO

  alias Broadway.Message
  alias BroadwayRabbitMQ.Producer

  defmodule FakeChannel do
    use GenServer

    def new(test_pid) do
      fake_connection_pid = spawn(fn -> Process.sleep(:infinity) end)
      true = Process.link(fake_connection_pid)
      {:ok, fake_channel_pid} = GenServer.start(__MODULE__, fake_connection_pid)

      %{
        pid: fake_channel_pid,
        conn: %{pid: fake_connection_pid, test_pid: test_pid},
        test_pid: test_pid
      }
    end

    def init(fake_connection_pid) do
      Process.link(fake_connection_pid)
      {:ok, :no_state}
    end

    def handle_call(:fake_basic_ack, _from, state) do
      {:reply, :ok, state}
    end
  end

  defmodule FakeRabbitmqClient do
    @behaviour BroadwayRabbitMQ.RabbitmqClient

    @impl true
    def init(opts) do
      send(opts[:test_pid], :init_called)
      {:ok, opts}
    end

    @impl true
    def setup_channel(config) do
      test_pid = config[:test_pid]

      status =
        Agent.get_and_update(config[:connection_agent], fn
          [status | rest] ->
            {status, rest}

          _ ->
            {:ok, []}
        end)

      if status == :ok do
        channel = FakeChannel.new(test_pid)
        send(test_pid, {:setup_channel, :ok, channel})
        {:ok, channel}
      else
        send(test_pid, {:setup_channel, :error, nil})
        {:error, status}
      end
    end

    @impl true
    def ack(channel, delivery_tag) do
      GenServer.call(channel.pid, :fake_basic_ack)
      send(channel.test_pid, {:ack, delivery_tag})
      :ok
    end

    @impl true
    def reject(channel, delivery_tag, opts) do
      GenServer.call(channel.pid, :fake_basic_ack)
      send(channel.test_pid, {:reject, delivery_tag, opts})
      :ok
    end

    @impl true
    def consume(_channel, _config) do
      send(self(), {:basic_consume_ok, %{consumer_tag: :fake_consumer_tag}})
      :fake_consumer_tag
    end

    @impl true
    def cancel(_channel, :fake_consumer_tag_closing) do
      {:error, :closing}
    end

    @impl true
    def cancel(%{test_pid: test_pid}, consumer_tag) do
      send(test_pid, {:cancel, consumer_tag})
      {:ok, consumer_tag}
    end

    @impl true
    def close_connection(%{test_pid: test_pid}) do
      send(test_pid, :connection_closed)
      :ok
    end
  end

  defmodule FlakyRabbitmqClient do
    @behaviour BroadwayRabbitMQ.RabbitmqClient

    @impl true
    def init(opts) do
      send(opts[:test_pid], :init_called)
      {:ok, opts}
    end

    @impl true
    def setup_channel(config) do
      test_pid = config[:test_pid]

      status =
        Agent.get_and_update(config[:connection_agent], fn
          [status | rest] ->
            {status, rest}

          _ ->
            {:ok, []}
        end)

      if status == :ok do
        channel = FakeChannel.new(test_pid)
        send(test_pid, {:setup_channel, :ok, channel})
        {:ok, channel}
      else
        send(test_pid, {:setup_channel, :error, nil})
        {:error, :econnrefused}
      end
    end

    @impl true
    def ack(_channel, :error_tuple) do
      {:error, "Cannot acknowledge, error returned from amqp"}
    end

    @impl true
    def ack(_channel, delivery_tag) do
      raise "cannot acknowledge with delivery tag: #{inspect(delivery_tag)}"
    end

    @impl true
    def reject(channel, delivery_tag, opts) do
      GenServer.call(channel.pid, :fake_basic_ack)
      send(channel.test_pid, {:reject, delivery_tag, opts})
    end

    @impl true
    def consume(_channel, _config) do
      :fake_consumer_tag
    end

    @impl true
    def cancel(_channel, :fake_consumer_tag_closing) do
      {:error, :closing}
    end

    @impl true
    def cancel(%{test_pid: test_pid}, consumer_tag) do
      send(test_pid, {:cancel, consumer_tag})
      {:ok, consumer_tag}
    end

    @impl true
    def close_connection(%{test_pid: test_pid}) do
      send(test_pid, :connection_closed)
      :ok
    end
  end

  defmodule Forwarder do
    use Broadway

    def handle_message(_, message, %{test_pid: test_pid}) do
      channel = get_channel(message)
      send(test_pid, {:message_handled, message, channel})

      case message.data do
        :fail ->
          Message.failed(message, "failed")

        :break_conn ->
          Process.exit(channel.conn.pid, :shutdown)
          message

        {:configure, options, :fail} ->
          message
          |> Message.configure_ack(options)
          |> Message.failed("failed")

        {:configure, options, _} ->
          Message.configure_ack(message, options)

        _ ->
          message
      end
    end

    def handle_batch(_, messages, _, %{test_pid: test_pid}) do
      send(test_pid, {:batch_handled, Enum.map(messages, & &1.data)})
      messages
    end

    defp get_channel(%Message{acknowledger: {_, channel, _}}) do
      channel
    end
  end

  defmodule CustomPool do
    @behaviour BroadwayRabbitMQ.ChannelPool

    @impl true
    def checkout_channel(parent) do
      channel = %AMQP.Channel{pid: spawn(fn -> Process.sleep(:infinity) end)}
      send(parent, {:checkout_channel_called, channel})
      {:ok, channel}
    end

    @impl true
    def checkin_channel(parent, %AMQP.Channel{} = channel) do
      send(parent, {:checkin_channel_called, channel})
      Process.exit(channel.pid, :kill)
      :ok
    end
  end

  test "raise an ArgumentError with proper message when client options are invalid" do
    assert_raise(
      ArgumentError,
      "invalid options given to BroadwayRabbitMQ.AmqpClient.init/1, expected :queue to be a string, got: nil",
      fn ->
        BroadwayRabbitMQ.Producer.init(queue: nil, on_failure: :reject_and_requeue)
      end
    )
  end

  test "raise an ArgumentError with proper message when backoff options are invalid" do
    assert_raise(
      ArgumentError,
      ~r/expected :backoff_type to be one of/,
      fn ->
        BroadwayRabbitMQ.Producer.init(
          queue: "test",
          backoff_type: :unknown_type,
          on_failure: :reject_and_requeue
        )
      end
    )
  end

  test "prints a deprecation warning when :on_failure is not specified" do
    stderr =
      capture_io(:stderr, fn ->
        BroadwayRabbitMQ.Producer.init(queue: "test")
      end)

    assert stderr =~ ":on_failure should be specified"
  end

  test "producer :buffer_size is :prefetch_count * 5" do
    qos = [prefetch_count: 12]

    {:producer, _, options} =
      BroadwayRabbitMQ.Producer.init(queue: "test", qos: qos, on_failure: :reject_and_requeue)

    assert options[:buffer_size] == 60
  end

  test "producer :buffer_size and :buffer_keep can be overridden" do
    {:producer, _, options} =
      BroadwayRabbitMQ.Producer.init(
        queue: "test",
        qos: [prefetch_count: 12],
        buffer_size: 100,
        buffer_keep: :first,
        on_failure: :reject_and_requeue
      )

    assert options[:buffer_size] == 100
    assert options[:buffer_keep] == :first
  end

  test ":prefetch_count set to 0 requires explicit :buffer_size setting" do
    assert_raise ArgumentError, ":prefetch_count is 0, specify :buffer_size explicitly", fn ->
      BroadwayRabbitMQ.Producer.init(
        queue: "test",
        qos: [prefetch_count: 0],
        on_failure: :reject_and_requeue
      )
    end

    {:producer, _, options} =
      BroadwayRabbitMQ.Producer.init(
        queue: "test",
        qos: [prefetch_count: 0],
        buffer_size: 100,
        on_failure: :reject_and_requeue
      )

    assert options[:buffer_size] == 100
  end

  test "retrieve only selected metadata" do
    broadway = start_broadway(metadata: [:routing_key, :content_type])

    deliver_messages(broadway, 1..2,
      extra_metadata: %{
        routing_key: "FAKE_ROTING_KEY",
        headers: "FAKE_HEADERS",
        content_type: "FAKE_CONTENT_TYPE",
        expiration: "FAKE_EXPIRATION"
      }
    )

    assert_receive {:message_handled, %Message{metadata: meta}, _}
    assert map_size(meta) == 3

    assert %{content_type: "FAKE_CONTENT_TYPE", routing_key: "FAKE_ROTING_KEY", amqp_channel: %{}} =
             meta
  end

  test "forward messages delivered by the channel" do
    broadway = start_broadway()

    deliver_messages(broadway, 1..4)

    assert_receive {:batch_handled, [1, 2]}
    assert_receive {:batch_handled, [3, 4]}

    stop_broadway(broadway)
  end

  test "acknowledge/reject processed messages" do
    broadway = start_broadway()

    deliver_messages(broadway, [1, 2, :fail, 4, 5])

    assert_receive {:ack, 1}
    assert_receive {:ack, 2}
    assert_receive {:reject, :fail, _}
    assert_receive {:ack, 4}
    assert_receive {:ack, 5}

    stop_broadway(broadway)
  end

  describe "controlling on_success/on_failure behavior" do
    test "setting on_success/on_failure when starting the producer" do
      broadway = start_broadway(on_success: :reject, on_failure: :ack)

      deliver_messages(broadway, [1, 2, :fail, 4])

      assert_receive {:reject, 1, _}
      assert_receive {:reject, 2, _}
      assert_receive {:ack, :fail}
      assert_receive {:reject, 4, _}
    end

    test "overriding on_success/on_failure through Broadway.Message.configure_ack/2" do
      broadway = start_broadway()

      deliver_messages(broadway, [
        {:configure, [on_success: :reject], 1},
        {:configure, [on_failure: :ack], :fail}
      ])

      assert_receive {:reject, {:configure, _opts, 1}, _}
      assert_receive {:ack, {:configure, _opts, :fail}}
    end

    test "passing unsupported options to Broadway.Message.configure_ack/2" do
      broadway = start_broadway()

      log =
        capture_log(fn ->
          deliver_messages(broadway, [{:configure, [unknown: 1], 1}])

          assert_receive {:reject, {:configure, _opts, 1}, _}
        end)

      assert log =~ "unsupported configure option :unknown"
    end

    test "setting on_success/on_failure to an unsupported value raises an error" do
      broadway = start_broadway()

      log =
        capture_log(fn ->
          deliver_messages(broadway, [{:configure, [on_success: :wat], 1}])

          assert_receive {:reject, {:configure, _opts, 1}, _}
        end)

      assert log =~ "unsupported value for :on_success option: :wat"
    end
  end

  describe "handle requeuing with the :on_success/:on_failure options" do
    test "always requeue messages with :on_failure set to :reject_and_requeue" do
      broadway = start_broadway(on_failure: :reject_and_requeue)

      deliver_messages(broadway, [1, :fail], redelivered: true)
      assert_receive {:reject, :fail, _opts}

      deliver_messages(broadway, [2, :fail], redelivered: false)
      assert_receive {:reject, :fail, _opts}

      refute_receive {:reject, :fail, _}

      stop_broadway(broadway)
    end

    test "never requeue messages with :on_failure set to :reject" do
      broadway = start_broadway(on_failure: :reject)

      deliver_messages(broadway, [1, :fail], redelivered: true)
      assert_receive {:reject, :fail, opts}
      assert opts[:requeue] == false

      deliver_messages(broadway, [2, :fail], redelivered: false)
      assert_receive {:reject, :fail, opts}
      assert opts[:requeue] == false

      refute_receive {:reject, :fail, _}

      stop_broadway(broadway)
    end

    test "requeue messages unless it's been redelivered with :on_failure set to :reject_and_requeue_once" do
      broadway = start_broadway(on_failure: :reject_and_requeue_once)

      deliver_messages(broadway, [1, :fail], redelivered: true)
      assert_receive {:reject, :fail, _opts}

      deliver_messages(broadway, [2, :fail], redelivered: false)
      assert_receive {:reject, :fail, _opts}

      refute_receive {:reject, :fail, _}

      stop_broadway(broadway)
    end
  end

  test "if the :no_ack consume option is true, the acknowledger is set to NoopAcknowledger" do
    broadway = start_broadway(consume_options: [no_ack: true])
    assert_receive {:setup_channel, :ok, _}

    deliver_messages(broadway, [1])

    assert_receive {:message_handled, %Broadway.Message{} = message, _channel}
    assert message.acknowledger == {Broadway.NoopAcknowledger, nil, nil}
  end

  test "handles the :basic_consume_ok message when consuming" do
    broadway = start_broadway()
    assert_receive {:setup_channel, :ok, channel}

    deliver_messages(broadway, [1])
    assert_receive {:message_handled, %Broadway.Message{}, ^channel}
  end

  describe "prepare_for_draining" do
    test "cancel consumer and keep the current state" do
      channel = FakeChannel.new(self())
      tag = :fake_consumer_tag
      state = %{client: FakeRabbitmqClient, channel: channel, consumer_tag: tag}

      assert {:noreply, [], ^state} = BroadwayRabbitMQ.Producer.prepare_for_draining(state)
      assert_received {:cancel, ^tag}
    end

    test "log unsuccessful cancellation and keep the current state" do
      channel = FakeChannel.new(self())
      tag = :fake_consumer_tag_closing
      state = %{client: FakeRabbitmqClient, channel: channel, consumer_tag: tag}

      assert(
        capture_log(fn ->
          assert {:noreply, [], ^state} = BroadwayRabbitMQ.Producer.prepare_for_draining(state)
        end)
      ) =~ "[error] Could not cancel producer while draining. Channel is closing"
    end
  end

  describe "handle connection loss" do
    test "producer is not restarted" do
      broadway = start_broadway()
      assert_receive {:setup_channel, :ok, _}
      producer_1 = get_producer(broadway)

      deliver_messages(broadway, [1, :break_conn])
      assert_receive {:setup_channel, :ok, _}
      producer_2 = get_producer(broadway)

      assert producer_1 == producer_2

      stop_broadway(broadway)
    end

    test "open a new connection/channel and keep consuming messages" do
      broadway = start_broadway()
      assert_receive {:setup_channel, :ok, channel_1}

      deliver_messages(broadway, [1, 2])
      assert_receive {:message_handled, %Message{data: 1}, ^channel_1}
      assert_receive {:message_handled, %Message{data: 2}, ^channel_1}

      deliver_messages(broadway, [:break_conn])
      assert_receive {:setup_channel, :ok, channel_2}

      deliver_messages(broadway, [3, 4])
      assert_receive {:message_handled, %Message{data: 3}, ^channel_2}
      assert_receive {:message_handled, %Message{data: 4}, ^channel_2}

      assert channel_1.pid != channel_2.pid
      assert channel_1.conn.pid != channel_2.conn.pid

      stop_broadway(broadway)
    end

    test "processed messages delivered by the old connection/channel will not be acknowledged" do
      broadway = start_broadway()
      assert_receive {:setup_channel, :ok, channel}

      deliver_messages(broadway, [1, :break_conn])

      assert_receive {:message_handled, %Message{data: 1}, ^channel}
      assert_receive {:message_handled, %Message{data: :break_conn}, ^channel}

      refute_receive {:ack, 1}
      refute_receive {:ack, :break_conn}
    end

    test "log error when trying to acknowledge" do
      broadway = start_broadway()
      assert_receive {:setup_channel, :ok, _channel}

      assert capture_log(fn ->
               deliver_messages(broadway, [:break_conn])
               refute_receive {:ack, :break_conn}
             end) =~ "(EXIT) no process: the process is not alive"

      stop_broadway(broadway)
    end

    test "client is reinitialized every time it reconnects (for example, for switching URLs)" do
      broadway = start_broadway()

      assert_receive {:setup_channel, :ok, _}
      assert_receive :init_called

      deliver_messages(broadway, [1, :break_conn])
      assert_receive {:setup_channel, :ok, _}
      assert_receive :init_called

      stop_broadway(broadway)
    end
  end

  describe "handle consumer cancellation" do
    test "open a new connection/channel and keep consuming messages" do
      broadway = start_broadway()
      assert_receive {:setup_channel, :ok, channel_1}

      producer = get_producer(broadway)

      send(producer, {:basic_cancel, %{consumer_tag: :fake_consumer_tag}})

      assert_receive {:setup_channel, :ok, channel_2}

      assert channel_1.pid != channel_2.pid
      assert channel_1.conn.pid != channel_2.conn.pid

      stop_broadway(broadway)
    end

    test "dealing with :basic_consume_ok messages" do
      broadway = start_broadway()
      assert_receive {:setup_channel, :ok, _channel}

      producer = get_producer(broadway)

      send(producer, {:basic_cancel_ok, %{consumer_tag: :fake_consumer_tag}})

      stop_broadway(broadway)
    end
  end

  describe "handle connection refused" do
    test "log the error and try to reconnect" do
      assert capture_log(fn ->
               broadway = start_broadway(connect_responses: [:econnrefused])
               assert_receive {:setup_channel, :error, _}
               assert_receive {:setup_channel, :ok, _}
               stop_broadway(broadway)
             end) =~ "Cannot connect to RabbitMQ broker"
    end

    @tag :capture_log
    test "emit a Telemetry event" do
      parent = self()
      ref = make_ref()

      :telemetry.attach(
        "handle-connection-refused-emit-telemetry-event",
        [:broadway_rabbitmq, :amqp, :connection_failure],
        fn _event, measurement, meta, _config -> send(parent, {ref, measurement, meta}) end,
        _config = nil
      )

      broadway = start_broadway(connect_responses: [:econnrefused])
      assert_receive {:setup_channel, :error, _}
      assert_receive {:setup_channel, :ok, _}

      assert_receive {^ref, measurement, meta}, 500
      assert %{system_time: _} = measurement
      assert meta == %{reason: :econnrefused}

      stop_broadway(broadway)
    after
      :telemetry.detach("handle-connection-refused-emit-telemetry-event")
    end

    test "if backoff_type = :stop, log the error and don't try to reconnect" do
      assert capture_log(fn ->
               broadway = start_broadway(connect_responses: [:econnrefused], backoff_type: :stop)
               assert_receive {:setup_channel, :error, _}
               refute_receive {:setup_channel, _, _}
               stop_broadway(broadway)
             end) =~ "Cannot connect to RabbitMQ broker"
    end

    test "keep retrying to connect using the backoff strategy" do
      broadway =
        start_broadway(connect_responses: [:ok, :econnrefused, :econnrefused, :econnrefused, :ok])

      assert_receive {:setup_channel, :ok, _}

      deliver_messages(broadway, [1, :break_conn])

      assert_receive {:setup_channel, :error, _}
      assert get_backoff_timeout(broadway) == 10
      assert_receive {:setup_channel, :error, _}
      assert get_backoff_timeout(broadway) == 20
      assert_receive {:setup_channel, :error, _}
      assert get_backoff_timeout(broadway) == 40

      assert_receive {:setup_channel, :ok, _}
      refute_receive {:setup_channel, _, _}

      stop_broadway(broadway)
    end

    test "reset backoff timeout after a successful connection" do
      broadway = start_broadway(connect_responses: [:econnrefused, :ok])

      assert_receive {:setup_channel, :error, _}
      assert get_backoff_timeout(broadway) == 10

      assert_receive {:setup_channel, :ok, _}
      assert get_backoff_timeout(broadway) == nil

      stop_broadway(broadway)
    end

    test "with auth_failure 'Disconnected'" do
      assert capture_log(fn ->
               broadway = start_broadway(connect_responses: [{:auth_failure, 'Disconnected'}])
               assert_receive {:setup_channel, :error, _}
               assert_receive {:setup_channel, :ok, _}
               stop_broadway(broadway)
             end) =~ "Cannot connect to RabbitMQ broker: {:auth_failure, 'Disconnected'}"
    end

    test "with socket_closed_unexpectedly" do
      assert capture_log(fn ->
               broadway =
                 start_broadway(
                   connect_responses: [{:socket_closed_unexpectedly, :"connection.start"}]
                 )

               assert_receive {:setup_channel, :error, _}
               assert_receive {:setup_channel, :ok, _}
               stop_broadway(broadway)
             end) =~ "Cannot connect to RabbitMQ broker: {:socket_closed_unexpectedly"
    end
  end

  describe "unsuccessful acknowledgement" do
    test "raise when an error is thrown acknowledging" do
      broadway =
        start_broadway(
          client: FlakyRabbitmqClient,
          on_success: :ack,
          on_failure: :reject
        )

      deliver_messages(broadway, [:fail_to_ack])

      assert_raise(RuntimeError, fn ->
        Message.ack_immediately(%Message{
          data: :fail_to_ack,
          acknowledger:
            {Producer, {self(), :ref},
             %{
               client: FlakyRabbitmqClient,
               on_success: :ack,
               on_failure: :reject,
               delivery_tag: :unused
             }}
        })
      end)
    end

    test "raise when an error is returned from amqp" do
      broadway =
        start_broadway(
          client: FlakyRabbitmqClient,
          on_success: :ack,
          on_failure: :reject
        )

      deliver_messages(broadway, [:fail_to_ack])

      msgs =
        Enum.map(["failure one", "failure two"], fn data ->
          %Message{
            data: data,
            acknowledger:
              {Producer, {self(), :ref},
               %{
                 client: FlakyRabbitmqClient,
                 on_success: :ack,
                 on_failure: :reject,
                 delivery_tag: :error_tuple
               }}
          }
        end)

      ack_attempt = fn ->
        Message.ack_immediately(msgs)
      end

      assert_raise(RuntimeError, fn ->
        assert capture_log(ack_attempt) =~ "failure one"
        assert capture_log(ack_attempt) =~ "failure two"
        assert capture_log(ack_attempt) =~ "error returned from amqp"
      end)
    end
  end

  test "close connection on terminate" do
    broadway = start_broadway()
    assert_receive {:setup_channel, :ok, _channel}
    Process.exit(Process.whereis(broadway), :shutdown)
    assert_receive :connection_closed
  end

  test "if connection goes down, we reconnect" do
    _broadway = start_broadway()
    assert_receive {:setup_channel, :ok, channel}

    assert capture_log(fn ->
             Process.exit(channel.conn.pid, :shutdown)
             assert_receive {:setup_channel, :ok, new_channel}
             assert new_channel.pid != channel.pid
           end) =~ "AMQP connection went down with reason: :shutdown"
  end

  test "if channel goes down, we close the connection before reconnecting" do
    _broadway = start_broadway()
    assert_receive {:setup_channel, :ok, channel}

    Process.exit(channel.pid, :shutdown)
    assert_receive :connection_closed
  end

  test "if producer gets an AMQP basic_cancel, we disconnect" do
    broadway = start_broadway()
    producer = Broadway.producer_names(broadway) |> Enum.random()
    assert_receive {:setup_channel, :ok, _channel}
    send(producer, {:basic_cancel, %{consumer_tag: :fake_consumer_tag}})
    assert_receive :connection_closed
  end

  describe "with custom pool" do
    @tag :capture_log
    test "calls the pool to check out a channel" do
      broadway =
        start_broadway(
          connection: {:custom_pool, CustomPool, self()},
          client: BroadwayRabbitMQ.AmqpClient,
          after_connect: fn _channel -> {:error, :some_reason} end
        )

      assert_receive {:checkout_channel_called, new_channel}
      assert_receive {:checkin_channel_called, ^new_channel}

      stop_broadway(broadway)
    end
  end

  defp start_broadway(opts \\ []) do
    connect_responses = Keyword.get(opts, :connect_responses, [])
    backoff_type = Keyword.get(opts, :backoff_type, :exp)
    metadata = Keyword.get(opts, :metadata, [])
    on_success = Keyword.get(opts, :on_success, :ack)
    on_failure = Keyword.get(opts, :on_failure, :reject)
    merge_options = Keyword.get(opts, :merge_options, fn _ -> [] end)
    client = Keyword.get(opts, :client, FakeRabbitmqClient)
    consume_options = Keyword.get(opts, :consume_options, [])
    connection = Keyword.get(opts, :connection, nil)
    after_connect = Keyword.get(opts, :after_connect, nil)

    {:ok, connection_agent} = Agent.start_link(fn -> connect_responses end)
    name = new_unique_name()

    producer_opts = [
      client: client,
      queue: "test",
      test_pid: self(),
      backoff_type: backoff_type,
      backoff_min: 10,
      backoff_max: 100,
      connection_agent: connection_agent,
      qos: [prefetch_count: 10],
      metadata: metadata,
      consume_options: consume_options,
      on_success: on_success,
      on_failure: on_failure,
      merge_options: merge_options,
      connection: connection,
      after_connect: after_connect
    ]

    producer_opts =
      if client == BroadwayRabbitMQ.AmqpClient do
        Keyword.drop(producer_opts, [:test_pid, :connection_agent])
      else
        producer_opts
      end

    {:ok, _pid} =
      Broadway.start_link(Forwarder,
        name: name,
        context: %{test_pid: self()},
        producer: [module: {BroadwayRabbitMQ.Producer, producer_opts}, concurrency: 1],
        processors: [default: [concurrency: 1]],
        batchers: [default: [batch_size: 2, batch_timeout: 50, concurrency: 1]]
      )

    name
  end

  defp new_unique_name() do
    :"Broadway#{System.unique_integer([:positive, :monotonic])}"
  end

  defp deliver_messages(broadway, messages, opts \\ []) do
    redelivered = Keyword.get(opts, :redelivered, false)
    producer = Broadway.producer_names(broadway) |> Enum.random()
    extra_metadata = Keyword.get(opts, :extra_metadata, %{})

    Enum.each(messages, fn msg ->
      send(
        producer,
        {:basic_deliver, msg,
         Map.merge(%{delivery_tag: msg, redelivered: redelivered}, extra_metadata)}
      )
    end)
  end

  defp get_producer(name, index \\ 0) when is_atom(name) do
    :"#{name}.Broadway.Producer_#{index}"
  end

  defp get_backoff_timeout(broadway) do
    producer = get_producer(broadway)
    :sys.get_state(producer).state.module_state.backoff.state
  end

  defp stop_broadway(name) when is_atom(name) do
    pid = Process.whereis(name)
    ref = Process.monitor(pid)
    Process.exit(pid, :normal)

    receive do
      {:DOWN, ^ref, _, _, _} -> :ok
    after
      1000 -> flunk("Broadway did not stop within 1000ms")
    end
  end
end
