defmodule Mutex.NameRegistrationTest do
  alias Mutex.Lock
  import Mutex.Test.Utils
  require Logger
  use ExUnit.Case, async: false

  @moduletag :capture_log
  @mut rand_mod()

  setup do
    pid = start_supervised!({Mutex, name: @mut})
    {:ok, mutex_pid: pid}
  end

  defp via(key, mutex_name \\ @mut), do: {:via, Mutex, {mutex_name, key}}

  test "can find a process by it's lock" do
    {ack, wack} = vawack()

    key = :i_am_here
    via = via(key)

    xspawn(fn ->
      _lock = Mutex.lock!(@mut, key)
      ack.(self())
      hang()
    end)

    pid = wack.()

    assert pid == GenServer.whereis(via)
    assert pid == Mutex.whereis_name({@mut, key})
  end

  test "cannot find process after exit" do
    task = Task.async(fn -> Mutex.lock!(@mut, :i_will_exit) end)
    assert %Lock{} = Task.await(task)
    assert nil == GenServer.whereis({:via, Mutex, {@mut, :i_will_exit}})
  end

  test "can start a proces with a name" do
    mod = rand_mod()

    defmodule mod do
      def init(arg), do: {:ok, arg}
    end

    key = :gs
    via = via(key)

    # server will start
    assert {:ok, pid} = GenServer.start_link(mod, [], name: via)

    # server will have a lock
    assert {:error, :busy} = Mutex.lock(@mut, :gs)
    assert {:error, {:already_started, ^pid}} = GenServer.start_link(mod, [], name: via)

    # on stop the lock is freed (this does not need uregister_name impl, it's
    # done by the monitor in the mutex anyway).
    assert :ok = GenServer.stop(pid)
    assert {:ok, _} = Mutex.lock(@mut, key)
  end

  test "unregister name on gen server init :error tuple" do
    sync = syncher(2)

    key = :err_gs
    via = via(key)

    mod = rand_mod()

    defmodule mod do
      def init(sync) do
        sync.(:initializing)
        sync.(:tested_busy)
        {:error, :changed_my_mind}
      end
    end

    # Start the gen server from another pid since it will be blocking
    starter = Task.async(fn -> GenServer.start_link(mod, sync, name: via) end)

    # when initializing the process has been registered
    sync.(:initializing)
    assert {:error, :busy} = Mutex.lock(@mut, key)

    # now we will let the gen server init return stop
    sync.(:tested_busy)

    # Gen server has stopped
    assert {:error, :changed_my_mind} = Task.await(starter)
    assert {:ok, _} = Mutex.lock(@mut, key)
  end

  test "unregister name on gen server init :stop tuple (exit)" do
    sync = syncher(2)

    key = :stop_gs
    via = via(key)

    mod = rand_mod()

    defmodule mod do
      def init(sync) do
        sync.(:initializing)
        sync.(:tested_busy)
        {:stop, :changed_my_mind}
      end
    end

    # Start the gen server from another pid since it will be blocking
    starter =
      Task.async(fn ->
        Process.flag(:trap_exit, true)
        GenServer.start_link(mod, sync, name: via)
      end)

    # when initializing the process has been registered
    sync.(:initializing)
    assert {:error, :busy} = Mutex.lock(@mut, key)

    # now we will let the gen server init return stop
    sync.(:tested_busy)

    # Gen server has stopped
    assert {:error, :changed_my_mind} = Task.await(starter)
    assert {:ok, _} = Mutex.lock(@mut, key)
  end

  defmodule CounterGS do
    def init(n), do: {:ok, n}

    def handle_call(:get_count, _, n), do: {:reply, n, n}
    def handle_call(:increment, _, n), do: {:reply, n, n + 1}

    def handle_cast(:increment, n), do: {:noreply, n + 1}
  end

  test "genserver via API" do
    # implement a simple counter as a gen server

    key = :counter
    via = via(key)

    assert {:ok, pid} = GenServer.start_link(CounterGS, 0, name: via)
    assert pid == GenServer.whereis(via)

    # gen call
    assert 0 = GenServer.call(via, :get_count)
    assert 0 = GenServer.call(via, :increment)
    assert 1 = GenServer.call(via, :get_count)

    # gen cast This will always return ok even if Mutex does not implement
    # send/2, but the value should be incremented.
    assert :ok = GenServer.cast(via, :increment)
    assert 2 = GenServer.call(via, :get_count)

    # cast to a non existing process. send/2 will exit as in global but
    # GenServer.cast will catch it.
    assert :ok = GenServer.cast(via(:other), :increment)

    # Stacktrace should contain arguments
    formatted_stacktrace =
      try do
        Mutex.send({@mut, :other_key}, :increment)
      rescue
        _ -> Exception.format_stacktrace(__STACKTRACE__)
      end

    assert formatted_stacktrace =~ "Mutex.send({#{inspect(@mut)}, :other_key}, :increment)"

    :ok = GenServer.stop(via)
  end

  test "genserver via API - pid instead of name", ctx do
    # implement a simple counter as a gen server

    key = :counter

    # forcing the mutex to not be found by name
    Process.unregister(@mut)
    via = via(key, ctx.mutex_pid)

    assert {:ok, pid} = GenServer.start_link(CounterGS, 0, name: via)
    assert pid == GenServer.whereis(via)

    # gen call
    assert 0 = GenServer.call(via, :get_count)

    # gen cast This will always return ok even if Mutex does not implement
    # send/2, but the value should be incremented.
    assert :ok = GenServer.cast(via, :increment)
    assert 1 = GenServer.call(via, :get_count)

    :ok = GenServer.stop(via)
  end
end
