defmodule Mutex.Test.Utils do
  require Logger
  require ExUnit.Assertions

  def rand_mod do
    :"Elixir.Test_Mutex_#{:erlang.unique_integer([:positive])}"
  end

  def awack(timeout \\ 5000) do
    {ack, wack} = vawack(timeout)
    {fn -> ack.(:ok) end, wack}
  end

  def vawack(timeout \\ 5000) do
    this = self()
    ref = make_ref()

    ack = fn value ->
      send(this, {ref, value})
    end

    wack = fn ->
      receive do
        {^ref, value} -> value
      after
        timeout -> exit(:timeout)
      end
    end

    {ack, wack}
  end

  # synchronizes several processes on a label, that is, when a participant
  # process calls the returned fun with a label, they'll block until all other
  # participants called the same label.
  def syncher(n_procs) when n_procs >= 2 do
    parent = self()
    n_clients = n_procs - 1
    ref = make_ref()

    fn key ->
      case self() do
        ^parent ->
          syncher_parent_loop(n_clients, key, ref, %{})

        from_pid ->
          send(parent, {:ack, ref, key, from_pid})

          receive do
            {:continue, ^ref, ^key} -> :ok
          after
            5000 -> exit(:timeout)
          end
      end
    end
  end

  defp syncher_parent_loop(n_clients, key, ref, others) when map_size(others) == n_clients do
    others |> Map.keys() |> Enum.each(&send(&1, {:continue, ref, key}))
  end

  defp syncher_parent_loop(n_clients, key, ref, others) do
    receive do
      {:ack, ^ref, ^key, from_pid} ->
        syncher_parent_loop(n_clients, key, ref, Map.put(others, from_pid, true))
    after
      5000 -> exit(:timeout)
    end
  end

  def spawn_hang(link? \\ true, fun) do
    executor = fn ->
      fun.()
      hang()
    end

    if link? do
      xspawn(executor)
    else
      spawn(executor)
    end
  end

  def hang do
    receive do
      :this_should_never_be_sent -> Logger.debug("Hanging stops")
    end
  end

  def kill_after(pid, sleep) do
    Process.sleep(sleep)
    kill(pid)
  end

  def kill(pid) do
    Process.unlink(pid)
    Process.exit(pid, :kill)
  end

  # Spawns a process linked to the caller like spawn_link. The process is killed
  # at the end of the test.
  def xspawn(fun) do
    pid = spawn_link(fun)
    ExUnit.Callbacks.on_exit(fn -> kill(pid) end)
    pid
  end

  def await_down(pid) when is_pid(pid) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, reason} -> reason
    after
      5000 -> ExUnit.Assertions.flunk("process #{inspect(pid)} did not exit")
    end
  end

  @doc """
  Ensures that the exception message can be generated
  """
  def ensure_message(e) do
    ExUnit.Assertions.refute(Exception.message(e) =~ "failed to produce a message with")
    e
  end
end
