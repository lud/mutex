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
  Attemps to lock a resource on the mutex and returns immediately with the
  result, which is either a `Mutex.Lock` structure or `{:error, :busy}`.
  """
  @spec lock(name :: name, key :: key) :: {:ok, Lock.t()} | {:error, :busy}
  def lock(mutex, key) do
    case GenServer.call(mutex, {:lock, key, self(), false}) do
      :ok -> {:ok, key_to_lock(key)}
      {:error, :busy} -> {:error, :busy}
    end
  end

  defp key_to_lock(key), do: %Lock{type: :single, key: key}
  defp lock_to_key_or_keys(%Lock{type: :single, key: key}), do: key
  defp lock_to_key_or_keys(%Lock{type: :multi, keys: keys}), do: keys

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
      :ok -> key_to_lock(key)
      {:available, ^key} -> await(mutex, key, :infinity)
    end
  end

  def await(mutex, key, timeout) do
    now = System.system_time(:millisecond)

    case GenServer.call(mutex, {:lock, key, self(), true}, timeout) do
      :ok ->
        key_to_lock(key)

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
    keys_to_multilock(:lists.reverse([last | locked_keys]))
  end

  defp await_sorted(mutex, [key | keys], :infinity, locked_keys) do
    _lock = await(mutex, key, :infinity)
    await_sorted(mutex, keys, :infinity, [key | locked_keys])
  end

  defp keys_to_multilock(keys),
    do: %Lock{type: :multi, keys: keys}

  @doc """
  Releases the given lock synchronously.

  """
  @spec release(mutex :: name, lock :: Lock.t()) :: :ok
  def release(mutex, lock) do
    case call_release(mutex, lock) do
      :ok -> :ok
      {:error, reason} -> raise ReleaseError.of(reason, lock.type, lock_to_key_or_keys(lock), :release, self())
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
  Awaits a lock for the given key, executes the given fun and releases
  the lock immediately.

  If an exeption is raised or thrown in the fun, the lock is
  automatically released.

  If a function of arity 1 is given, it will be passed the lock.
  Otherwise the arity must be 0. You should not manually release the
  lock within the function.
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
  Awaits a lock for the given keys, executes the given fun and
  releases the lock immediately.

  If an exeption is raised or thrown in the fun, the lock is
  automatically released.

  If a function of arity 1 is given, it will be passed the lock.
  Otherwise the arity must be 0. You should not manually release the
  lock within the function.
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
    release(mutex, lock)
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
    release(mutex, %Lock{type: :single, key: key})
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
