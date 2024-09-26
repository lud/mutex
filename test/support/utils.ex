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
