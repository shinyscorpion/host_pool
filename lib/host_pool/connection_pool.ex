defmodule HostPool.ConnectionPool do
  @moduledoc """
  Documentation for ConnectionPool.
  """

  use GenServer

  @compile {:inline, checkout_connection: 5, queue_for_connection: 5}

  @limit Application.get_env(:host_pool, :limit, 10)
  @checkout_timeout_reduction 100

  @starting_state %{queue: [], items: [], checked_out: []}

  case Application.get_env(:host_pool, :overflow, :timeout) do
    :timeout ->
      @overflow_message {:error, :pool_connect_timeout}
    :allow ->
      @overflow_message {:ok, :new}
  end

  ### GenServer

  @doc false
  @dialyzer {:nowarn_function, start_link: 1}
  @spec start_link(term) :: GenServer.on_start
  def start_link(name) do
    GenServer.start_link(__MODULE__, %{}, id: name)
  end

  @impl true
  def handle_call({:checkout, id, {checkout_timeout, checkout_limit}}, from, state) do
    host = Map.get(state, id, @starting_state)
    unavailable = Enum.count(host.checked_out)

    cond do
      Enum.count(host.items) > 0 ->
        checkout_connection(host, id, checkout_limit, from, state)
      unavailable >= @limit ->
        queue_for_connection(host, id, checkout_timeout, from, state)
      true ->
        state = Map.put(state, id, host)
        {:reply, {:ok, :new}, state}
    end
  end

  def handle_call({:checkin, {_, id, _, type}, socket}, from, state) do
    GenServer.reply(from, :ok)

    transport = id |> elem(2)

    # Clean socket if type is new
    if type == {:ok, :new} do
      claim(socket)

      transport.controlling_process socket, self()
      transport.setopts socket, [{:keepalive, true}, {:active, true}]
    else
      transport.setopts socket, [{:active, true}]
    end

    # Get and update host
    host = Map.get(state, id, @starting_state)
    updated_host =
      (return(host, type, socket) || add_new_connection(host, socket))
      |> check_queue()

    {:noreply, Map.put(state, id, updated_host)}
  end

  @impl true
  def handle_info(info, state) do
    IO.inspect info

    {:noreply, state}
  end

  ### Connection distributing

  @spec checkout_connection(map, tuple, non_neg_integer, tuple, map) :: tuple
  defp checkout_connection(
    host = %{items: [socket | items]},
    id = {_, _, transport},
    checkout_limit,
    {client_pid, _},
    state
  ) do
    host = Map.put(host, :items, items)

    transport.setopts socket, [{:active, false}]
    if socket_alive?(transport, socket) do
      transport.controlling_process socket, client_pid

      checked_out =
        {socket, System.system_time(:milliseconds) + checkout_limit}

      updated_host =
        host
        |> Map.update(:checked_out, [checked_out], &([checked_out | &1]))

      {:reply, {:ok, socket}, Map.put(state, id, updated_host)}
    else
      # cleanup by closing socket
      close socket

      {:reply, {:ok, :new}, Map.put(state, id, host)}
    end
  end

  @spec queue_for_connection(map, tuple, non_neg_integer, tuple, map) :: tuple
  defp queue_for_connection(host, id, checkout_timeout, from, state) do
    # Cleanup and try to respond
    case clean_checked_out(host.checked_out) do
      {:ok, out} ->
        # We were able to create more space, let's tell them
        updated_host = Map.put(host, :checked_out, out)

        {:reply, {:ok, :new}, Map.put(state, id, updated_host)}
      :ok ->
        if checkout_timeout > @checkout_timeout_reduction do
          {client_pid, tag} = from

          timer =
            Process.send_after(
              client_pid,
              {tag, @overflow_message},
              (checkout_timeout - @checkout_timeout_reduction)
            )

          client = {from, timer}
          updated_host =
            Map.update(host, :queue, [client], &([client | &1]))

          {:noreply, Map.put(state, id, updated_host)}
        else
          {:reply, @overflow_message, state}
        end
    end
  end

  ### Check in Check out logic helpers

  @spec check_queue(map) :: map
  defp check_queue(host = %{queue: []}), do: host
  defp check_queue(host = %{items: []}), do: host
  defp check_queue(host) do
    {client, clients} = queue_client(host.queue)

    if client do
      [item | items] = host.items # Should only be one item, but still...

      GenServer.reply client, {:ok, item}

      %{host | queue: clients, items: items}
    else
      %{host | queue: clients}
    end
  end

  @spec queue_client(list(tuple)) :: {tuple | nil, list(tuple)}
  defp queue_client([]), do: {nil, []}
  defp queue_client([client | clients]) do
    {c, tail} = queue_client(clients)

    if is_nil(c) do
      {from, timer} = client

      case Process.cancel_timer(timer) do
        false -> {nil, tail}
        _ -> {from, tail}
      end
    else
      {c, [client | tail]}
    end
  end

  @spec return(map, atom, any) :: map | false
  defp return(host, :return, socket) do
    case List.keytake(host.checked_out, socket, 0) do
      nil ->
        # Old connection got turned back in
        # Just treat it like a new connection
        false
      {_, out} ->
        %{host | checked_out: out, items: [socket | host.items]}
    end
  end
  defp return(_, _, _), do: false

  @spec add_new_connection(map, any) :: map
  defp add_new_connection(host, socket) do
    available = Enum.count(host.items)
    unavailable = Enum.count(host.checked_out)

    cond do
      available >= @limit ->
        close socket

        host
      unavailable > 0 && available + unavailable >= @limit ->
        with {:ok, out} <- clean_checked_out(host.checked_out) do
          %{host | checked_out: out, items: [socket | host.items]}
        else
          :ok ->
            close socket

            host
        end
      true ->
        %{host | items: [socket | host.items]}
    end
  end

  @spec clean_checked_out(list) :: :ok | {:ok, map}
  defp clean_checked_out(checked_out) do
    {to_close, out} =
      checked_out
      |> Enum.partition(&timed_out?/1)

    if to_close == [] do
      :ok
    else
      to_close
      |> Enum.each(&(&1 |> elem(0) |> close()))

      {:ok, out}
    end
  end

  @spec timed_out?({any, integer}) :: boolean
  defp timed_out?({_, timeout}) do
    timeout <= System.system_time(:milliseconds)
  end

  ### Socket Helpers

  @spec close(any) :: term
  defp close(socket = {:sslsocket, _, _}), do: :ssl.close(socket)
  defp close(socket), do: :gen_tcp.close(socket)

  @spec claim(any) :: true
  defp claim({:sslsocket, {_, port, _, _}, _}), do: :erlang.link(port)
  defp claim(port), do: :erlang.link(port)

  @spec socket_alive?(atom, any) :: boolean
  defp socket_alive?(transport, socket) do
    with {:ok, _} <- transport.peername(socket) do
      sync_socket(transport, socket)
    else
      _ -> false
    end
  end

  @spec socket_alive?(atom, any) :: boolean
  defp sync_socket(transport, socket) do
    {msg, msg_closed, msg_error} = transport.messages(socket)

    receive do
      {^msg, ^socket, _} -> false
      {^msg_closed, ^socket} -> false
      {^msg_error, ^socket, _} -> false
    after
      0 -> true
    end
  end
end
