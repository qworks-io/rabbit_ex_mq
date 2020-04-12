defmodule RabbitMQ.Producer.Worker do
  alias AMQP.{Basic, Channel, Confirm}

  require Logger

  use GenServer

  @this_module __MODULE__

  defmodule Config do
    @enforce_keys ~w(channel_type connection confirm_type confirm_timeout)a
    defstruct @enforce_keys
  end

  defmodule State do
    # TODO look into using ETS for outstanding_confirms
    @enforce_keys ~w(channel config outstanding_confirms)a
    defstruct @enforce_keys
  end

  ##############
  # Public API #
  ##############

  def start_link(config) do
    GenServer.start_link(@this_module, config)
  end

  ######################
  # Callback Functions #
  ######################

  @impl true
  def init(%Config{confirm_type: :async, connection: connection} = config) do
    with table <- :ets.new(:outstanding_confirms, [:protected, :ordered_set]),
         {:ok, channel} <- Channel.open(connection),
         :ok <- Confirm.select(channel),
         :ok <- Confirm.register_handler(channel, self()) do
      {:ok, %State{config: config, channel: channel, outstanding_confirms: table}}
    end
  end

  # @impl true
  # def init(%Config{channel_type: :confirm, connection: connection} = config) do
  #   with {:ok, channel} <- Channel.open(connection),
  #        :ok <- Confirm.select(channel),
  #        :ok <- Confirm.register_handler(channel, self()) do
  #     {:ok, %State{config: config, channel: channel, unackd: []}}
  #   end
  # end

  # @impl true
  # def init(%Config{connection: connection} = config) do
  #   with {:ok, channel} <- Channel.open(connection) do
  #     {:ok, %State{config: config, channel: channel, unackd: []}}
  #   end
  # end

  @impl true
  def handle_call(
        {:publish, exchange, routing_key, data, opts},
        _from,
        %State{
          config: %Config{channel_type: :confirm, confirm_timeout: confirm_timeout},
          channel: %Channel{} = channel,
          outstanding_confirms: outstanding_confirms
        } = state
      ) do
    next_publish_seqno = Confirm.next_publish_seqno(channel)

    case do_publish(channel, exchange, routing_key, data, opts) do
      :ok ->
        :ets.insert(outstanding_confirms, {next_publish_seqno, data})
        # true = Confirm.wait_for_confirms_or_die(channel, confirm_timeout)
        # TODO investigate notifications when confirms are not
        # received within a specified time limit?
        {:reply, {:ok, next_publish_seqno}, state}

      error ->
        {:reply, error, state}
    end
  end

  # @impl true
  # def handle_call(
  #       {:publish, exchange, routing_key, data, opts},
  #       _from,
  #       %State{
  #         channel: %Channel{} = channel
  #       } = state
  #     ) do
  #   case do_publish(channel, exchange, routing_key, data, opts) do
  #     :ok -> {:reply, {:ok, channel}, state}
  #     error -> {:reply, error, state}
  #   end
  # end

  @impl true
  def handle_info(
        {:basic_ack, seq_number, false},
        %State{outstanding_confirms: outstanding_confirms} = state
      ) do
    Logger.info("Received ACK of #{seq_number}.")

    true = :ets.delete(outstanding_confirms, seq_number)

    {:noreply, state}
  end

  @impl true
  def handle_info(
        {:basic_ack, seq_number, true},
        %State{outstanding_confirms: outstanding_confirms} = state
      ) do
    Logger.info("Received ACKs up to #{seq_number}.")

    # ms = :ets.fun2ms(fn {index, _data} when index <= seq_number -> true end)
    ms = [{{:"$1", :"$2"}, [{:"=<", :"$1", seq_number}], [true]}]
    _ = :ets.select_delete(outstanding_confirms, ms)

    {:noreply, state}
  end

  @impl true
  def handle_info(
        {:basic_nack, seq_number, false},
        %State{outstanding_confirms: outstanding_confirms} = state
      ) do
    Logger.warn("Received NACK of #{seq_number}.")

    # TODO also notify another process!
    true = :ets.delete(outstanding_confirms, seq_number)

    {:noreply, state}
  end

  @impl true
  def handle_info(
        {:basic_nack, seq_number, true},
        %State{outstanding_confirms: outstanding_confirms} = state
      ) do
    Logger.info("Received NACKs up to #{seq_number}.")

    # TODO also notify another process!
    # ms = :ets.fun2ms(fn {index, _data} when index <= seq_number -> true end)
    ms = [{{:"$1", :"$2"}, [{:"=<", :"$1", seq_number}], [true]}]
    _ = :ets.select_delete(outstanding_confirms, ms)

    {:noreply, state}
  end

  @impl true
  def terminate(reason, %State{channel: %Channel{} = channel} = state) do
    Logger.warn(
      "Terminating Producer Worker due to #{inspect(reason)}. Closing dedicated channel."
    )

    Channel.close(channel)

    {:noreply, %{state | channel: nil}}
  end

  #####################
  # Private Functions #
  #####################

  defp do_publish(channel, exchange, routing_key, data, opts) do
    if Keyword.has_key?(opts, :correlation_id) do
      Basic.publish(channel, exchange, routing_key, data, opts)
    else
      {:error, :correlation_id_missing}
    end
  end
end
