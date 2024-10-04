defmodule Mutex do
  alias Mutex.Lock
  alias Mutex.LockError
  alias Mutex.ReleaseError
  import Kernel, except: [send: 2]
  require Logger
  use GenServer

  @moduledoc """
  This is the main module in this application, it implements a mutex as a
  GenServer with a notification system to be able to await lock releases.

  See [`README.md`](https://hexdocs.pm/mutex/readme.html) for how to use.
  """
  @gen_opts [:debug, :name, :timeout, :spawn_opt, :hibernate_after]

  @typedoc "Identifier for a mutex process."
  @type name :: GenServer.server()

  @typedoc "A key can be any term."
  @type key :: any

  @doc """
  Starts a mutex with no process linking. Given options are passed as options
  for a `GenServer`, it's a good place to set the name for registering the
  process.

  See `start_link/1` for options.
  """
  @spec start(opts :: Keyword.t()) :: GenServer.on_start()
  def start(opts \\ []) when is_list(opts) do
    {gen_opts, opts} = Keyword.split(opts, @gen_opts)
    GenServer.start(__MODULE__, opts, gen_opts)
  end

  @doc """
  Starts a mutex linked to the calling process.

  Accepts only `t:GenServer.options()`.

  See [`GenServer`
  options](https://hexdocs.pm/elixir/GenServer.html#t:options/0).
  """
  @spec start_link(opts :: Keyword.t()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    {gen_opts, opts} = Keyword.split(opts, @gen_opts)
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc """
  Attemps to lock a resource on the mutex and returns immediately with the
  result, which is either a `Mutex.Lock` structure or `{:error, :busy}`.
  """
  @spec lock(name :: name, key :: key) :: {:ok, Lock.t()} | {:error, :busy}
  def lock(mutex, key) do
    case GenServer.call(mutex, {:lock, key, self(), false}) do
      :ok -> {:ok, key2lock(key)}
      {:error, :busy} -> {:error, :busy}
    end
  end

  defp key2lock(key), do: %Lock{type: :single, key: key}

  @doc """
  Attemps to lock a resource on the mutex and returns immediately with the lock
  or raises an exception if the key is already locked.
  """
  @spec lock!(name :: name, key :: key) :: Lock.t()
  def lock!(mutex, key) do
    case lock(mutex, key) do
      {:ok, lock} -> lock
      {:error, :busy} -> raise LockError, key: key
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
  process exits as in `GenServer.call/3`.  More information in the
  [timeouts](https://hexdocs.pm/elixir/GenServer.html#call/3-timeouts) section.
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
  def await_all(mutex, keys) when is_list(keys) and length(keys) > 0 do
    sorted = Enum.sort(keys)
    await_sorted(mutex, sorted, :infinity, [])
  end

  # Waiting multiple keys and avoiding deadlocks. It is enough to simply lock
  # the keys sorted. @optimize send all keys to the server and get {locked,
  # busies} as reply, then start over with the busy ones

  defp await_sorted(mutex, [last | []], :infinity, locked_keys) do
    %Lock{} = await(mutex, last, :infinity)
    keys2multilock(:lists.reverse([last | locked_keys]))
  end

  defp await_sorted(mutex, [key | keys], :infinity, locked_keys) do
    _lock = await(mutex, key, :infinity)
    await_sorted(mutex, keys, :infinity, [key | locked_keys])
  end

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
    do: release_key_async(mutex, key, self())

  def release(mutex, %Lock{type: :multi, keys: keys}) do
    # TODO send all at once
    Enum.each(keys, &release_key_async(mutex, &1, self()))
    :ok
  end

  defp release_key_async(mutex, key, pid) do
    :ok = GenServer.cast(mutex, {:release, key, pid})
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
  Awaits a lock for the given key, executes the given fun and releases
  the lock immediately.

  If an exeption is raised or thrown in the fun, the lock is
  automatically released.

  If a function of arity 1 is given, it will be passed the lock.
  Otherwise the arity must be 0. You should not manually release the
  lock within the function.
  """
  @spec under(
          mutex :: name,
          key :: key,
          timeout :: timeout,
          fun :: (-> any) | (Lock.t() -> any)
        ) :: any
  def under(mutex, key, timeout \\ :infinity, fun)

  def under(mutex, key, timeout, fun) when is_function(fun, 0),
    do: under(mutex, key, timeout, fn _ -> fun.() end)

  def under(mutex, key, timeout, fun) when is_function(fun, 1) do
    lock = await(mutex, key, timeout)
    apply_with_lock(mutex, lock, fun)
  end

  @doc """
  Awaits a lock for the given keys, executes the given fun and
  releases the lock immediately.

  If an exeption is raised or thrown in the fun, the lock is
  automatically released.

  If a function of arity 1 is given, it will be passed the lock.
  Otherwise the arity must be 0. You should not manually release the
  lock within the function.
  """
  @spec under_all(mutex :: name, keys :: [key], fun :: (-> any) | (Lock.t() -> any)) :: any
  def under_all(mutex, keys, fun) when is_function(fun, 0),
    do: under_all(mutex, keys, fn _ -> fun.() end)

  def under_all(mutex, keys, fun) when is_function(fun, 1) do
    lock = await_all(mutex, keys)
    apply_with_lock(mutex, lock, fun)
  end

  defp apply_with_lock(mutex, lock, fun) do
    fun.(lock)
  after
    release(mutex, lock)
  end

  @doc """
  Sets the the process identified by `pid` as the new owner of the `lock`.

  If succesful, that new owner will be sent a `{:"MUTEX-TRANSFER", from_pid,
  lock, gift_data} ` message. If it is not alive, the lock will be released.

  This function only supports single key locks.
  """
  @doc since: "3.0.0"
  @spec give_away(mutex :: name, Lock.t(), pid, gift_data :: term) :: :ok
  def give_away(mutex, lock, pid, gift_data \\ nil)

  def give_away(_mutex, %Lock{type: :single}, pid, _gift_data) when pid == self() do
    raise ArgumentError, "process #{inspect(pid)} is already owner of the lock"
  end

  def give_away(mutex, %Lock{type: :single, key: key} = lock, pid, gift_data) when is_pid(pid) do
    from_pid = self()

    case GenServer.call(mutex, {:give_away, key, from_pid, pid}) do
      :ok ->
        Kernel.send(pid, {:"MUTEX-TRANSFER", from_pid, lock, gift_data})
        :ok

      {:error, {:bad_owner, owner}} ->
        raise ReleaseError, owner: owner, releaser: from_pid, key: key, action: :give_away

      {:error, :unknown_lock} ->
        raise ReleaseError, releaser: from_pid, key: key, action: :give_away
    end
  end

  # -- Via Callbacks ----------------------------------------------------------

  @doc false
  @spec whereis_name({mutex :: name, key :: key}) :: pid | :undefined
  def whereis_name({mutex, key}) do
    case GenServer.call(mutex, {:where, key}) do
      nil -> :undefined
      pid -> if Process.alive?(pid), do: pid, else: :undefined
    end
  end

  @doc false
  @spec register_name({mutex :: name, key :: key}, pid) :: :yes | :no
  def register_name({mutex, key}, pid) do
    # Just support registering self for now
    true = self() == pid

    case Mutex.lock(mutex, key) do
      {:ok, _lock} -> :yes
      {:error, :busy} -> :no
    end
  end

  @doc false
  @spec unregister_name({mutex :: name, key :: key}) :: :ok
  def unregister_name({mutex, key}) do
    release_key_async(mutex, key, :"$force_release")
  end

  @doc false
  @spec send({mutex :: name, key :: key}, term) :: pid
  def send({mutex, key}, msg) do
    case whereis_name({mutex, key}) do
      pid when is_pid(pid) ->
        Kernel.send(pid, msg)
        pid

      :undefined ->
        :erlang.error(:badarg, [{mutex, key}, msg])
    end
  end

  # -- Server Callbacks -------------------------------------------------------

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

  def handle_call({:where, key}, _from, state) do
    reply =
      case Map.fetch(state.locks, key) do
        {:ok, pid} -> pid
        :error -> nil
      end

    {:reply, reply, state}
  end

  def handle_call({:give_away, key, caller_pid, heir_pid}, _from, state) do
    {reply, state} =
      case Map.fetch(state.locks, key) do
        {:ok, ^caller_pid} ->
          state = rm_lock(state, key, caller_pid)
          state = set_lock(state, key, heir_pid)
          {:ok, state}

        {:ok, owner_pid} ->
          {{:error, {:bad_owner, owner_pid}}, state}

        :error ->
          {{:error, :unknown_lock}, state}
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_cast({:release, key, pid}, state) do
    state =
      case Map.fetch(state.locks, key) do
        {:ok, ^pid} ->
          rm_lock(state, key, pid)

        {:ok, owner_pid} when pid == :"$force_release" ->
          rm_lock(state, key, owner_pid)

        {:ok, other_pid} ->
          Logger.error("Could not release #{inspect(key)}, bad owner",
            key: key,
            owner: other_pid,
            attempt: pid
          )

          state

        :error ->
          Logger.error("Could not release #{inspect(key)}, not found", key: key, attempt: pid)
          state
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
    # Logger.debug "RELEASE #{inspect key}"
    # pid must be the owner here. Checked in handle_cast
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