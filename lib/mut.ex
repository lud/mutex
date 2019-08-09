defmodule Mutex do
  require Logger
  use GenServer

  @typedoc "The name of a mutex is an atom, registered with `Process.register/2`"
  @type name :: atom

  @typedoc "A key can be any term."
  @type key :: any

  defmodule Lock do
    @moduledoc """
    This module defines a struct containing the key(s) locked with all the
    locking functions in `Mutex`.
    """
    defstruct [:type, :key, :keys]

    @typedoc """
    The struct containing the key(s) locked during a lock operation. `:type`
    specifies wether there is one or more keys.
    """
    @type t :: %__MODULE__{
            type: :single | :multi,
            key: nil | Mutex.key(),
            keys: nil | [Mutex.key()]
          }
  end

  @moduledoc """
  This is the only module in this application, it implements a mutex as a
  GenServer with a notification system to be able to await lock releases.

  See [`README.md`](https://hexdocs.pm/mutex/readme.html) for how to use.
  """

  @doc """
  Returns a child specification to integrate the mutex in a supervision tree.
  The passed name is an atom, it will be the registered name for the mutex.
  """
  @spec child_spec(name :: name) :: Supervisor.Spec.spec()
  def child_spec(name) when is_atom(name) do
    Supervisor.Spec.supervisor(__MODULE__, [[name: name]])
  end

  @doc """
  Starts a mutex with no process linking. Given options are passed as options
  for a `GenServer`, it's a good place to set the name for registering the
  process.
  """
  @spec start(opts :: GenServer.options()) :: GenServer.on_start()
  def start(opts \\ []) do
    GenServer.start(__MODULE__, :noargs, opts)
  end

  @doc """
  Starts a mutex with linking under a supervision tree. Given options are passed
  as options for a `GenServer`, it's a good place to set the name for
  registering the process.
  """
  @spec start_link(opts :: GenServer.options()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :noargs, opts)
  end

  @doc """
  Attemps to lock a resource on the mutex and returns immediately with the
  result, which is either a `Mutex.Lock` structure or `{:error, :busy}`.
  """
  @spec lock(name :: name, key :: key) :: {:ok, Lock.t()} | {:error, :busy}
  def lock(mutex, key) do
    case GenServer.call(mutex, {:lock, key, self(), false}) do
      :ok -> {:ok, key2lock(key)}
      err -> err
    end
  end

  defp key2lock(key),
    do: %Lock{type: :single, key: key}

  @doc """
  Attemps to lock a resource on the mutex and returns immediately with the lock
  or raises an exception if the key is already locked.
  """
  @spec lock!(name :: name, key :: key) :: Lock.t()
  def lock!(mutex, key) do
    case lock(mutex, key) do
      {:ok, lock} ->
        lock

      err ->
        raise "Locking of key #{inspect(key)} is impossible, " <>
                "the key is already locked (#{inspect(err)})."
    end
  end

  @doc """
  Locks a key if it is available, or waits for the key to be freed before
  attempting again to lock it.

  Returns the lock or fails with a timeout.

  Due to the notification system, multiple attempts can be made to lock if
  multiple processes are competing for the key.

  So timeout will be *at least* for the passed amount of milliseconds, but may
  be slightly longer.

  Default timeout is `5000` milliseconds. If the timeout is reached, the caller
  process exists as in `GenServer.call/3`.
  More information in the [timeouts](https://hexdocs.pm/elixir/GenServer.html#call/3-timeouts)
  section.
  """
  @spec await(mutex :: name, key :: key, timeout :: timeout) :: Lock.t()
  def await(mutex, key, timeout \\ 5000)

  def await(mutex, key, timeout) when is_integer(timeout) and timeout < 0 do
    await(mutex, key, 0)
  end

  def await(mutex, key, :infinity) do
    case GenServer.call(mutex, {:lock, key, self(), true}, :infinity) do
      # lock acquired
      :ok -> key2lock(key)
      {:available, ^key} -> await(mutex, key, :infinity)
    end
  end

  def await(mutex, key, timeout) do
    now = System.system_time(:millisecond)

    case GenServer.call(mutex, {:lock, key, self(), true}, timeout) do
      :ok ->
        # lock acquired
        key2lock(key)

      {:available, ^key} ->
        expires_at = now + timeout
        now2 = System.system_time(:millisecond)
        timeout = expires_at - now2
        await(mutex, key, timeout)
    end
  end

  @doc """
  Awaits multiple keys at once. Returns once all the keys have been locked,
  timeout is `:infinity`.

  If two processes are trying to lock `[:user_1, :user_2]` and
  `[:user_2, :user_3]` at the same time, this function ensures that no deadlock
  can happen and that one process will eventually lock all the keys.

  More information at the end of the
  [deadlocks section](https://hexdocs.pm/mutex/readme.html#avoiding-deadlocks).
  """
  @spec await_all(mutex :: name, keys :: [key]) :: Lock.t()
  def await_all(mutex, keys) do
    sorted = Enum.sort(keys)
    await_sorted(mutex, sorted, :infinity, [])
  end

  # Waiting multiple keys and avoiding deadlocks. It is enough to simply lock
  # the keys sorted. @optimize send all keys to the server and get {locked,
  # busies} as reply, then start over with the busy ones
  defp await_sorted(mutex, [key | keys], :infinity, locked_keys) do
    _lock = await(mutex, key, :infinity)
    await_sorted(mutex, keys, :infinity, [key | locked_keys])
  end

  defp await_sorted(_mutex, [], :infinity, locked_keys),
    do: keys2multilock(locked_keys)

  defp keys2multilock(keys),
    do: %Lock{type: :multi, keys: keys}

  @doc """
  Tells the mutex to free the given lock and immediately returns `:ok` without
  waiting for the actual release.
  If the calling process is not the owner of the key(s), the key(s) is/are
  *not* released and an error is logged.
  """
  @spec release(mutex :: name, lock :: Lock.t()) :: :ok
  def release(mutex, %Lock{type: :single, key: key}),
    do: release_key(mutex, key)

  def release(mutex, %Lock{type: :multi, keys: keys}) do
    Enum.each(keys, &release_key(mutex, &1))
    :ok
  end

  defp release_key(mutex, key) do
    GenServer.cast(mutex, {:release, key, self()})
    :ok
  end

  @doc """
  Tells the mutex to release *all* the keys owned by the calling process and
  returns immediately with `:ok`.
  """
  @spec goodbye(mutex :: name) :: :ok
  def goodbye(mutex) do
    GenServer.cast(mutex, {:goodbye, self()})
    :ok
  end

  @doc """
  Awaits a lock for the given key, executes the given fun and releases the lock
  immediately.

  If an exeption is raised or thrown in the fun, the lock is automatically
  released.
  """
  @spec under(mutex :: name, key :: key, timeout :: timeout, fun :: (() -> any)) :: any
  def under(mutex, key, timeout \\ :infinity, fun) do
    lock = await(mutex, key, timeout)
    apply_with_lock(mutex, lock, fun)
  end

  @doc """
  Awaits a lock for the given keys, executes the given fun and releases the lock
  immediately.

  If an exeption is raised or thrown in the fun, the lock is automatically
  released.
  """
  @spec under_all(mutex :: name, keys :: [key], fun :: (() -> any)) :: any
  def under_all(mutex, keys, fun) do
    lock = await_all(mutex, keys)
    apply_with_lock(mutex, lock, fun)
  end

  defp apply_with_lock(mutex, lock, fun) do
    try do
      result2 = fun.()
      release(mutex, lock)
      result2
    rescue
      e ->
        stacktrace = System.stacktrace()
        release(mutex, lock)
        Logger.error("Exception within lock: #{inspect(e)}")
        reraise(e, stacktrace)
    catch
      :throw, term ->
        Logger.error("Thrown within lock: #{inspect(term)}")
        release(mutex, lock)
        throw(term)
    end
  end

  # -- Server Callbacks -------------------------------------------------------

  defmodule S do
    @moduledoc false
    defstruct locks: %{},
              # owner's pids
              owns: %{},
              # waiters's gen_server from value
              waiters: %{}
  end

  def init(:noargs) do
    send(self(), :cleanup)
    {:ok, %S{}}
  end

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

  def handle_cast({:release, key, pid}, state) do
    case Map.fetch(state.locks, key) do
      {:ok, ^pid} ->
        {:noreply, rm_lock(state, key, pid)}

      {:ok, other_pid} ->
        Logger.error("Could not release #{key}, bad owner",
          key: key,
          owner: other_pid,
          attempt: pid
        )

        {:noreply, state}

      :error ->
        Logger.error("Could not release #{key}, not found", key: key, attempt: pid)
        {:noreply, state}
    end
  end

  def handle_cast({:goodbye, pid}, state) do
    {:noreply, clear_owner(state, pid, :goodbye)}
  end

  def handle_info(_info = {:DOWN, _ref, :process, pid, _}, state) do
    {:noreply, clear_owner(state, pid, :DOWN)}
  end

  def handle_info(:cleanup, state) do
    Process.send_after(self(), :cleanup, 1000)
    {:noreply, cleanup(state)}
  end

  def handle_info(info, state) do
    Logger.warn("Mutex received unexpected info : #{inspect(info)}")
    {:noreply, state}
  end

  # -- State ------------------------------------------------------------------

  defp set_lock(state = %S{locks: locks, owns: owns}, key, pid) do
    # Logger.debug "LOCK #{inspect key}"
    new_locks =
      locks
      |> Map.put(key, pid)

    ref = Process.monitor(pid)
    keyref = {key, ref}

    new_owns =
      owns
      |> Map.update(pid, [keyref], fn keyrefs -> [keyref | keyrefs] end)

    %S{state | locks: new_locks, owns: new_owns}
  end

  defp rm_lock(state = %S{locks: locks, owns: owns}, key, pid) do
    # Logger.debug "RELEASE #{inspect key}"
    # pid must be the owner here. Checked in handle_cast
    new_locks =
      locks
      |> Map.drop([key])

    new_owns =
      owns
      |> Map.update(pid, [], fn keyrefs ->
        {{_key, ref}, new_keyrefs} = List.keytake(keyrefs, key, 0)
        Process.demonitor(ref)
        new_keyrefs
      end)

    state.waiters
    |> Map.get(key, [])
    |> notify_waiters(key)

    new_waiters =
      state.waiters
      |> Map.drop([key])

    %S{state | locks: new_locks, owns: new_owns, waiters: new_waiters}
  end

  defp clear_owner(state = %S{locks: locks, owns: owns}, pid, type) do
    {keys, refs} =
      owns
      |> Map.get(pid, [])
      |> Enum.unzip()

    if length(keys) > 0 do
      # Logger.debug "RELEASE ALL (#{type}) #{inspect keys}"
    end

    new_locks =
      locks
      |> Map.drop(keys)

    # sure that monitors are cleaned up ?
    if(type !== :DOWN,
      do: Enum.each(refs, &Process.demonitor/1)
    )

    state.waiters
    |> Map.take(keys)
    |> Enum.map(fn {key, froms} ->
      notify_waiters(froms, key)
    end)

    new_waiters =
      state.waiters
      |> Map.drop(keys)

    new_owns =
      owns
      |> Map.drop([pid])

    %S{state | locks: new_locks, owns: new_owns, waiters: new_waiters}
  end

  defp set_waiter(state = %S{waiters: waiters}, key, from) do
    # Maybe we should monitor the waiter to not send useless message when the
    # key is available if the waiter is down ?
    new_waiters =
      waiters
      |> Map.update(key, [from], fn waiters -> [from | waiters] end)

    %S{state | waiters: new_waiters}
  end

  defp cleanup(state = %S{owns: owns}) do
    # remove empty owns
    new_owns =
      owns
      |> Enum.filter(fn
        {_pid, []} -> false
        _ -> true
      end)
      |> Enum.into(%{})

    %S{state | owns: new_owns}
  end

  defp notify_waiters([], _) do
    :ok
  end

  defp notify_waiters(froms, key) do
    # Use a task so we can sleep between notifications for waiters are called in
    # order with a chance for each one to send lock msg befor the following
    # others.
    Task.start_link(fn ->
      froms
      |> Enum.reverse()
      |> Enum.map(fn from ->
        GenServer.reply(from, {:available, key})
        Process.sleep(50)
      end)
    end)

    :ok
  end
end
