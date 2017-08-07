defmodule HostPoolTest do
  use ExUnit.Case, async: false

  defp client(options \\ []) do
    {0, 1, 2, 3, 4, 5, 6, options}
  end

  describe "pool management" do
    test "creates a new pool for unique id" do
      HostPool.checkout 'pool-test-new.com', 1, :custom, client()

      children = Supervisor.which_children(HostPool)

      assert List.keymember?(children, {:default, 'pool-test-new.com'}, 0)
    end

    test "reuses pool for existing id" do
      HostPool.checkout 'pool-test-reuse.com', 1, :custom, client()
      children = Supervisor.which_children(HostPool)

      HostPool.checkout 'pool-test-reuse.com', 1, :custom, client()
      new_children = Supervisor.which_children(HostPool)

      assert new_children == children
    end

    test "respects pool" do
      HostPool.checkout 'pool-test-pool.com', 1, :custom, client(pool: :custom)

      children = Supervisor.which_children(HostPool)

      assert List.keymember?(children, {:custom, 'pool-test-pool.com'}, 0)
    end
  end

  describe "checkin" do
    test "claims port when :new (ssl)" do
      port = 5
      ref = {:default, 0, self(), :new}
      socket = {:sslsocket, {0, port, 0, 0}, 0}

      assert_raise ArgumentError, fn -> HostPool.checkin ref, socket end
    end

    test "claims port when :new (other)" do
      port = 5
      ref = {:default, 0, self(), :new}

      assert_raise ArgumentError, fn -> HostPool.checkin ref, port end
    end

    test "doesn not claim port on :return (other)" do
      owner = self()
      ref = {:default, 0, owner, :return}
      port = 5

      :meck.new GenServer
      :meck.expect GenServer, :call, fn
        ^owner, {:checkin, ^ref, ^port} -> :not_claimed
      end
      on_exit &:meck.unload/0

      assert HostPool.checkin(ref, port) == :not_claimed
    end
  end


  describe "checkout" do
    defp mock_response(ref, result, data_pid \\ nil) do
      :meck.new GenServer, [:passthrough]
      :meck.expect GenServer, :call, fn
        owner, {:checkout, ^ref, options}, timeout ->
          if data_pid do
            send data_pid, {:mock_data, options, timeout, owner}
          end

          result
        a, b, c -> :meck.passthrough([a, b, c])
      end
      on_exit &:meck.unload/0
    end

    test "creates correct reference" do
      ref = {'pool-test-checkout.com', 1, :custom}
      mock_response ref, :ok_ref

      assert HostPool.checkout('pool-test-checkout.com', 1, :custom, client()) == :ok_ref
    end

    test "uses the correct timeout" do
      ref = {'pool-test-checkout.com', 1, :custom}
      mock_response ref, :ok_ref, self()

      client = client(connect_timeout: 5)
      HostPool.checkout('pool-test-checkout.com', 1, :custom, client)

      {options, timeout} =
        receive do
          {:mock_data, options, timeout, _owner} -> {options, timeout}
        end

      assert timeout == 5
      assert elem(options, 0) == 5
    end

    test "uses the correct checkout limit" do
      ref = {'pool-test-checkout.com', 1, :custom}
      mock_response ref, :ok_ref, self()

      client = client(checkout_limit: 8)
      HostPool.checkout('pool-test-checkout.com', 1, :custom, client)

      checkout_limit =
        receive do
          {:mock_data, {_, checkout_limit}, _timeout, _owner} -> checkout_limit
        end

      assert checkout_limit == 8
    end

    test "passes along the errors" do
      ref = {'pool-test-checkout.com', 1, :custom}
      mock_response ref, {:error, :ref}

      assert HostPool.checkout('pool-test-checkout.com', 1, :custom, client()) == {:error, :ref}
    end

    test "returns correct response for new socket" do
      ref = {'pool-test-checkout.com', 1, :custom}
      mock_response ref, {:new,}, self()

      response = HostPool.checkout('pool-test-checkout.com', 1, :custom, client())

      owner =
        receive do
          {:mock_data, _options, _timeout, owner} -> owner
        end

      assert response == {:error, :no_socket, {:default, ref, owner, :new}}
    end

    test "returns correct response for existing socket" do
      ref = {'pool-test-checkout.com', 1, :custom}
      mock_response ref, {:ok, :existing_socket}, self()

      response = HostPool.checkout('pool-test-checkout.com', 1, :custom, client())

      owner =
        receive do
          {:mock_data, _options, _timeout, owner} -> owner
        end

      assert response == {:ok, {:default, ref, owner, :return}, :existing_socket}
    end
  end
end
