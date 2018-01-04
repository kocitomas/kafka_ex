defmodule KafkaEx.Server0P8P2 do
  @moduledoc """
  Implements kafkaEx.Server behaviors for kafka >= 0.8.2 < 0.9.0 API.
  """

  # these functions aren't implemented for 0.8.2
  @dialyzer [
    {:nowarn_function, kafka_server_heartbeat: 3},
    {:nowarn_function, kafka_server_sync_group: 3},
    {:nowarn_function, kafka_server_join_group: 3},
    {:nowarn_function, kafka_server_leave_group: 3}
  ]

  use KafkaEx.Server
  alias KafkaEx.ConsumerGroupRequiredError
  alias KafkaEx.Protocol.Fetch
  alias KafkaEx.Protocol.Fetch.Request, as: FetchRequest
  alias KafkaEx.Protocol.OffsetFetch
  alias KafkaEx.Protocol.OffsetCommit
  alias KafkaEx.Server.State
  alias KafkaEx.NetworkClient

  def start_link(args, name \\ __MODULE__)

  def start_link(args, :no_name) do
    GenServer.start_link(__MODULE__, [args])
  end
  def start_link(args, name) do
    GenServer.start_link(__MODULE__, [args, name], [name: name])
  end

  def kafka_server_init([args]) do
    kafka_server_init([args, self()])
  end

  def kafka_server_init([args, name]) do
    # warn if ssl is configured
    if Keyword.get(args, :use_ssl) do
      Logger.warn(fn ->
        "KafkaEx is being configured to use ssl with a broker version that " <>
          "does not support ssl"
      end)
    end

    state = kafka_common_init(args, name)

    state_with_cg_metadata = consumer_group_init(state)

    {:ok, state_with_cg_metadata}
  end

  def kafka_server_consumer_group(state) do
    {:reply, state.consumer_group, state}
  end

  def kafka_server_fetch(fetch_request, state) do
    true = consumer_group_if_auto_commit?(fetch_request.auto_commit, state)
    {response, state} = fetch(fetch_request, state)

    {:reply, response, state}
  end

  def kafka_server_offset_fetch(offset_fetch, state) do
    unless State.consumer_group?(state) do
      raise ConsumerGroupRequiredError, offset_fetch
    end

    {broker, state} = broker_for_consumer_group_with_update(state)

    # if the request is for a specific consumer group, use that
    # otherwise use the worker's consumer group
    consumer_group = offset_fetch.consumer_group || state.consumer_group
    offset_fetch = %{offset_fetch | consumer_group: consumer_group}

    wire_request = offset_fetch
                   |> client_request(state)
                   |> OffsetFetch.create_request

    {response, state} = case broker do
      nil    ->
        Logger.log(:error, "Coordinator for topic #{offset_fetch.topic} is not available")
        {:topic_not_found, state}
      _ ->
        response = broker
          |> NetworkClient.send_sync_request(wire_request, config_sync_timeout())
          |> OffsetFetch.parse_response
        {response, %{state | correlation_id: state.correlation_id + 1}}
    end

    {:reply, response, state}
  end

  def kafka_server_offset_commit(offset_commit_request, state) do
    {response, state} = offset_commit(state, offset_commit_request)

    {:reply, response, state}
  end

  def kafka_server_consumer_group_metadata(state) do
    {consumer_metadata, state} = update_consumer_metadata(state)
    {:reply, consumer_metadata, state}
  end

  def kafka_server_update_consumer_metadata(state) do
    unless State.consumer_group?(state) do
      raise ConsumerGroupRequiredError, "consumer metadata update"
    end

    {_, state} = update_consumer_metadata(state)
    {:noreply, state}
  end

  def kafka_server_join_group(_, _, _state), do: raise "Join Group is not supported in 0.8.0 version of kafka"
  def kafka_server_sync_group(_, _, _state), do: raise "Sync Group is not supported in 0.8.0 version of kafka"
  def kafka_server_leave_group(_, _, _state), do: raise "Leave Group is not supported in 0.8.0 version of Kafka"
  def kafka_server_heartbeat(_, _, _state), do: raise "Heartbeat is not supported in 0.8.0 version of kafka"

  defp fetch(request, state) do
    case partition_request(request, Fetch, state) do
      {{:error, error}, state_out} -> {error, state_out}
      {response, state_after_fetch} ->
        # commit the offset if we need to
        last_offset = last_offset_from_fetch(response)
        state_out = maybe_commit_offset(
          last_offset,
          request,
          state_after_fetch
        )
        {response, state_out}
    end
  end

  defp offset_commit(state, offset_commit_request) do
    {broker, state} = broker_for_consumer_group_with_update(state, true)

    # if the request has a specific consumer group, use that
    # otherwise use the worker's consumer group
    consumer_group = offset_commit_request.consumer_group || state.consumer_group
    offset_commit_request = %{offset_commit_request | consumer_group: consumer_group}

    offset_commit_request_payload = OffsetCommit.create_request(state.correlation_id, @client_id, offset_commit_request)
    response = broker
      |> NetworkClient.send_sync_request(offset_commit_request_payload, config_sync_timeout())
      |> OffsetCommit.parse_response

    {response, %{state | correlation_id: state.correlation_id + 1}}
  end

  defp consumer_group_if_auto_commit?(true, state) do
    State.consumer_group?(state)
  end
  defp consumer_group_if_auto_commit?(false, _state) do
    true
  end

  defp first_broker_response(request, state) do
    first_broker_response(request, state.brokers, config_sync_timeout())
  end

  defp maybe_commit_offset(nil, _fetch_request, state), do: state
  defp maybe_commit_offset(_, %FetchRequest{auto_commit: false}, state) do
    state
  end

  defp maybe_commit_offset(offset, fetch_request, state) do
    unless State.consumer_group?(state) do
      raise ConsumerGroupRequiredError, fetch_request
    end

    offset_commit_request = %OffsetCommit.Request{
      topic: fetch_request.topic,
      partition: fetch_request.partition,
      offset: offset,
      consumer_group: state.consumer_group
    }
    {_, state_out} = offset_commit(state, offset_commit_request)
    state_out
  end

  defp last_offset_from_fetch([response]) do
    [partition] = response.partitions
    partition.last_offset
  end
end
