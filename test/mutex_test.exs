defmodule MutexTest do
  alias Mutex.Lock
  import Mutex.Test.Utils
  require Logger
  use ExUnit.Case, async: true

  doctest Mutex

  # @moduletag :capture_log
  @mut rand_mod()

  setup do
    {:ok, _pid} = start_supervised({Mutex, name: @mut, meta: :test_mutex})
    :ok
  end

  test "mutex can start" do
    assert is_pid(Process.whereis(@mut))
  end

  test "can acquire lock (can lock key)" do
    assert {:ok, %Lock{meta: :test_mutex}} = Mutex.lock(@mut, :some_key)
  end

  test "can't acquire locked key" do
    {ack, wack} = awack()

    tspawn(fn ->
      Mutex.lock!(@mut, :key1)

      ack.()
      hang()
    end)

    wack.()
    assert {:error, :busy} = Mutex.lock(@mut, :key1)
  end

  test "can wait for key is released when owner dies" do
    {ack, wack} = awack()

    tspawn(fn ->
      Mutex.lock!(@mut, :key2)
      ack.()
      Process.sleep(100)
    end)

    wack.()
    assert %Lock{} = Mutex.await(@mut, :key2, 500)
  end

  test "a wait-for-lock should timeout" do
    {ack, wack} = awack()

    pid =
      tspawn(fn ->
        Mutex.lock!(@mut, :key3)
        ack.()
        hang()
      end)

    wack.()
    assert {:timeout, _} = catch_exit(Mutex.await(@mut, :key3, 500))
    Process.exit(pid, :normal)
  end

  test "can wait for a killed process to be automatically released" do
    {ack_locker, wack_locker} = awack()

    {locker_pid, locker_mref} =
      spawn_monitor(fn ->
        Mutex.lock!(@mut, :inf_key)
        ack_locker.()
        hang()
      end)

    wack_locker.()

    {ack_waiter, wack_waiter} = awack(:infinity)

    tspawn(fn ->
      assert {:error, :busy} = Mutex.lock(@mut, :inf_key)
      # infinity timeout is valid
      assert %Lock{} = Mutex.await(@mut, :inf_key, :infinity)
      ack_waiter.()
    end)

    kill_after(locker_pid, 100)
    assert_receive {:DOWN, ^locker_mref, :process, ^locker_pid, :killed}
    # the second process can to lock
    assert :ok = wack_waiter.()
  end

  test "if a fun throws within wrapper, the lock should be released" do
    {ack, wack} = awack(:infinity)

    spawn_hang(fn ->
      # here we catch so the process does not exit, so the lock is not released
      # because of an exit (false positive) but because the lib removes it
      try do
        Mutex.under(@mut, :wrap1, :infinity, fn ->
          ack.()
          throw(:fail)
        end)
      catch
        :throw, :fail -> :ok
      end
    end)

    wack.()
    assert %Lock{} = Mutex.await(@mut, :wrap1, 1000)
  end

  test "if a fun exits within wrapper, the lock should be released" do
    {ack, wack} = awack(:infinity)

    spawn_hang(false, fn ->
      Mutex.under(@mut, :wrap2, :infinity, fn ->
        ack.()
        Logger.debug("exit from pid #{inspect(self())}")
        exit(:fail)
      end)
    end)

    wack.()
    assert %Lock{} = Mutex.await(@mut, :wrap2, 1000)
  end

  test "if a fun raises within wrapper with multilock it should be fine" do
    {ack, wack} = awack(:infinity)
    errmsg = "You failed me !"
    keys = [:wrap_mult_1, :wrap_mult_2]

    spawn_hang(fn ->
      try do
        Mutex.under_all(@mut, keys, fn ->
          ack.()
          Logger.debug("Will raise #{errmsg}")
          raise errmsg
          Logger.debug("rose")
        end)
      rescue
        e in _ ->
          case e do
            %{message: msg} ->
              Logger.debug("Rescued")
              assert ^errmsg = msg
              :ok

            e ->
              Logger.debug(
                "Rescued unexcepted exception #{inspect(e)}\n#{inspect(__STACKTRACE__)}"
              )

              :ok
          end
      end
    end)

    wack.()
    assert %Lock{} = Mutex.await(@mut, :wrap1, 1000)
  end

  test "goodbye mechanism" do
    {ack, wack} = awack(:infinity)

    spawn_hang(fn ->
      Mutex.lock!(@mut, :hello_1)
      Mutex.lock!(@mut, :hello_2)
      Mutex.lock!(@mut, :hello_3)
      ack.()
      Process.sleep(1000)
      Mutex.goodbye(@mut)
    end)

    wack.()
    assert %Lock{} = Mutex.await(@mut, :hello_1, 2000)
    assert %Lock{} = Mutex.await(@mut, :hello_2, 2000)
    assert %Lock{} = Mutex.await(@mut, :hello_3, 2000)
  end

  test "mutex can hold metadata" do
    # Direct call

    {:ok, pid} = Mutex.start_link(meta: :some_data)
    assert :some_data = Mutex.get_meta(pid)

    # Simple value

    {:ok, pid} = Mutex.start_link(meta: :some_data)
    assert {:ok, lock} = Mutex.lock(pid, :some_key)
    assert lock.meta === :some_data
    assert Mutex.Lock.get_meta(lock) === :some_data
    assert %{meta: :some_data} = Mutex.await(pid, :a_key)
    assert %{meta: :some_data} = Mutex.await_all(pid, [:some_key_2, :other_key])

    # Data structure

    {:ok, pid} = Mutex.start_link(meta: %{some: [:nested, {:data, "structure"}]})
    assert {:ok, lock} = Mutex.lock(pid, :some_key)
    assert lock.meta === %{some: [:nested, {:data, "structure"}]}

    # Callbacks with 0 arity

    {:ok, pid} = Mutex.start_link(meta: :passed)

    Mutex.under(pid, :fun0, fn ->
      assert {:error, :busy} === Mutex.lock(pid, :fun0)
    end)

    Mutex.under_all(pid, [:fun0], fn ->
      assert {:error, :busy} === Mutex.lock(pid, :fun0)
    end)

    # Callbacks with 1 arity

    Mutex.under(pid, :fun1, fn lock ->
      assert lock.meta === :passed
      assert {:error, :busy} === Mutex.lock(pid, :fun1)
    end)

    Mutex.under_all(pid, [:fun1], fn lock ->
      assert lock.meta === :passed
      assert {:error, :busy} === Mutex.lock(pid, :fun1)
    end)

    # Releasing the lock in `under`

    result =
      Mutex.under(pid, :mess_with_me, fn lock ->
        assert lock.meta === :passed
        Mutex.release(pid, lock)
        :the_result
      end)

    # It should sill work (just log an error)
    assert result === :the_result

    assert {:ok, _} = Mutex.lock(pid, :mess_with_me)
  end

  test "under and under_all return values" do
    {:ok, pid} = Mutex.start_link()

    assert :some_val = Mutex.under(pid, :my_key, fn -> :some_val end)
    assert :some_val = Mutex.under(pid, :my_key, fn _lock -> :some_val end)
    assert :some_val = Mutex.under_all(pid, [:my_key, :my_other], fn -> :some_val end)
    assert :some_val = Mutex.under_all(pid, [:my_key, :my_other], fn _lock -> :some_val end)
  end

  test "error logger can log unknown compound keys on release" do
    {:ok, pid} = Mutex.start_link()
    {ack, wack} = vawack()

    key = [{:t1, %{"compound" => ~c"key"}}, {}, %{}, "hello", pid]

    tspawn(fn ->
      lock = Mutex.lock!(pid, key)
      Mutex.release(pid, lock)
      ack.(lock)
    end)

    lock = wack.()

    assert :ok = Mutex.release(pid, lock)

    GenServer.stop(pid)
  end

  test "error logger can log un-owned compound keys on release" do
    {:ok, pid} = Mutex.start_link()
    {ack, wack} = vawack()

    key = [{:t1, %{"compound" => ~c"key"}}, {}, %{}, "hello", pid]

    friend =
      tspawn(fn ->
        lock = Mutex.lock!(pid, key)
        ack.(lock)
        hang()
      end)

    lock = wack.()

    assert :ok = Mutex.release(pid, lock)

    send(friend, :stop)
    GenServer.stop(pid)
  end
end
