defmodule HostPool do
  @moduledoc ~S"""
  Hackney pool implementation that sets limits per host in stead of pool.
  """
  use Supervisor

  @behaviour :hackney_pool_handler

  @compile {:inline, pool_name: 2}

  # Supervisor settings
  @super_parent :hackney_sup
  @super_spec supervisor(__MODULE__, [])

  # Configuration
  @connection_pool Application.get_env(:host_pool,
                                       :connection_pool,
                                       HostPool.ConnectionPool)
  @checkout_timeout Application.get_env(:host_pool, :checkout_timeout, 5_000)
  @checkout_limit Application.get_env(:host_pool, :checkout_limit, 15_000)

  # Request record parsing
  @record_request_options 6 + 1

  ### Hackney Pool Handler

  @impl true
  def start do
    with {:ok, _pid} <- Supervisor.start_child(@super_parent, @super_spec) do
      :ok
    end
  end

  @impl true
  def checkout(host, port, transport, client) do
    # Parse options
    options =
      client
      |> elem(@record_request_options)

    pool_name =
      options
      |> Keyword.get(:pool, :default)

    connect_timeout =
      options
      |> Keyword.get(:connect_timeout, @checkout_timeout)

    checkout_limit =
      options
      |> Keyword.get(:checkout_limit, @checkout_limit)

    # Setup references
    checkin_ref = {host, port, transport}

    owner =
      pool_name
      |> find_or_create_pool(checkin_ref)

    # Make the call
    result =
      GenServer.call(
        owner,
        {:checkout, checkin_ref, {connect_timeout, checkout_limit}},
        connect_timeout
      )

    # Parse the result
    case result do
      {:ok, socket} ->
        {
          :ok,
          {pool_name, checkin_ref, owner, :return},
          socket
        }
      # credo:disable-for-next-line
      {:new,} ->
        {
          :error,
          :no_socket,
          {pool_name, checkin_ref, owner, :new}
        }
      error -> error
    end
  end

  @impl true
  def checkin(reference = {_pool, _data, owner, type}, socket) do
    if type == :new do
      unclaim(socket)
    end

    GenServer.call(owner, {:checkin, reference, socket})
  end

  @impl true
  def notify(_pool, _message) do
    # Do not notify anyone

    :ok
  end

  ### Supervisor

  @doc false
  @spec start_link :: Supervisor.on_start
  def start_link do
    Supervisor.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init([]) do
    Supervisor.init([], strategy: :one_for_one)
  end

  ### Pool Helpers

  # Finds or creates a pool.
  # All created pools are added to the HostPool supervisor.
  @spec find_or_create_pool(atom, tuple) :: pid
  defp find_or_create_pool(pool, reference) do
    name = pool_name(pool, reference)
    child = worker(@connection_pool, [name], id: name)

    case Supervisor.start_child(__MODULE__, child) do
      {:ok, pid} -> pid
      {:error, {:already_started, pid}} -> pid
    end
  end

  # @spec stop_pool(term) :: :ok | {:error, atom}
  # defp stop_pool(id) do
  #   Supervisor.terminate_child __MODULE__, id
  #   Supervisor.delete_child __MODULE__, id
  # end

  # Unlinks the socket from its creator.
  @spec unclaim(term) :: true
  def unclaim({:sslsocket, {_, port, _, _}, _}), do: :erlang.unlink(port)
  def unclaim(port), do: :erlang.unlink(port)

  # Turns the pool and checkin_ref into an identifier.
  @spec pool_name(atom, tuple) :: term
  case Application.get_env(:host_pool, :pool_type, :host) do
    :single ->
      defp pool_name(_pool, _ref), do: :single_process_pool
    :pool ->
      defp pool_name(pool, _ref), do: pool
    :host ->
      defp pool_name(pool, {host, _, _}), do: {pool, host}
  end
end
