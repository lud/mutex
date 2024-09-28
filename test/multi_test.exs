defmodule Mutex.MultiTest do
  alias Mutex.Lock
  import Mutex.Test.Utils
  require Logger
  use ExUnit.Case, async: true

  @moduletag :capture_log
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

  # spawns a process that loop forever and locks <key> for <tin> time, release,
  # wait for <tout> time and start over
  defp spawn_single_locker(mutex, key, tin \\ 200, tout \\ 150) do
    tspawn(fn -> locker_loop(mutex, key, tin, tout) end)
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
        {name, spawn_monitor(fn -> under_loop(pid, name, keys, n_iter) end)}
      end)

    Enum.each(procs, fn {name, {pid, mref}} ->
      receive do
        {:DOWN, ^mref, :process, ^pid, ^name} -> :ok
      end
    end)
  end

  def under_loop(_mutex, name, _keys, 0) do
    exit(name)
  end

  def under_loop(mutex, name, keys, iterations) when iterations > 0 do
    _ = Mutex.under_all(mutex, keys, fn -> :ok end)

    iterations = iterations - 1

    under_loop(mutex, name, keys, iterations)
  end
end
