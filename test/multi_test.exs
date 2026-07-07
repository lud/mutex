defmodule Mutex.MultiTest do
  alias Mutex.Lock
  alias Mutex.LockError
  import Mutex.Test.Utils
  use ExUnit.Case, async: true

  @moduletag :capture_log
  @moduletag timeout: 5000
  @mut rand_mod()

  setup do
    {:ok, _pid} = start_supervised({Mutex, name: @mut})
    :ok
  end

  test "multilocks" do
    letters = ?a..?f |> Enum.map(&:"#{[&1]}")

    # Spawn processes, each one with a given key like {:a, 1}, {:f, 2}, etc.
    # Each process will lock its key, then
    # sleep, then release, then sleep, then repeat that infinitely. They sleep
    # after release so our other processes that will try to lock all the keys
    # have a chance to do so.

    all_keys = for c <- letters, i <- 1..3, do: {c, i}

    all_keys
    |> Enum.shuffle()
    |> Enum.map(fn key ->
      spawn_single_locker(@mut, key)
    end)

    # Wait so some of the single-key lockers have a chance to lock
    Process.sleep(200)

    # Now we spawn processes that will attemp to lock multiple keys from the
    # given list. They should be able to do so despite the noise.
    #
    #  When done, they call their ack function. We will wait for all the acks to
    # be received (with wacks), which means that all the locking processes have
    # managed to lock their keys.

    task_1s = spawn_multi_locker(@mut, Enum.shuffle(for c <- letters, do: {c, 1}))
    task_2s = spawn_multi_locker(@mut, Enum.shuffle(for c <- letters, do: {c, 2}))
    task_3s = spawn_multi_locker(@mut, Enum.shuffle(for c <- letters, do: {c, 3}))

    assert :ok = Task.await(task_1s, :infinity)
    assert :ok = Task.await(task_2s, :infinity)
    assert :ok = Task.await(task_3s, :infinity)

    assert %Lock{} = Mutex.await(@mut, :multi_1, :infinity)
  end

  test "accepts a single key" do
    assert %Mutex.Lock{keys: [:hello], type: :multi} = Mutex.await_all(@mut, [:hello])
  end

  describe "rejecting duplicate keys" do
    # If the caller passes the same key twice, awaiting all keys would make the
    # caller await a key it just locked itself, deadlocking forever. This must
    # raise instead. The timeout guards against a regression to the deadlock
    # behavior.

    test "await_all raises on duplicate keys" do
      err =
        assert_raise ArgumentError, fn ->
          Mutex.await_all(@mut, [:k1, :dup, :dup])
        end

      assert err.message =~ "duplicate"
      assert err.message =~ ":dup"
    end

    test "no key is locked when duplicates are rejected" do
      # The raise must happen in the caller, before any key is locked, so
      # all of the given keys can immediately be locked.
      assert_raise ArgumentError, fn ->
        Mutex.await_all(@mut, [:x, :y, :x])
      end

      assert {:ok, %Lock{}} = Mutex.lock(@mut, :x)
      assert {:ok, %Lock{}} = Mutex.lock(@mut, :y)
    end

    test "with_lock_all raises on duplicate keys without running the fun" do
      test_pid = self()

      err =
        assert_raise ArgumentError, fn ->
          Mutex.with_lock_all(@mut, [:dup, :dup], fn -> send(test_pid, :fun_ran) end)
        end

      assert err.message =~ "duplicate"
      assert err.message =~ ":dup"
      refute_received :fun_ran
    end

    test "keys are compared with strict equality" do
      # 1 and 1.0 compare as equal with ==/2 but are distinct lock keys, as
      # keys are stored in a map. They must not be treated as duplicates.
      assert %Lock{type: :multi, keys: keys} = Mutex.await_all(@mut, [1, 1.0])
      assert 2 == length(keys)
    end
  end

  describe "self-lock detection with multiple keys" do
    # See the "self-lock detection" tests in mutex_test.exs for single keys.
    # The timeout guards against a regression to the deadlock behavior.

    test "await_all raises on a partially owned keys list, leaving no partial locks" do
      this = self()

      # :zzz sorts last, so await_all acquires :aaa before detecting the
      # self-lock on :zzz. The raise must not leak the :aaa lock.
      assert {:ok, _lock} = Mutex.lock(@mut, :zzz)

      assert_raise LockError, fn ->
        Mutex.await_all(@mut, [:aaa, :zzz])
      end

      assert {:ok, %Lock{}} = Mutex.lock(@mut, :aaa)
      assert {:error, %LockError{cause: {:locked, ^this}}} = Mutex.lock(@mut, :zzz)
    end

    test "await_all raises when the first sorted key is owned" do
      # The self-lock is detected before any key is acquired, so the failure
      # path releases an empty list of keys.
      assert {:ok, _lock} = Mutex.lock(@mut, :aaa)

      assert_raise LockError, fn ->
        Mutex.await_all(@mut, [:aaa, :zzz])
      end

      assert {:ok, %Lock{}} = Mutex.lock(@mut, :zzz)
    end
  end

  # spawns a process that loop forever and locks <key> for <tin> time, release,
  # wait for <tout> time and start over
  defp spawn_single_locker(mutex, key, tin \\ 200, tout \\ 150) do
    xspawn(fn -> locker_loop(mutex, key, tin, tout) end)
  end

  defp locker_loop(mutex, key, tin, tout) do
    (lock = %Lock{}) = Mutex.await(mutex, key, :infinity)
    Process.sleep(tin)
    :ok = Mutex.release(mutex, lock)
    Process.sleep(tout)
    locker_loop(mutex, key, tin, tout)
  end

  defp spawn_multi_locker(mutex, keys) do
    Task.async(fn ->
      Mutex.await_all(mutex, keys)
      Process.sleep(100)
      :ok
    end)
  end

  test "multilocks with many processes" do
    {:ok, pid} = Mutex.start_link()
    n_processes = 40
    n_iter = 20

    spawn_specs =
      for i <- 1..n_processes do
        # by taking keys from this list but starting at different point we make
        # the processes wait for the keys. For instance process 1 wants :k1,:k2
        # and process 2 wants :k2,:k3 ; process 2 will ask :k2 while process 1
        # is asking :k1 and will ask :k2 later, it's gonna be locked.
        #
        # Of course there is a delay when spawning a process so it may be slow.
        # We will not use tasks for this test.
        {"t#{i}", [:k1, :k2, :k3, :k4, :k5] |> Enum.shuffle() |> Enum.take(3)}
      end

    procs =
      Enum.map(spawn_specs, fn {name, keys} ->
        task = Task.async(fn -> with_lock_loop(pid, name, keys, n_iter) end)
        {name, task}
      end)

    Enum.each(procs, fn {name, task} ->
      assert ^name = Task.await(task, :infinity)
    end)
  end

  def with_lock_loop(_mutex, name, _keys, 0) do
    name
  end

  def with_lock_loop(mutex, name, keys, iterations) when iterations > 0 do
    _ = Mutex.with_lock_all(mutex, keys, fn -> :ok end)

    iterations = iterations - 1

    with_lock_loop(mutex, name, keys, iterations)
  end
end
