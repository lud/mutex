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

      # %{owner_pid => {monitor_ref, [owned_key]}}
      owns: %{},

      # %{key => queue(gen_server.from())}
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
  def handle_call({:lock, key, wait?}, {pid, _} = from, state) do
    case Map.fetch(state.locks, key) do
      {:ok, ^pid} when wait? ->
        # Owner of the lock tries to lock it twice. If it wants to wait, that is
        # a deadlock
        {:reply, {:error, :self_deadlock}, state}

      {:ok, owner} ->
        if wait? do
          {:noreply, set_waiter(state, key, from)}
        else
          {:reply, {:error, {:locked, owner}}, state}
        end

      :error ->
        {:reply, :ok, set_lock(state, key, pid)}
    end
  end

  def handle_call({:release, :single, key, pid}, _from, state) when is_pid(pid) do
    case check_ownership(state.locks, key, pid) do
      :ok -> {:reply, :ok, free_lock(state, key, pid)}
      {:error, _} = err -> {:reply, err, state}
    end
  end

  def handle_call({:release, :multi, keys, pid}, _from, state) when is_pid(pid) do
    case check_ownership_all(state.locks, keys, pid) do
      :ok ->
        state = Enum.reduce(keys, state, fn key, state -> free_lock(state, key, pid) end)
        {:reply, :ok, state}

      {:error, _} = err ->
        {:reply, err, state}
    end
  end

  def handle_call({:give_away, key, caller_pid, heir_pid}, _from, state) do
    case check_ownership(state.locks, key, caller_pid) do
      :ok ->
        state = clear_lock(state, key, caller_pid)
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
        {:noreply, free_lock(state, key, pid)}

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

  def handle_cast({:cancel, key, pid}, %S{} = state) do
    state =
      case check_ownership(state.locks, key, pid) do
        :ok ->
          free_lock(state, key, pid)

        {:error, _} ->
          case state do
            %{waiters: %{^key => queue} = waiters} ->
              queue = clear_queue_pid(queue, pid)
              waiters = waiters_with_queue(waiters, key, queue)
              %S{state | waiters: waiters}

            _ ->
              state
          end
      end

    {:noreply, state}
  end

  def handle_cast({:goodbye, pid}, state) do
    {:noreply, clear_owner(state, pid, :goodbye)}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _}, state) do
    {:noreply, clear_owner(state, pid, :DOWN)}
  end

  def handle_info(msg, state) do
    Logger.error("Mutex #{inspect(self())} received unexepected message: #{inspect(msg)}")
    {:noreply, state}
  end

  # -- State ------------------------------------------------------------------

  defp set_lock(%S{locks: locks, owns: owns} = state, key, pid) do
    # Logger.debug "LOCK #{inspect key}"
    new_locks = Map.put(locks, key, pid)

    new_owns =
      case owns do
        %{^pid => {mref, keys}} -> Map.put(owns, pid, {mref, [key | keys]})
        _ -> Map.put(owns, pid, {Process.monitor(pid), [key]})
      end

    %S{state | locks: new_locks, owns: new_owns}
  end

  defp clear_lock(%S{locks: locks, owns: owns} = state, key, pid) do
    new_locks = Map.delete(locks, key)

    new_owns =
      case owns do
        %{^pid => {mref, [^key]}} ->
          Process.demonitor(mref, [:flush])
          Map.delete(owns, pid)

        %{^pid => {mref, keys}} ->
          Map.put(owns, pid, {mref, List.delete(keys, key)})
      end

    %S{state | locks: new_locks, owns: new_owns}
  end

  defp free_lock(state, key, pid) do
    state |> clear_lock(key, pid) |> rotate_lock(key)
  end

  defp rotate_lock(%S{} = state, key) do
    %{waiters: waiters} = state

    waiters
    |> Map.fetch(key)
    |> case do
      :error ->
        state

      {:ok, queue} ->
        {{:value, {pid, _} = from}, queue} = :queue.out(queue)
        waiters = waiters_with_queue(waiters, key, queue)

        state = set_lock(%S{state | waiters: waiters}, key, pid)
        GenServer.reply(from, :ok)
        state
    end
  end

  defp clear_owner(%S{locks: locks, owns: owns} = state, pid, type) do
    case owns do
      %{^pid => {mref, keys}} ->
        if type !== :DOWN do
          Process.demonitor(mref, [:flush])
        end

        new_locks = Map.drop(locks, keys)
        new_owns = Map.delete(owns, pid)
        state = %S{state | locks: new_locks, owns: new_owns}
        state = Enum.reduce(keys, state, fn key, state -> rotate_lock(state, key) end)
        state

      _ ->
        state
    end
  end

  defp set_waiter(%S{waiters: waiters} = state, key, from) do
    # Maybe we should monitor the waiter to not send useless message when the
    # key is available if the waiter is down ?
    new_waiters = Map.update(waiters, key, :queue.from_list([from]), fn waiters -> :queue.in(from, waiters) end)

    %S{state | waiters: new_waiters}
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

  defp waiters_with_queue(waiters, key, queue) do
    case :queue.peek(queue) do
      :empty -> Map.delete(waiters, key)
      {:value, _} -> Map.put(waiters, key, queue)
    end
  end

  defp clear_queue_pid(queue, pid) do
    :queue.delete_with(fn {p, _} -> p == pid end, queue)
  end
end
