defmodule Mutex do
  alias Mutex.Lock
  alias Mutex.LockError
  alias Mutex.ReleaseError
  import Kernel, except: [send: 2]

  @moduledoc """
  This is the main module in this application, it implements a mutex as a
  GenServer with a notification system to be able to await lock releases.

  See [`README.md`](https://hexdocs.pm/mutex/readme.html) for usage
  instructions.
  """
  @gen_opts [:debug, :name, :timeout, :spawn_opt, :hibernate_after]

  @typedoc "Identifier for a mutex process."
  @type name :: GenServer.server()

  @typedoc "A key can be any term."
  @type key :: term

  @doc """
  Starts a mutex with no process linking. Given options are passed as options
  for a `GenServer`, it's a good place to set the name for registering the
  process.

  See `start_link/1` for options.
  """
  @spec start(opts :: Keyword.t()) :: GenServer.on_start()
  def start(opts \\ []) when is_list(opts) do
    {gen_opts, opts} = Keyword.split(opts, @gen_opts)
    GenServer.start(__MODULE__.Server, opts, gen_opts)
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
    GenServer.start_link(__MODULE__.Server, opts, gen_opts)
  end

  @doc """
  Returns a specification to start a mutex under a supervisor.

  See the "Child specification" section in the `Supervisor` module for more
  detailed information.
  """
  def child_spec(arg) do
    %{id: Mutex, start: {Mutex, :start_link, [arg]}}
  end

  @doc """
  Attempts to lock a resource on the mutex and returns immediately with the
  result.

  When the key is already locked, the returned `Mutex.LockError` carries the
  owner pid in its `:cause` field. This lets callers tell whether they already
  own the key themselves:

  ```elixir
  case Mutex.lock(mutex, key) do
    {:ok, lock} ->
      handle_resource(lock)

    {:error, %Mutex.LockError{cause: {:locked, owner}}} when owner == self() ->
      :already_mine

    {:error, %Mutex.LockError{}} ->
      :taken
  end
  ```

  The owner pid is the owner at the time the mutex handled the request. When
  that pid is `self()` the information stays accurate, as a lock is only
  released or given away by its owner.
  """
  @spec lock(name :: name, key :: key) :: {:ok, Lock.t()} | {:error, LockError.t()}
  def lock(mutex, key) do
    case GenServer.call(mutex, {:lock, key, self(), false}) do
      :ok -> {:ok, key_to_lock(key)}
      {:error, {:locked, _} = cause} -> {:error, %LockError{key: key, cause: cause}}
    end
  end

  defp key_to_lock(key), do: %Lock{type: :single, key: key}
  defp lock_to_key_or_keys(%Lock{type: :single, key: key}), do: key
  defp lock_to_key_or_keys(%Lock{type: :multi, keys: keys}), do: keys

  @doc """
  Attempts to lock a resource on the mutex and returns immediately with the
  lock, or raises a `Mutex.LockError` if the key is already locked.
  """
  @spec lock!(name :: name, key :: key) :: Lock.t()
  def lock!(mutex, key) do
    case lock(mutex, key) do
      {:ok, lock} -> lock
      {:error, %LockError{} = e} -> raise e
    end
  end

  @doc """
  Locks a key if it is available, or waits for the key to be freed before
  attempting again to lock it.

  Returns the lock or fails with a timeout.

  When the key is released, all awaiting processes compete to lock it again,
  and one of them, chosen in no particular order, acquires it. The other
  processes keep waiting.

  Because of those repeated attempts, the timeout is a minimum: the function
  waits *at least* for the passed amount of milliseconds, but may take
  slightly longer to give up.

  Default timeout is `5000` milliseconds. If the timeout is reached, the caller
  process exits as in `GenServer.call/3`.  More information in the
  [timeouts](https://hexdocs.pm/elixir/GenServer.html#call/3-timeouts) section.

  Raises a `Mutex.LockError` when the calling process already owns the key,
  since waiting for its own key to be released would deadlock.
  """
  @spec await(mutex :: name, key :: key, timeout :: timeout) :: Lock.t()
  def await(mutex, key, timeout \\ 5000)

  def await(mutex, key, timeout) when is_integer(timeout) and timeout < 0 do
    await(mutex, key, 0)
  end

  def await(mutex, key, :infinity) do
    case safe_await_infinity(mutex, key) do
      # lock acquired
      :ok -> key_to_lock(key)
      {:error, :self_deadlock} -> raise LockError, cause: :self_deadlock, key: key
    end
  end

  def await(mutex, key, timeout) do
    now = System.monotonic_time(:millisecond)

    case GenServer.call(mutex, {:lock, key, self(), true}, timeout) do
      :ok ->
        key_to_lock(key)

      {:available, ^key} ->
        expires_at = now + timeout
        now2 = System.monotonic_time(:millisecond)
        timeout = expires_at - now2
        await(mutex, key, timeout)

      {:error, :self_deadlock} ->
        raise LockError, cause: :self_deadlock, key: key
    end
  end

  defp safe_await_infinity(mutex, key) do
    case GenServer.call(mutex, {:lock, key, self(), true}, :infinity) do
      :ok -> :ok
      {:available, ^key} -> safe_await_infinity(mutex, key)
      {:error, :self_deadlock} = err -> err
    end
  end

  @doc """
  Awaits multiple keys at once. Returns once all the keys have been locked,
  timeout is `:infinity`.

  If two processes are trying to lock `[:user_1, :user_2]` and `[:user_2,
  :user_3]` at the same time, this function ensures that no deadlock can happen
  and that one process will eventually lock all the keys.

  More information at the end of the [deadlocks
  section](https://hexdocs.pm/mutex/readme.html#avoiding-deadlocks).

  Keys must be unique, otherwise an `ArgumentError` is raised. When keys are
  built dynamically and may collide, deduplicate them first, for instance with
  `Enum.uniq/1`.

  Raises a `Mutex.LockError` when the calling process already owns one of the
  keys. In that case, the keys acquired during the call are released before
  raising.
  """
  @spec await_all(mutex :: name, keys :: [key]) :: Lock.t()
  def await_all(mutex, [_ | _] = keys) do
    raise_duplicated_keys!(keys, [])
    sorted = Enum.sort(keys)
    await_sorted(mutex, sorted, :infinity, [])
  end

  @spec raise_duplicated_keys!([key], [key]) :: :ok | no_return()
  defp raise_duplicated_keys!([h | t], acc) do
    if h in acc do
      raise ArgumentError, "keys must be unique, duplicate key: #{inspect(h)}"
    end

    raise_duplicated_keys!(t, [h | acc])
  end

  defp raise_duplicated_keys!([], _acc), do: :ok

  # Waiting multiple keys and avoiding deadlocks. It is enough to simply lock
  # the keys sorted. @optimize send all keys to the server and get {locked,
  # busies} as reply, then start over with the busy ones

  defp await_sorted(_mutex, [], :infinity, locked_keys) do
    keys_to_multilock(:lists.reverse(locked_keys))
  end

  defp await_sorted(mutex, [key | keys], :infinity, locked_keys) do
    case safe_await_infinity(mutex, key) do
      :ok ->
        await_sorted(mutex, keys, :infinity, [key | locked_keys])

      {:error, :self_deadlock} ->
        await_all_failure(mutex, %LockError{key: key, cause: :self_deadlock}, locked_keys)
    end
  end

  defp keys_to_multilock(keys),
    do: %Lock{type: :multi, keys: keys}

  @spec await_all_failure(name, Exception.t(), [key]) :: no_return()
  defp await_all_failure(mutex, error, keys) do
    :ok = call_release(mutex, %Lock{type: :multi, keys: keys})
    raise error
  end

  @doc """
  Releases the given lock synchronously.

  Returns `:ok` once the keys of the lock are unlocked, making them available to
  other processes.

  Returns `{:error, error}` with a `Mutex.ReleaseError` when a key of the lock
  is not locked by the calling process in the mutex.
  """
  @spec release(mutex :: name, lock :: Lock.t()) :: :ok | {:error, ReleaseError.t()}
  def release(mutex, lock) do
    case call_release(mutex, lock) do
      :ok -> :ok
      {:error, reason} -> {:error, ReleaseError.of(reason, lock.type, lock_to_key_or_keys(lock), :release, self())}
    end
  end

  @doc """
  Releases the given lock synchronously, raising when the release fails.

  Returns `:ok` once the keys of the lock are unlocked, making them available to
  other processes.

  Raises a `Mutex.ReleaseError` when a key of the lock is not locked by the
  calling process in the mutex.
  """
  @spec release!(mutex :: name, lock :: Lock.t()) :: :ok
  def release!(mutex, lock) do
    case release(mutex, lock) do
      :ok -> :ok
      {:error, e} -> raise e
    end
  end

  defp call_release(mutex, %Lock{type: :single, key: key}) do
    GenServer.call(mutex, {:release, :single, key, self()})
  end

  defp call_release(mutex, %Lock{type: :multi, keys: keys}) do
    GenServer.call(mutex, {:release, :multi, keys, self()})
  end

  @doc """
  Tells the mutex to free the given lock and immediately returns `:ok` without
  waiting for the actual release.

  Unlike `release/2`, this function will not raise if the calling process is
  not lock owner. In that case, the lock is not released and an error is
  logged.

  Supports only single key locks.
  """
  def release_async(mutex, %Lock{type: :single, key: key}),
    do: GenServer.cast(mutex, {:release, :single, key, self()})

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

  If an exception is raised or thrown in the fun, the lock is automatically
  released.

  If a function of arity 1 is given, it will be passed the lock. Otherwise the
  arity must be 0. You should not manually release the lock within the function.

  The lock is awaited as in `await/3`, with the same timeout and error
  behaviors.
  """
  @doc since: "3.0.0"
  @spec with_lock(mutex :: name, key :: key, timeout :: timeout, fun :: (-> any) | (Lock.t() -> any)) :: any
  def with_lock(mutex, key, timeout \\ :infinity, fun)

  def with_lock(mutex, key, timeout, fun) when is_function(fun, 0),
    do: with_lock(mutex, key, timeout, fn _ -> fun.() end)

  def with_lock(mutex, key, timeout, fun) when is_function(fun, 1) do
    lock = await(mutex, key, timeout)
    apply_with_lock(mutex, lock, fun)
  end

  @doc """
  Awaits a lock for the given keys, executes the given fun and releases the lock
  immediately.

  If an exception is raised or thrown in the fun, the lock is automatically
  released.

  If a function of arity 1 is given, it will be passed the lock. Otherwise the
  arity must be 0. You should not manually release the lock within the function.

  The keys are awaited as in `await_all/2`, with the same unique keys
  requirement and error behaviors.
  """
  @doc since: "3.0.0"
  @spec with_lock_all(mutex :: name, keys :: [key], fun :: (-> any) | (Lock.t() -> any)) :: any
  def with_lock_all(mutex, keys, fun) when is_function(fun, 0),
    do: with_lock_all(mutex, keys, fn _ -> fun.() end)

  def with_lock_all(mutex, keys, fun) when is_function(fun, 1) do
    lock = await_all(mutex, keys)
    apply_with_lock(mutex, lock, fun)
  end

  defp apply_with_lock(mutex, lock, fun) do
    fun.(lock)
  after
    release!(mutex, lock)
  end

  @doc "Alias for `with_lock/4`."
  @deprecated "use with_lock/4 instead"
  def under(mutex, key, timeout \\ :infinity, fun) do
    with_lock(mutex, key, timeout, fun)
  end

  @doc "Alias for `with_lock/3`."
  @deprecated "use with_lock/3 instead"
  def under_all(mutex, key, fun) do
    with_lock_all(mutex, key, fun)
  end

  @doc """
  Sets the process identified by `pid` as the new owner of the `lock`.

  If successful, that new owner will be sent a `{:"MUTEX-TRANSFER", from_pid,
  lock, gift_data}` message. If it is not alive, the lock will be released.

  Raises a `Mutex.ReleaseError` when the calling process does not own the
  lock.

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

      {:error, reason} ->
        raise ReleaseError.of(reason, :single, key, :give_away, from_pid)
    end
  end

  # -- Via Callbacks ----------------------------------------------------------

  @doc false
  @spec whereis_name({mutex :: name, key :: key}) :: pid | :undefined
  def whereis_name({mutex, key}) do
    case GenServer.call(mutex, {:where, key}) do
      nil -> :undefined
      pid when node(pid) == node() -> if Process.alive?(pid), do: pid, else: :undefined
      pid -> pid
    end
  end

  @doc false
  @spec register_name({mutex :: name, key :: key}, pid) :: :yes | :no
  def register_name({mutex, key}, pid) do
    true = self() == pid

    # As in :global, no special case when the name owner is already self()
    case Mutex.lock(mutex, key) do
      {:ok, _lock} -> :yes
      {:error, %LockError{cause: {:locked, _}}} -> :no
    end
  end

  @doc false
  @spec unregister_name({mutex :: name, key :: key}) :: :ok
  def unregister_name({mutex, key}) do
    _ = release(mutex, %Lock{type: :single, key: key})
    :ok
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
end
