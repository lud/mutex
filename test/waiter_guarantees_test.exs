defmodule Mutex.WaiterGuaranteesTest do
  alias Mutex.Lock
  alias Mutex.LockError
  import Mutex.Test.Utils
  use ExUnit.Case, async: true

  # These tests pin the guarantees around waiters that stop waiting, either
  # because they rescued the timeout exit of `Mutex.await/3` or because they
  # were killed while waiting. They assert on observable behavior only (lock
  # ownership, message flows), so the grant mechanism on release can evolve
  # while keeping them green.

  @moduletag :capture_log
  @moduletag timeout: 5000
  @mut rand_mod()

  setup do
    {:ok, _pid} = start_supervised({Mutex, name: @mut})
    :ok
  end

  describe "waiters rescuing the timeout exit" do
    test "a rescued timeout leaves the key with its owner, then free after release" do
      this = self()
      {ack, wack} = vawack()

      assert {:ok, lock} = Mutex.lock(@mut, :tmo_key)

      waiter =
        xspawn(fn ->
          assert {:timeout, _} = catch_exit(Mutex.await(@mut, :tmo_key, 100))
          ack.(:timed_out)

          receive do
            :proceed -> :ok
          end

          # Give time for any late message to arrive before reporting.
          Process.sleep(100)
          ack.(flush_messages())
          hang()
        end)

      assert :timed_out = wack.()

      # The key is still owned by the test process.
      assert {:error, %LockError{key: :tmo_key, cause: {:locked, ^this}}} = Mutex.lock(@mut, :tmo_key)

      :ok = Mutex.release(@mut, lock)

      # After the release the key is immediately available to anyone, the
      # timed-out waiter has no claim on it.
      assert {:ok, _} = Mutex.lock(@mut, :tmo_key)

      # The rescued waiter is still alive and its mailbox is empty: rescuing
      # the timeout exposes no stray message from the mutex.
      send(waiter, :proceed)
      assert [] = wack.()
      assert Process.alive?(waiter)
    end

    test "a rescued waiter can wait again and acquire the key once released" do
      {ack, wack} = vawack()

      assert {:ok, lock} = Mutex.lock(@mut, :retry_key)

      waiter =
        xspawn(fn ->
          assert {:timeout, _} = catch_exit(Mutex.await(@mut, :retry_key, 100))
          ack.(:timed_out)

          assert %Lock{} = Mutex.await(@mut, :retry_key, 2000)
          ack.(:acquired)
          hang()
        end)

      assert :timed_out = wack.()

      :ok = Mutex.release(@mut, lock)

      assert :acquired = wack.()
      assert {:error, %LockError{key: :retry_key, cause: {:locked, ^waiter}}} = Mutex.lock(@mut, :retry_key)
    end

    test "a timeout on one key leaves the other keys of the waiter locked" do
      this = self()
      {ack, wack} = vawack()

      assert {:ok, _lock} = Mutex.lock(@mut, :busy_key)

      waiter =
        xspawn(fn ->
          Mutex.lock!(@mut, :kept_key)
          assert {:timeout, _} = catch_exit(Mutex.await(@mut, :busy_key, 100))
          ack.(:timed_out)
          hang()
        end)

      assert :timed_out = wack.()

      # The waiter still owns the key it locked before timing out.
      assert {:error, %LockError{key: :kept_key, cause: {:locked, ^waiter}}} = Mutex.lock(@mut, :kept_key)

      # And the contended key is still owned by the test process.
      assert {:error, %LockError{key: :busy_key, cause: {:locked, ^this}}} = Mutex.lock(@mut, :busy_key)
    end
  end

  describe "waiters killed while waiting" do
    test "the next live waiter acquires the key on release" do
      assert {:ok, lock} = Mutex.lock(@mut, :dead_key)

      # The killed waiter registers first so it sits before the live waiter in
      # the waiters list.
      first_waiter =
        xspawn(fn ->
          _ = Mutex.await(@mut, :dead_key, :infinity)
          hang()
        end)

      wait_for_waiting_pid(@mut, :dead_key, first_waiter)
      kill(first_waiter)

      {ack, wack} = vawack()

      live_waiter =
        xspawn(fn ->
          assert %Lock{} = Mutex.await(@mut, :dead_key, 2000)
          ack.(:acquired)
          hang()
        end)

      wait_for_waiting_pid(@mut, :dead_key, live_waiter)

      :ok = Mutex.release(@mut, lock)

      assert :acquired = wack.()
      assert {:error, %LockError{key: :dead_key, cause: {:locked, ^live_waiter}}} = Mutex.lock(@mut, :dead_key)
    end

    test "a key whose only waiter was killed becomes available on release" do
      assert {:ok, lock} = Mutex.lock(@mut, :corpse_key)

      waiter =
        xspawn(fn ->
          _ = Mutex.await(@mut, :corpse_key, :infinity)
          hang()
        end)

      wait_for_waiting_pid(@mut, :corpse_key, waiter)
      kill(waiter)

      :ok = Mutex.release(@mut, lock)

      # Awaiting rides through the cleanup of the killed waiter.
      assert %Lock{} = Mutex.await(@mut, :corpse_key, 1000)
    end
  end

  describe "interplay with multilocks" do
    test "await_all acquires a key that a timed-out waiter was waiting on" do
      {ack_owner, wack_owner} = vawack()
      {ack_waiter, wack_waiter} = vawack()
      {ack_multi, wack_multi} = vawack()

      owner =
        xspawn(fn ->
          lock = Mutex.lock!(@mut, :ml_busy)
          ack_owner.(:locked)

          receive do
            :release_now -> :ok = Mutex.release(@mut, lock)
          end

          hang()
        end)

      assert :locked = wack_owner.()

      # This waiter times out and stays alive, registered before the
      # multilocker in the waiters list.
      xspawn(fn ->
        assert {:timeout, _} = catch_exit(Mutex.await(@mut, :ml_busy, 100))
        ack_waiter.(:timed_out)
        hang()
      end)

      assert :timed_out = wack_waiter.()

      multilocker =
        xspawn(fn ->
          assert %Lock{type: :multi, keys: [:ml_busy, :ml_free]} = Mutex.await_all(@mut, [:ml_free, :ml_busy])
          ack_multi.(:locked_all)
          hang()
        end)

      wait_for_waiting_pid(@mut, :ml_busy, multilocker)

      send(owner, :release_now)

      assert :locked_all = wack_multi.()
      assert {:error, %LockError{key: :ml_busy, cause: {:locked, ^multilocker}}} = Mutex.lock(@mut, :ml_busy)
      assert {:error, %LockError{key: :ml_free, cause: {:locked, ^multilocker}}} = Mutex.lock(@mut, :ml_free)
    end

    test "each waiter receives its key when the owner of several keys dies" do
      {ack_owner, wack_owner} = vawack()
      {ack_a, wack_a} = vawack()
      {ack_b, wack_b} = vawack()

      owner =
        xspawn(fn ->
          Mutex.lock!(@mut, :die_a)
          Mutex.lock!(@mut, :die_b)
          ack_owner.(:locked)
          hang()
        end)

      assert :locked = wack_owner.()

      waiter_a =
        xspawn(fn ->
          assert %Lock{} = Mutex.await(@mut, :die_a, 2000)
          ack_a.(:got_a)
          hang()
        end)

      waiter_b =
        xspawn(fn ->
          assert %Lock{} = Mutex.await(@mut, :die_b, 2000)
          ack_b.(:got_b)
          hang()
        end)

      wait_for_waiting_pid(@mut, :die_a, waiter_a)
      wait_for_waiting_pid(@mut, :die_b, waiter_b)

      kill(owner)

      assert :got_a = wack_a.()
      assert :got_b = wack_b.()

      assert {:error, %LockError{key: :die_a, cause: {:locked, ^waiter_a}}} = Mutex.lock(@mut, :die_a)
      assert {:error, %LockError{key: :die_b, cause: {:locked, ^waiter_b}}} = Mutex.lock(@mut, :die_b)
    end
  end

  defp flush_messages(acc \\ []) do
    receive do
      msg -> flush_messages([msg | acc])
    after
      0 -> :lists.reverse(acc)
    end
  end
end
