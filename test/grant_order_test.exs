defmodule Mutex.GrantOrderTest do
  alias Mutex.Lock
  import Mutex.Test.Utils
  use ExUnit.Case, async: true

  # When a key is released, its ownership is transferred to the process that
  # has been waiting for the longest time.

  @moduletag :capture_log
  @moduletag timeout: 5000
  @mut rand_mod()

  setup do
    {:ok, _pid} = start_supervised({Mutex, name: @mut})
    :ok
  end

  test "waiters acquire the key in order of arrival" do
    {ack, wack} = vawack()

    assert {:ok, lock} = Mutex.lock(@mut, :fifo_key)

    for i <- 1..5 do
      waiter =
        xspawn(fn ->
          wlock = Mutex.await(@mut, :fifo_key, 2000)
          ack.(i)
          :ok = Mutex.release(@mut, wlock)
          hang()
        end)

      wait_for_waiting_pid(@mut, :fifo_key, waiter)
    end

    :ok = Mutex.release(@mut, lock)

    assert [1, 2, 3, 4, 5] = Enum.map(1..5, fn _ -> wack.() end)
  end

  test "a timed-out waiter passes its turn to the next waiter in line" do
    {ack, wack} = vawack()

    assert {:ok, lock} = Mutex.lock(@mut, :skip_key)

    first =
      xspawn(fn ->
        assert {:timeout, _} = catch_exit(Mutex.await(@mut, :skip_key, 100))
        ack.(:timed_out)
        hang()
      end)

    wait_for_waiting_pid(@mut, :skip_key, first)

    second =
      xspawn(fn ->
        assert %Lock{} = Mutex.await(@mut, :skip_key, 2000)
        ack.(:acquired)
        hang()
      end)

    wait_for_waiting_pid(@mut, :skip_key, second)

    assert :timed_out = wack.()

    :ok = Mutex.release(@mut, lock)

    assert :acquired = wack.()
  end

  test "a killed waiter passes its turn to the next waiter in line" do
    {ack, wack} = vawack()

    assert {:ok, lock} = Mutex.lock(@mut, :skip_dead_key)

    first =
      xspawn(fn ->
        _ = Mutex.await(@mut, :skip_dead_key, :infinity)
        hang()
      end)

    wait_for_waiting_pid(@mut, :skip_dead_key, first)
    kill(first)

    second =
      xspawn(fn ->
        assert %Lock{} = Mutex.await(@mut, :skip_dead_key, 2000)
        ack.(:acquired)
        hang()
      end)

    wait_for_waiting_pid(@mut, :skip_dead_key, second)

    :ok = Mutex.release(@mut, lock)

    assert :acquired = wack.()
  end

  test "giving away a key transfers ownership to the heir, waiters keep waiting" do
    {ack, wack} = vawack()

    assert {:ok, lock} = Mutex.lock(@mut, :gift_key)

    waiter =
      xspawn(fn ->
        assert %Lock{} = Mutex.await(@mut, :gift_key, 2000)
        ack.(:waiter_acquired)
        hang()
      end)

    wait_for_waiting_pid(@mut, :gift_key, waiter)

    heir =
      xspawn(fn ->
        receive do
          {:"MUTEX-TRANSFER", _from, hlock, _gift_data} ->
            ack.(:transfer_received)

            receive do
              :release -> :ok = Mutex.release(@mut, hlock)
            end

            hang()
        end
      end)

    :ok = Mutex.give_away(@mut, lock, heir)

    assert :transfer_received = wack.()

    # The heir owns the key and the waiter is still in line
    assert heir == Mutex.whereis_name({@mut, :gift_key})
    wait_for_waiting_pid(@mut, :gift_key, waiter)

    # The waiter acquires the key once the heir releases it
    send(heir, :release)
    assert :waiter_acquired = wack.()
  end

  test "a waiter timing out while being granted the key leaves the key available" do
    {ack, wack} = vawack()

    assert {:ok, lock} = Mutex.lock(@mut, :cross_key)

    waiter =
      xspawn(fn ->
        assert {:timeout, _} = catch_exit(Mutex.await(@mut, :cross_key, 200))
        ack.(:timed_out)
        hang()
      end)

    wait_for_waiting_pid(@mut, :cross_key, waiter)

    # Suspending the server queues the release before the waiter's timeout
    # cancellation: the grant and the cancellation cross in flight.
    :ok = :sys.suspend(@mut)
    :ok = Mutex.release_async(@mut, lock)

    # Leaves enough time for the waiter timeout to fire, so its cancellation
    # is queued behind the release while the server is suspended.
    Process.sleep(600)

    :ok = :sys.resume(@mut)

    assert :timed_out = wack.()

    # The key ends up available for the next taker
    assert %Lock{} = Mutex.await(@mut, :cross_key, 2000)
  end
end
