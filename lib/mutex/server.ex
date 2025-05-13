defmodule Mutex.Server do
  alias Mutex.ReleaseError
  require Logger
  use GenServer

  @moduledoc false

  defmodule S do
    @moduledoc false
    defstruct [
      # %{lock_key => owner_pid}
      locks: %{},

      # %{owner_pid => [{owned_key, monitor_ref}]}
      owns: %{},

      # %{key => [gen_server.from()]}
      waiters: %{}
    ]
  end

  @impl true
  def init(opts) do
    _opts = Enum.flat_map(opts, &validate_opt/1)

    {:ok, %S{}}
  end

  defp validate_opt(opt) do
    Logger.warning("Unknown option #{inspect(opt)} given to #{inspect(__MODULE__)}")
    []
  end

  @impl true
  def handle_call({:lock, key, pid, wait?}, from, state) do
    case Map.fetch(state.locks, key) do
      {:ok, _owner} ->
        if wait? do
          {:noreply, set_waiter(state, key, from)}
        else
          {:reply, {:error, :busy}, state}
        end

      :error ->
        {:reply, :ok, set_lock(state, key, pid)}
    end
  end

  def handle_call({:release, :single, key, pid}, _from, state) when is_pid(pid) do
    case check_ownership(state.locks, key, pid) do
      :ok -> {:reply, :ok, rm_lock(state, key, pid)}
      {:error, _} = err -> {:reply, err, state}
    end
  end

  def handle_call({:release, :multi, keys, pid}, _from, state) when is_pid(pid) do
    case check_ownership_all(state.locks, keys, pid) do
      :ok ->
        state = Enum.reduce(keys, state, fn key, state -> rm_lock(state, key, pid) end)
        {:reply, :ok, state}

      {:error, _} = err ->
        {:reply, err, state}
    end
  end

  def handle_call({:give_away, key, caller_pid, heir_pid}, _from, state) do
    case check_ownership(state.locks, key, caller_pid) do
      :ok ->
        state = rm_lock(state, key, caller_pid)
        state = set_lock(state, key, heir_pid)
        {:reply, :ok, state}

      {:error, _} = err ->
        {:reply, err, state}
    end
  end

  def handle_call({:where, key}, _from, state) do
    reply =
      case Map.fetch(state.locks, key) do
        {:ok, pid} -> pid
        :error -> nil
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_cast({:release, :single, key, pid}, state) do
    case check_ownership(state.locks, key, pid) do
      :ok ->
        {:noreply, rm_lock(state, key, pid)}

      {:error, reason} ->
        message =
          try do
            reason
            |> ReleaseError.of(:single, key, :release, pid)
            |> Exception.message()
          catch
            _, _ -> "unknown error"
          end

        Logger.error("[Mutex] Could not release key asynchronously: #{message}")

        {:noreply, state}
    end
  end

  def handle_cast({:goodbye, pid}, state) do
    {:noreply, clear_owner(state, pid, :goodbye)}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _}, state) do
    {:noreply, clear_owner(state, pid, :DOWN)}
  end

  # -- State ------------------------------------------------------------------

  defp set_lock(%S{locks: locks, owns: owns} = state, key, pid) do
    # Logger.debug "LOCK #{inspect key}"
    new_locks = Map.put(locks, key, pid)

    ref = Process.monitor(pid)
    keyref = {key, ref}

    new_owns = Map.update(owns, pid, [keyref], fn keyrefs -> [keyref | keyrefs] end)

    %S{state | locks: new_locks, owns: new_owns}
  end

  defp rm_lock(%S{locks: locks, owns: owns} = state, key, pid) do
    # TODO optimize for multilocks release
    new_locks = Map.delete(locks, key)

    {new_owns, mref} =
      case owns do
        %{^pid => [{^key, mref}]} ->
          {Map.delete(owns, pid), mref}

        %{^pid => keyrefs} ->
          {{_key, mref}, new_keyrefs} = List.keytake(keyrefs, key, 0)
          {Map.put(owns, pid, new_keyrefs), mref}
      end

    Process.demonitor(mref, [:flush])

    state.waiters
    |> Map.get(key, [])
    |> notify_waiters(key)

    new_waiters = Map.delete(state.waiters, key)

    %S{state | locks: new_locks, owns: new_owns, waiters: new_waiters}
  end

  defp clear_owner(%S{locks: locks, owns: owns} = state, pid, type) do
    {keys, refs} =
      owns
      |> Map.get(pid, [])
      |> Enum.unzip()

    new_locks = Map.drop(locks, keys)

    if type !== :DOWN do
      Enum.each(refs, &Process.demonitor(&1, [:flush]))
    end

    {notifiables, new_waiters} = Map.split(state.waiters, keys)

    Enum.each(notifiables, fn {key, froms} -> notify_waiters(froms, key) end)

    new_owns = Map.delete(owns, pid)

    %S{state | locks: new_locks, owns: new_owns, waiters: new_waiters}
  end

  defp set_waiter(%S{waiters: waiters} = state, key, from) do
    # Maybe we should monitor the waiter to not send useless message when the
    # key is available if the waiter is down ?
    new_waiters = Map.update(waiters, key, [from], fn waiters -> [from | waiters] end)

    %S{state | waiters: new_waiters}
  end

  defp notify_waiters([], _) do
    :ok
  end

  defp notify_waiters(waiters, key) do
    # The first waiter is the last in the list.
    waiters = :lists.reverse(waiters)

    :ok = Enum.each(waiters, &notify_waiter(&1, key))
  end

  defp notify_waiter(from, key) do
    :ok = GenServer.reply(from, {:available, key})
  end

  defp check_ownership_all(_, [], _), do: :ok

  defp check_ownership_all(locks, [h | keys], pid) do
    case check_ownership(locks, h, pid) do
      :ok -> check_ownership_all(locks, keys, pid)
      {:error, _} = err -> err
    end
  end

  defp check_ownership(locks, key, pid) do
    case Map.fetch(locks, key) do
      {:ok, ^pid} -> :ok
      {:ok, owner_pid} -> {:error, {:bad_owner, key, owner_pid}}
      :error -> {:error, {:unknown_key, key}}
    end
  end
end
