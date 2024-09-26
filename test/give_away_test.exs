defmodule Mutex.ReadmeTest do
  alias Mutex.Lock
  import Mutex.Test.Utils
  require Logger
  use ExUnit.Case, async: true

  @moduletag :capture_log
  @mut rand_mod()

  setup do
    {:ok, _pid} = start_supervised({Mutex, name: @mut, meta: :test_mutex})
    :ok
  end

  test "can't release a key if not owner or if not registered" do
    {ack, wack} = vawack()

    tspawn(fn ->
      lock = Mutex.lock!(@mut, :not_mine)
      ack.(lock)
      hang()
    end)

    lock = wack.()

    # release is a gen:cast() so it always returns :ok

    # cannot release a lock owned by someone else
    assert :ok = Mutex.release(@mut, lock)
    assert {:error, :busy} = Mutex.lock(@mut, :not_mine)

    # Cannot release an unknown key
    assert :ok = Mutex.release(@mut, %Lock{type: :single, key: :unregistered_key})
    assert {:ok, _} = Mutex.lock(@mut, :unregistered_key)

    # trying with multiple keys:
    # * This process registers 2 keys. Then a concurrent process try to acquire
    #   them.
    # * The first process release those keys but with other inexistent keys.
    # * The second process must be able to lock the keys in the end
    {ack, wack} = awack()
    lock = Mutex.await_all(@mut, [:all_1, :all_2])

    tspawn(fn ->
      Mutex.await_all(@mut, [:all_2, :all_1])
      ack.()
    end)

    :ok = Mutex.release(@mut, %{lock | keys: [:other_1, :all_2, :other_2, :all_1, :other_3]})
    assert :ok = wack.()
  end
end
