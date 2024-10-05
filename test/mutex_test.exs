defmodule MutexTest do
  alias Mutex.Lock
  alias Mutex.LockError
  alias Mutex.ReleaseError
  import Mutex.Test.Utils
  require Logger
  use ExUnit.Case, async: true

  doctest Mutex

  @moduletag :capture_log
  @mut rand_mod()

  setup do
    {:ok, _pid} = start_supervised({Mutex, name: @mut})
    :ok
  end

  test "mutex can start" do
    assert is_pid(Process.whereis(@mut))
  end

  test "can acquire lock" do
    assert {:ok, %Lock{}} = Mutex.lock(@mut, :some_key)
  end

  test "cannot acquire twice" do
    assert {:ok, %Lock{}} = Mutex.lock(@mut, :some_key)
    assert {:error, :busy} = Mutex.lock(@mut, :some_key)
  end

  test "can't acquire locked key" do
    {ack, wack} = awack()

    xspawn(fn ->
      Mutex.lock!(@mut, :key1)

      ack.()
      hang()
    end)

    wack.()
    assert {:error, :busy} = Mutex.lock(@mut, :key1)
    err = catch_error(Mutex.lock!(@mut, :key1))
    assert %LockError{key: :key1} = err
    assert Exception.message(err) =~ "key1"
  end

  test "can wait for key is released when owner dies" do
    {ack, wack} = awack()

    xspawn(fn ->
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
      xspawn(fn ->
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

    xspawn(fn ->
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
        Mutex.with_lock(@mut, :wrap1, :infinity, fn ->
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
      Mutex.with_lock(@mut, :wrap2, :infinity, fn ->
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
        Mutex.with_lock_all(@mut, keys, fn ->
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
              Logger.debug("Rescued unexcepted exception #{inspect(e)}\n#{inspect(__STACKTRACE__)}")

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

  test "can't release a key if not owner" do
    {ack, wack} = vawack()

    xspawn(fn ->
      lock = Mutex.lock!(@mut, :not_mine)
      ack.(lock)
      hang()
    end)

    lock = wack.()

    assert_raise ReleaseError, fn -> Mutex.release(@mut, lock) end
    assert {:error, :busy} = Mutex.lock(@mut, :not_mine)
  end

  test "can't release a key if not owner (async)" do
    {ack, wack} = vawack()

    xspawn(fn ->
      lock = Mutex.lock!(@mut, :not_mine)
      ack.(lock)
      hang()
    end)

    lock = wack.()

    # release_async is a gen:cast() so it always returns :ok
    assert :ok = Mutex.release_async(@mut, lock)
  end

  test "can't release a key if it does not exist" do
    assert_raise ReleaseError, fn -> Mutex.release(@mut, %Lock{type: :single, key: :unregistered_key}) end
  end

  test "can't release a key if not owner or if not registered (async)" do
    # Not sure what to test here
    assert :ok = Mutex.release_async(@mut, %Lock{type: :single, key: :unregistered_key})
    assert :ok = Mutex.release_async(@mut, %Lock{type: :single, key: :unregistered_key})
  end

  test "releasing multilocks with unknown keys" do
    # Lock k1,k2
    lock = Mutex.await_all(@mut, [:k1, :k2])

    # Release k1
    assert :ok = Mutex.release(@mut, %Lock{type: :single, key: :k1})

    # Cannot release both k1,k2
    assert_raise ReleaseError, fn -> Mutex.release(@mut, lock) end

    # Still owning k2
    assert {:error, :busy} = Mutex.lock(@mut, :k2)
    assert self() == Mutex.whereis_name({@mut, :k2})
  end

  test "with_lock and with_lock_all return values" do
    {:ok, pid} = Mutex.start_link()

    assert :some_val = Mutex.with_lock(pid, :my_key, fn -> :some_val end)
    assert :some_val = Mutex.with_lock(pid, :my_key, fn _lock -> :some_val end)
    assert :some_val = Mutex.with_lock_all(pid, [:my_key, :my_other], fn -> :some_val end)
    assert :some_val = Mutex.with_lock_all(pid, [:my_key, :my_other], fn _lock -> :some_val end)
  end

  test "error logger can log unknown compound keys on release" do
    {:ok, pid} = Mutex.start_link()
    {ack, wack} = vawack()

    key = [{:t1, %{"compound" => ~c"key"}}, {}, %{}, "hello", pid]

    xspawn(fn ->
      lock = Mutex.lock!(pid, key)
      Mutex.release(pid, lock)
      ack.(lock)
    end)

    lock = wack.()

    assert :ok = Mutex.release_async(pid, lock)

    GenServer.stop(pid)
  end

  @tag capture_log: false
  test "error logger can log un-owned compound keys on release" do
    # This test was created after a but where we would log the key without using
    # inspect/1.
    {:ok, pid} = Mutex.start_link()
    {ack, wack} = vawack()

    key = [{:t1, %{"compound" => ~c"key"}}, {}, %{}, "hello", pid]

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        xspawn(fn ->
          lock = Mutex.lock!(pid, key)
          ack.(lock)
          hang()
        end)

        lock = wack.()

        assert :ok = Mutex.release_async(pid, lock)

        GenServer.stop(pid)
      end)

    # log has color and formatting
    IO.puts(["\n", log])

    generic = "Could not release key asynchronously"
    formatted_key = inspect(key)
    assert log =~ generic
    assert log =~ formatted_key
  end
end
