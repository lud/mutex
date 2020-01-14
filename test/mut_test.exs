defmodule MutexTest do
  use ExUnit.Case, async: true
  doctest Mutex
  @mut TestMutex
  require Logger
  alias Mutex.Lock

  setup_all do
    children = [
      {Mutex, name: @mut, meta: :test_mutex}
    ]

    {:ok, _pid} = Supervisor.start_link(children, strategy: :one_for_one)
    :ok
  end

  test "bad example README" do
    update_user = fn worker ->
      IO.puts("[#{worker}] Reading user from database.")
      Process.sleep(250)
      IO.puts("[#{worker}] Working with user.")
      Process.sleep(250)
      IO.puts("[#{worker}] Saving user in database.")
    end

    spawn(fn -> update_user.("worker 1") end)
    spawn(fn -> update_user.("worker 2") end)
    spawn(fn -> update_user.("worker 3") end)
  end

  test "good example README" do
    resource_id = {User, {:id, 1}}

    update_user = fn worker ->
      lock = Mutex.await(@mut, resource_id)
      IO.puts("[#{worker}] Reading user from database.")
      Process.sleep(250)
      IO.puts("[#{worker}] Working with user.")
      Process.sleep(250)
      IO.puts("[#{worker}] Saving user in database.")
      Mutex.release(@mut, lock)
    end

    spawn(fn -> update_user.("worker 4") end)
    spawn(fn -> update_user.("worker 5") end)
    spawn(fn -> update_user.("worker 6") end)
  end

  test "mutex can start" do
    assert is_pid(Process.whereis(@mut))
  end

  test "can acquire lock (can lock key)" do
    assert {:ok, %Lock{meta: :test_mutex}} = Mutex.lock(@mut, :some_key)
  end

  test "can't acquire locked key" do
    {ack, wack} = awack()

    spawn(fn ->
      Mutex.lock!(@mut, :key1)
      ack.()
      Process.sleep(1000)
    end)

    wack.()
    assert {:error, :busy} = Mutex.lock(@mut, :key1)
  end

  test "can't release a key if not owner or if not registered" do
    {ack, wack} = awack()

    spawn(fn ->
      Mutex.lock!(@mut, :not_mine)
      ack.()
      Process.sleep(1000)
    end)

    wack.()
    # It's a cast() so it always return ok
    assert :ok = Mutex.release(@mut, %Lock{type: :single, key: :not_mine})
    assert {:error, :busy} = Mutex.lock(@mut, :not_mine)
    assert :ok = Mutex.release(@mut, %Lock{type: :single, key: :unregistered_key})
    # trying with multiple keys this process registers 2 keys. Then a concurrent
    # process try to acquire them.
    # The first process release those keys but with other inexistent keys.
    # The second process must be able to lock the keys in the end
    {ack, wack} = awack()
    lock = Mutex.await_all(@mut, [:all_1, :all_2])
    Process.sleep(200)

    spawn(fn ->
      Mutex.await_all(@mut, [:all_2, :all_1])
      ack.()
    end)

    :ok = Mutex.release(@mut, lock)
    assert :ok = wack.()
  end

  test "can wait for key is released when owner dies" do
    {ack, wack} = awack()

    spawn(fn ->
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
      spawn(fn ->
        Mutex.lock!(@mut, :key3)
        ack.()
        Process.sleep(10_0000)
      end)

    wack.()
    assert {:timeout, _} = catch_exit(Mutex.await(@mut, :key3, 500))
    Process.exit(pid, :normal)
  end

  test "can wait infinitely" do
    {ack, wack} = awack()

    locker_pid =
      spawn(fn ->
        Mutex.lock!(@mut, :inf_key)
        ack.()
        hang()
      end)

    wack.()
    {ack, wack} = awack(:infinity)

    spawn(fn ->
      assert {:error, :busy} = Mutex.lock(@mut, :inf_key)
      assert %Lock{} = Mutex.await(@mut, :inf_key, :infinity)
      ack.()
    end)

    kill(locker_pid, 1000)
    refute Process.alive?(locker_pid)
    # the second process managed to lock
    assert :ok = wack.()
  end

  test "Bad Concurrency" do
    filename = "test/tmp/wrong-file.txt"
    setup_test_file(filename)

    for _ <- 1..10 do
      {ack, wack} = awack()

      spawn(fn ->
        dummy_increment_file(filename)
        ack.()
      end)

      wack
    end
    |> Enum.each(fn wack -> wack.() end)

    # file val was read from all process at 0, then written incremented
    # so the file is "1"
    assert "1" = File.read!(filename)
  end

  test "Mutexex Concurrency" do
    filename = "test/tmp/good-file.txt"
    setup_test_file(filename)

    for _ <- 1..10 do
      {ack, wack} = awack(10_000)

      spawn(fn ->
        assert (lock = %Lock{}) = Mutex.await(@mut, :good_file, 5000)
        dummy_increment_file(filename)
        assert :ok = Mutex.release(@mut, lock)
        # ensure release is useful
        Process.sleep(1000)
        ack.()
      end)

      wack
    end
    |> Enum.map(fn wack -> wack.() end)

    # file val was read from all process at 0, then written incremented
    # so the file is "1"
    assert "10" = File.read!(filename)
  end

  test "Multilocks" do
    lockers =
      for i <- 1..3,
          k <- [:a, :b, :c, :d, :e, :f] do
        key = {k, i}
        pid = spawn_locker(@mut, key)
        {pid, key}
      end

    {cleanup_pids, _} = lockers |> Enum.unzip()
    Process.sleep(200)
    # We spawn processes that will attemp to lock all their given
    # keys. All the keys list share some common keys. When done, they
    # call their ack function. We will wait for all the acks to be
    # received (with wacks), which means that all the locking
    # processes have managed to lock their keys.

    # The test is that with competing keys, and single-keys
    # competitors, The processes can still manage to lock multiple
    # keys.
    wacks =
      for i <- 1..3 do
        # spawn 3 process locking with competing keys
        keys3 = [c: i, d: i, e: i, f: i] |> Enum.shuffle()
        keys2 = [b: i, c: i, d: i, e: i] |> Enum.shuffle()
        keys1 = [a: i, b: i, c: i, d: i] |> Enum.shuffle()

        locker = fn ack, keys ->
          lock = Mutex.await_all(@mut, keys)
          Process.sleep(1000)
          Mutex.release(@mut, lock)
          ack.()
        end

        {ack1, wack1} = awack(:infinity)
        {ack2, wack2} = awack(:infinity)
        {ack3, wack3} = awack(:infinity)
        spawn(fn -> locker.(ack1, keys1) end)
        spawn(fn -> locker.(ack2, keys2) end)
        spawn(fn -> locker.(ack3, keys3) end)
        # return the wacks
        [wack1, wack2, wack3]
      end

    wacks
    |> List.flatten()
    |> Enum.each(fn wack -> :ok = wack.() end)

    Process.sleep(1000)
    assert %Lock{} = Mutex.await(@mut, :multi_1, :infinity)

    cleanup_pids
    |> Enum.each(&kill(&1))
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
                "Rescued unexcepted exception #{inspect(e)}\n#{inspect(System.stacktrace())}"
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
      IO.inspect(lock, pretty: true, label: :lock)
      assert lock.meta === :passed
      assert {:error, :busy} === Mutex.lock(pid, :fun1)
    end)

    Mutex.under_all(pid, [:fun1], fn lock ->
      IO.inspect(lock, pretty: true, label: :lock)
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

  test "Many many processes" do
    {:ok, pid} = Mutex.start_link()
    iterations = 10000

    [
      Task.async(fn -> under_loop(pid, :my_key, iterations) end),
      Task.async(fn -> under_loop(pid, :my_key, iterations) end),
      Task.async(fn -> under_loop(pid, :my_key, iterations) end),
      Task.async(fn -> under_loop(pid, :my_key, iterations) end)
    ]
    |> Enum.map(&Task.await(&1, :infinity))
  end

  # -- helpers --------------------------------------------------------------

  # spawns a process that loop forever and locks <key> for <tin> time, release,
  # wait for <tout> time and start over
  def spawn_locker(mutex, key, tin \\ 200, tout \\ 150) do
    spawn(fn -> locker_loop(mutex, key, tin, tout) end)
  end

  def locker_loop(mutex, key, tin, tout) do
    (lock = %Lock{}) = Mutex.await(mutex, key, :infinity)
    Process.sleep(tin)
    :ok = Mutex.release(mutex, lock)
    Process.sleep(tout)
    locker_loop(mutex, key, tin, tout)
  end

  def under_loop(mutex, key, 0),
    do: :ok

  def under_loop(mutex, key, iterations) when iterations > 0 do
    Mutex.under(mutex, key, fn ->
      _dummy_calculation = 1234 * 1235
    end)

    under_loop(mutex, key, iterations - 1)
  end

  def setup_test_file(filename) do
    File.rm(filename)
    File.write!(filename, "0")
  end

  def dummy_increment_file(filename, sleep \\ 100) do
    # Dummy function that read, parse and write incremented value from file in a
    # stupid way that allows simple writes race conditions fully enabled ;)
    {value, ""} =
      File.read!(filename)
      |> Integer.parse()

    Process.sleep(sleep)
    File.write!(filename, Integer.to_string(value + 1))
  end

  def awack(timeout \\ 5000) do
    this = self()
    ref = make_ref()

    ack = fn ->
      send(this, ref)
    end

    wack = fn ->
      receive do
        ^ref -> :ok
      after
        timeout -> exit(:timeout)
      end
    end

    {ack, wack}
  end

  def spawn_hang(fun) do
    spawn_link(fn ->
      fun.()
      hang()
    end)
  end

  def hang do
    receive do
      :stop -> Logger.debug("Hangin stops")
    end
  end

  def kill(pid, sleep \\ 0) do
    Process.sleep(sleep)
    Process.exit(pid, :kill)
  end
end
