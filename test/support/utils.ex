defmodule Mutex.Test.Utils do
  require Logger

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
      tspawn(executor)
    else
      spawn(executor)
    end
  end

  def hang do
    receive do
      :stop -> Logger.debug("Hanging stops")
    end
  end

  def kill_after(pid, sleep) do
    Process.sleep(sleep)
    kill(pid)
  end

  def kill(pid) do
    Process.exit(pid, :kill)
  end

  def tspawn(fun) do
    {Task, fun}
    |> Supervisor.child_spec(id: :erlang.unique_integer())
    |> ExUnit.Callbacks.start_supervised!()
  end
end
