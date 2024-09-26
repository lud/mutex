defmodule Mutex.ExampleTest do
  import Mutex.Test.Utils
  require Logger
  use ExUnit.Case, async: true

  @moduletag :capture_log
  @mut rand_mod()

  setup do
    {:ok, _pid} = start_supervised({Mutex, name: @mut, meta: :test_mutex})
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

    {_, ref1} = spawn_monitor(fn -> update_user.("worker 1") end)
    {_, ref2} = spawn_monitor(fn -> update_user.("worker 2") end)
    {_, ref3} = spawn_monitor(fn -> update_user.("worker 3") end)

    await_refs([ref1, ref2, ref3])
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

    {_, ref4} = spawn_monitor(fn -> update_user.("worker 4") end)
    {_, ref5} = spawn_monitor(fn -> update_user.("worker 5") end)
    {_, ref6} = spawn_monitor(fn -> update_user.("worker 6") end)

    await_refs([ref4, ref5, ref6])
  end

  defp await_refs([]), do: :ok

  defp await_refs([h | t]) do
    receive do
      {:DOWN, ^h, :process, _, _} -> await_refs(t)
    after
      5000 -> flunk("process did not exit")
    end
  end

  test "Bad Concurrency" do
    filename = "test/tmp/wrong-file.txt"
    setup_test_file(filename)

    tasks = for _ <- 1..10, do: Task.async(fn -> sloppy_increment_file(filename) end)

    # await all tasks
    Enum.each(tasks, &Task.await(&1))

    # file val was read from all process at 0, then written incremented
    # so the file is "1"
    assert "1" = File.read!(filename)
  end

  test "Mutex Concurrency" do
    filename = "test/tmp/good-file.txt"
    setup_test_file(filename)

    tasks =
      for _ <- 1..10 do
        Task.async(fn ->
          lock = Mutex.await(@mut, :good_file, :infinity)
          sloppy_increment_file(filename)
          assert :ok = Mutex.release(@mut, lock)
        end)
      end

    Enum.each(tasks, &Task.await(&1))

    # file val was read from all process at 0, then written incremented
    # so the file is "1"
    assert "10" = File.read!(filename)
  end

  defp setup_test_file(filename) do
    File.rm!(filename)
    File.write!(filename, "0")
  end

  # Bad function that will reads an integer from a file, wait a little bit and
  # then write in the incremented integer. If called concurrently, the last
  # process that will write will overwrite every previous calculation
  defp sloppy_increment_file(filename) do
    int = filename |> File.read!() |> String.to_integer()
    Process.sleep(100)
    File.write!(filename, Integer.to_string(int + 1))
  end
end
