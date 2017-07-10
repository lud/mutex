defmodule MutexTest do
  use ExUnit.Case, async: true
  doctest Mutex
  @mut TestMutex
  require Logger

  @moduletag skip: false

  setup_all do
    children = [
      Mutex.child_spec(@mut)
    ]
    {:ok, _pid} = Supervisor.start_link(children, strategy: :one_for_one)
    :ok
  end

  test "mutex can start" do
    assert is_pid(Process.whereis(@mut))
  end

  test "can acquire lock (can lock key)" do
    assert :ok = Mutex.lock(@mut, :some_key)
  end

  test "can't acquire locked key" do
    {ack, wack} = awack()
    spawn(fn() ->
      Mutex.lock!(@mut, :key1)
      ack.()
      Process.sleep(1000)
    end)
    wack.()
    assert {:error, :busy} = Mutex.lock(@mut, :key1)
  end

  test "can't release a key if not owner or if not registered" do
    {ack, wack} = awack()
    spawn(fn() ->
      Mutex.lock!(@mut, :not_mine)
      ack.()
      Process.sleep(1000)
    end)
    wack.()
    # It's a cast() so it always return ok
    assert :ok = Mutex.release(@mut, :not_mine)
    assert {:error, :busy} = Mutex.lock(@mut, :not_mine)
    assert :ok = Mutex.release(@mut, :unregistered_key)
    # trying with multiple keys this process registers 2 keys. Then a concurrent
    # process try to acquire them.
    # The first process release those keys but with other inexistent keys.
    # The second process must be able to lock the keys in the end
    {ack, wack} = awack()
    :ok = Mutex.await_all(@mut, [:all_1, :all_2])
    Process.sleep(200)
    spawn(fn ->
      :ok = Mutex.await_all(@mut, [:all_2, :all_1])
      ack.()
    end)
    :ok = Mutex.release_all(@mut, [:all_missing, :all_1, :all_missing_2, :all_2])
    assert :ok = wack.()
  end

  test "can wait for key is released when owner dies" do
    {ack, wack} = awack()
    spawn(fn() ->
      Mutex.lock!(@mut, :key2)
      ack.()
      Process.sleep(100)
    end)
    wack.()
    assert :ok = Mutex.await(@mut, :key2, 500)
  end

  test "a wait-for-lock should timeout" do
    {ack, wack} = awack()
    pid = spawn(fn() ->
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
    locker_pid = spawn(fn() ->
      Mutex.lock!(@mut, :inf_key)
      ack.()
      hang()
    end)
    wack.()
    {ack, wack} = awack(:infinity)
    spawn(fn() ->
      assert {:error, :busy} = Mutex.lock(@mut, :inf_key)
      assert :ok = Mutex.await(@mut, :inf_key, :infinity)
      ack.()
    end)
    kill_after(locker_pid, 1000)
    refute Process.alive?(locker_pid)
    assert :ok = wack.() # the second process managed to lock
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
    |> Enum.each(fn(wack) -> wack.() end)
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
        assert :ok = Mutex.await(@mut, :good_file, 5000)
        dummy_increment_file(filename)
        assert :ok = Mutex.release(@mut, :good_file)
        Process.sleep(1000) # ensure release is useful
        ack.()
      end)
      wack
    end
    |> Enum.map(fn(wack) -> wack.() end)
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

    {cleanup_pids, _} = lockers |> Enum.unzip
    Process.sleep(200)
    for i <- 1..3 do
      # spawn 3 process locking with competing keys
      key3 = [c: i, d: i, e: i, f: i] |> Enum.shuffle()
      key2 = [b: i, c: i, d: i, e: i] |> Enum.shuffle()
      key1 = [a: i, b: i, c: i, d: i] |> Enum.shuffle()
      {ack, wack1} = awack(:infinity)
      spawn(fn() ->
        Mutex.await_all(@mut, key1)
        Process.sleep(1000)
        Mutex.release_all(@mut, key1)
        ack.()
      end)
      {ack, wack2} = awack(:infinity)
      spawn(fn() ->
        Mutex.await_all(@mut, key2)
        Process.sleep(1000)
        Mutex.release_all(@mut, key2)
        ack.()
      end)
      {ack, wack3} = awack(:infinity)
      spawn(fn() ->
        Mutex.await_all(@mut, key3)
        Process.sleep(1000)
        Mutex.release_all(@mut, key3)
        ack.()
      end)
      [wack1, wack2, wack3]
    end
    |> List.flatten
    |> Enum.each(fn(wack) -> :ok = wack.() end)
    Process.sleep(1000)
    assert :ok = Mutex.await(@mut, :multi_1, :infinity)
    cleanup_pids
      |> Enum.each(&kill_after(&1))
  end

  test "if a fun throws within wrapper, the lock should be released" do
    {ack, wack} = awack(:infinity)
    stoppable = spawn_hang(fn ->
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
    assert :ok = Mutex.await(@mut, :wrap1, 1000)
    kill_after(stoppable)
  end

  test "if a fun raises within wrapper with multilock it should be fine" do
    {ack, wack} = awack(:infinity)
    errmsg = "You failed me !"
    stoppable = spawn_hang(fn ->
      try do
        Mutex.under(@mut, :wrap1, :infinity, fn ->
          ack.()
          Logger.debug "Will raise #{errmsg}"
          raise errmsg
          Logger.debug "rose"
        end)
      rescue
        e in _ ->
          Logger.debug "Rescued"
          assert ^errmsg = e.message
          :ok
      end
    end)
    wack.()
    assert :ok = Mutex.await(@mut, :wrap1, 1000)
  end

  @tag skip: false
  test "goodbye mechanism" do
    {ack, wack} = awack(:infinity)
    spawn_hang(fn() ->
      Mutex.lock!(@mut, :hello_1)
      Mutex.lock!(@mut, :hello_2)
      Mutex.lock!(@mut, :hello_3)
      ack.()
      Process.sleep(1000)
      Mutex.goodbye(@mut)
    end)
    wack.()
    assert :ok = Mutex.await(@mut, :hello_1, 2000)
    assert :ok = Mutex.await(@mut, :hello_2, 2000)
    assert :ok = Mutex.await(@mut, :hello_3, 2000)
  end

  # -- helpers --------------------------------------------------------------

  # spawns a process that loop forever and locks <key> for <tin> time, release,
  # wait for <tout> time and start over
  def spawn_locker(mut, key, tin \\ 200, tout \\ 150) do
    spawn(fn() ->
      locker_loop(mut, key, tin, tout)
    end)
  end

  def locker_loop(mut, key, tin, tout) do
    :ok = Mutex.await(mut, key, :infinity)
    Process.sleep(tin)
    :ok = Mutex.release(mut, key)
    Process.sleep(tout)
    locker_loop(mut, key, tin, tout)
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
    ack = fn() ->
      send(this, ref)
    end
    wack = fn() ->
      receive do
        ^ref -> :ok
      after
        timeout -> exit(:timeout)
      end
    end
    {ack, wack}
  end

  def spawn_hang(fun) do
    spawn(fn ->
      fun.()
      hang()
    end)
  end

  def hang do
    receive do
      :stop -> Logger.debug "Hangin stops"
    after
      1000 -> hang()
    end
  end

  def kill_after(pid, sleep \\ 0) do
    Process.sleep(sleep)
    Process.exit(pid, :kill)
  end
end
