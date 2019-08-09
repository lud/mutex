# A simple mutex for Elixir.

`Mutex` is a simple mutex module that fits under your supervision tree and allows processes to work on shared ressources one by one. This can be a simple alternative to database transactions. Also, `Mutex` supports multiple keys locking without deadlocks.

## Installation

This package can be installed by adding `mutex` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [{:mutex, "~> 1.1.0"}]
end
```

## Using Mutex

A mutex is handled by a process that you start in your supervision tree with [`child_spec(name)`](https://hexdocs.pm/mutex/Mutex.html#child_spec/1).

Options can be an atom (used as the `GenServer` name), or a `Keyword` with [`GenServer` options](https://hexdocs.pm/elixir/GenServer.html#t:options/0) and a `:meta` option to set the metadata.

```elixir
children = [
  {Mutex, name: MyMutex, meta: some_data}
]
{:ok, _pid} = Supervisor.start_link(children, strategy: :one_for_one)
```

Let's see a bad example of concurrent code without database transactions.

```elixir
resource_id = :some_user_id # unused in example
update_user = fn(worker) ->
  IO.puts "[#{worker}] Reading user from database."
  Process.sleep(250)
  IO.puts "[#{worker}] Working with user."
  Process.sleep(250)
  IO.puts "[#{worker}] Saving user in database."
  Process.sleep(500)
end
spawn(fn -> update_user.("worker 1") end)
spawn(fn -> update_user.("worker 2") end)
spawn(fn -> update_user.("worker 3") end)

# Results :
# [worker 1] Reading user from database.
# [worker 2] Reading user from database.
# [worker 3] Reading user from database.
# [worker 1] Working with user.
# [worker 2] Working with user.
# [worker 3] Working with user.
# [worker 2] Saving user in database. # 2 before 1 !
# [worker 1] Saving user in database.
# [worker 3] Saving user in database.
```

Serialized transactions could be a good fit for this specific case, but let's see another simple solution :

With a simple mutex mechanism, workers will be able to wait until the resource is saved in database before loading it, with the guarantee that any other worker will not be able to touch the resource.

Each worker will wait for the key identifying the resource to be available on the mutex and attempt to lock it. A key can be anything : `:my_resource`, `{User, user_id}`, `"http://example.com"` or more complex structures.

When the lock is eventually acquired, the worker can work with the resource. Of course, this works only if all your workers use the mutex, with the same key.

```elixir
resource_id = {User, {:id, 1}}
update_user = fn(worker) ->
  lock = Mutex.await(MyMutex, resource_id)
  IO.puts "[#{worker}] Reading user from database."
  Process.sleep(250)
  IO.puts "[#{worker}] Working with user."
  Process.sleep(250)
  IO.puts "[#{worker}] Saving user in database."
  Mutex.release(MyMutex, lock)
end
spawn(fn -> update_user.("worker 4") end)
spawn(fn -> update_user.("worker 5") end)
spawn(fn -> update_user.("worker 6") end)

# [worker 4] Reading user from database.
# [worker 4] Working with user.
# [worker 4] Saving user in database.
# [worker 5] Reading user from database.
# [worker 5] Working with user.
# [worker 5] Saving user in database.
# [worker 6] Reading user from database.
# [worker 6] Working with user.
# [worker 6] Saving user in database.
```

## Error Handling

Whenever a process that locked a key on the mutex crashes, the mutex
automatically unlocks the key so any other process can lock it in its turn.

But if you catch exceptions you may forget to release the keys and keep
unnecessary keys locked for a while :

```elixir
# Do not do this
try do
  lock = Mutex.await(MyMutex, :some_key)
  throw(:fail)
  # This will never happen:
  Mutex.release(MyMutex, lock)
catch
  :throw, :fail -> :ok
end
```

Whenever possible, avoid to lock keys in `try`, `if`, `for`, ... blocks.

The mutex provides a mechanism to automatically handle this situation. Using `Mutex.under/3`, the calling process will wait for the key to be available and lock it. Then the passed `fn` will be executed and if it raises or throws, the lock will automatically be removed. Exceptions and thrown values are reraised and rethrown so you still have to handle them.

```elixir
# Do this instead
try do
  Mutex.under(MyMutex, :some_key, fn ->
    throw(:fail)
  end)
catch
  :throw, :fail -> :ok
end
```

A multilock version is also available with `Mutex.under_all/3`.


## Avoiding Deadlocks

A deadlock would occur if the keys were locked one by one with a race condition :

    # Do not do this

    def handle_order(buyer, seller) do
      lock1 = Mutex.await(MyMutex, buyer)
      lock2 = Mutex.await(MyMutex, seller)
      do_some_work_with_users(buyer, seller)
      Mutex.release(MyMutex, lock1)
      Mutex.release(MyMutex, lock2)
    end

    spawn(fn -> handler_order(:user_1, :user_2) end) # Process 1
    spawn(fn -> handler_order(:user_2, :user_1) end) # Process 2

Process 1 will first lock `:user_1` and process 2 will lock `:user_2`, and then each process is waiting for the key that is already locked by the other one.

**If any process should have, at any given time, several keys locked, those keys shall have been locked all at once.**

This simple rule is mandatory and sufficient to be free from deadlocks, and `Mutex.await_all/2` is the simplest way to respect that rule.

    # Do this instead

    def handle_order(buyer, seller) do
      lock = Mutex.await_all(MyMutex, [buyer, seller])
      do_some_work_with_users(buyer, seller)
      Mutex.release(MyMutex, lock)
    end

If you really have to lock keys in a loop, or in mutiple moments, the `Mutex.goodbye/1` function allows to simply release all the keys locked by the calling process in one call.

## Metadata

A mutex can hold metadata that will be assigned to each lock. The metadata is set upon initialization (given as `:meta` in the child spec in your supervisor, or in the options for `Mutex.start` or `Mutex.start_link`).

Metadata can be fetched at anytime with `Mutex.get_meta/1`.

The metadata is also sent to any client that locks a key or a group of keys:

```
{:ok, pid} = Mutex.start_link(meta: :some_data)
{:ok, lock} = Mutex.lock(pid, :some_key)
lock.meta === :some_data
Mutex.Lock.get_meta(lock) === :some_data
```

The lock will also be passed to a fun if its arity is `1` when using `Mutex.under/4` and `Mutex.under_all/3`. The arity of the fun can also be `0`. Releasing the lock within the fun is still useless as it will be automatically release as for 0-arity funs, and could give other processes the ability to lock the keys before the fun execution is complete.
