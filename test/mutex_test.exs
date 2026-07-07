defmodule MutexTest do
  alias Mutex.Lock
  alias Mutex.LockError
  alias Mutex.ReleaseError
  import Mutex.Test.Utils
  require Logger
  use ExUnit.Case, async: true

  doctest Mutex

  @moduletag :capture_log
  @moduletag timeout: 3000
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
    this = self()
    assert {:ok, %Lock{}} = Mutex.lock(@mut, :some_key)
    assert {:error, %LockError{key: :some_key, cause: {:locked, ^this}}} = Mutex.lock(@mut, :some_key)
  end

  test "can't acquire locked key" do
    {ack, wack} = awack()

    pid =
      xspawn(fn ->
        Mutex.lock!(@mut, :key1)

        ack.()
        hang()
      end)

    wack.()
    assert {:error, %LockError{key: :key1, cause: {:locked, ^pid}}} = Mutex.lock(@mut, :key1)
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
      assert {:error, %LockError{key: :inf_key, cause: {:locked, ^locker_pid}}} = Mutex.lock(@mut, :inf_key)
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

    pid =
      xspawn(fn ->
        lock = Mutex.lock!(@mut, :not_mine)
        ack.(lock)
        hang()
      end)

    lock = wack.()

    assert_raise ReleaseError, fn -> Mutex.release(@mut, lock) end
    assert {:error, %LockError{key: :not_mine, cause: {:locked, ^pid}}} = Mutex.lock(@mut, :not_mine)
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
    this = self()
    assert {:error, %LockError{key: :k2, cause: {:locked, ^this}}} = Mutex.lock(@mut, :k2)
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

  describe "receiving unexpected messages" do
    # The server must ignore stray messages instead of crashing: a crash
    # destroys all lock state, so owners would believe they still hold their
    # locks while a restarted, empty server grants the keys to anyone.

    test "a stray message does not crash the server nor lose the locks" do
      server_pid = Process.whereis(@mut)
      assert {:ok, %Lock{}} = Mutex.lock(@mut, :stray_key)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          send(@mut, :unexpected_garbage)

          # A synchronous call proves the stray message was handled, since
          # messages are processed in order. The key must still be locked.
          assert {:error, %LockError{cause: {:locked, _}}} = Mutex.lock(@mut, :stray_key)
        end)

      # The server was not restarted: same pid, still alive.
      assert ^server_pid = Process.whereis(@mut)
      assert Process.alive?(server_pid)

      # The stray message is logged with its content.
      assert log =~ ":unexpected_garbage"
    end

    test "waiters are still served after a stray message" do
      assert {:ok, lock} = Mutex.lock(@mut, :stray_wait_key)

      task = Task.async(fn -> Mutex.await(@mut, :stray_wait_key, 5_000) end)

      wait_for_waiter(@mut, :stray_wait_key)

      send(@mut, {:garbage, make_ref(), [self()]})
      :ok = Mutex.release(@mut, lock)

      assert %Lock{key: :stray_wait_key} = Task.await(task)
    end
  end

  describe "self-lock detection" do
    # Awaiting a key that the calling process already owns can never succeed,
    # since only the owner itself can release a key. This must raise instead
    # of deadlocking. The timeout guards against a regression to the deadlock
    # behavior.

    test "await on an owned key raises instead of deadlocking" do
      assert {:ok, _lock} = Mutex.lock(@mut, :self_key)

      err =
        assert_raise LockError, fn ->
          Mutex.await(@mut, :self_key, :infinity)
        end

      # The message must tell that the caller owns the key itself, not merely
      # that the key is busy.
      assert Exception.message(err) =~ ":self_key"
      assert Exception.message(err) =~ "own"
    end

    test "await with a finite timeout raises instead of exiting" do
      assert {:ok, _lock} = Mutex.lock(@mut, :self_key_tmo)

      # The long await timeout proves that detection is immediate: on
      # regression this test fails after 5 seconds, before the await gives up.
      assert_raise LockError, fn ->
        Mutex.await(@mut, :self_key_tmo, 60_000)
      end
    end

    test "the key is still locked after the raise" do
      this = self()
      assert {:ok, _lock} = Mutex.lock(@mut, :self_kept_key)

      assert_raise LockError, fn ->
        Mutex.await(@mut, :self_kept_key, :infinity)
      end

      assert {:error, %LockError{key: :self_kept_key, cause: {:locked, ^this}}} = Mutex.lock(@mut, :self_kept_key)
    end

    test "with_lock on an owned key raises without running the fun" do
      this = self()
      assert {:ok, _lock} = Mutex.lock(@mut, :self_wl_key)

      assert_raise LockError, fn ->
        Mutex.with_lock(@mut, :self_wl_key, fn -> send(this, :fun_ran) end)
      end

      refute_received :fun_ran
    end
  end

  describe "cleanup on owner death" do
    test "releasing one key does not stop the cleanup of remaining keys" do
      {ack, wack} = vawack()

      pid =
        xspawn(fn ->
          assert {:ok, lock_a} = Mutex.lock(@mut, :partial_a)
          assert {:ok, _lock_b} = Mutex.lock(@mut, :partial_b)
          :ok = Mutex.release(@mut, lock_a)
          ack.(:released)
          hang()
        end)

      assert :released = wack.()

      # The released key is available, the other one is still held.
      assert {:ok, _} = Mutex.lock(@mut, :partial_a)

      assert {:error, %LockError{key: :partial_b, cause: {:locked, ^pid}}} =
               Mutex.lock(@mut, :partial_b)

      kill(pid)

      # The owner death releases its remaining key.
      assert %Lock{} = Mutex.await(@mut, :partial_b)
    end
  end

  defp wait_for_waiter(mutex, key, attempts \\ 50)

  defp wait_for_waiter(_mutex, key, 0) do
    flunk("no waiter registered for key #{inspect(key)}")
  end

  defp wait_for_waiter(mutex, key, attempts) do
    case :sys.get_state(mutex) do
      %{waiters: %{^key => [_ | _]}} ->
        :ok

      _ ->
        Process.sleep(10)
        wait_for_waiter(mutex, key, attempts - 1)
    end
  end
end
