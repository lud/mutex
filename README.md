# A simple mutex for Elixir.

`Mutex` is a simple mutex module that fits under your supervision tree and allows processes to work on shared ressources without one by one. This can be a simple alternative to database transactions. Also, `Mutex` supports multiple keys locking without deadlocks.

## Installation

This package can be installed by adding `mutex` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [{:mutex, "~> 1.0.0"}]
end
```

## Using Mutex

A mutex is handled by a process that you can start in your supervision tree with [`child_spec(name)`](https://hexdocs.pm/mutex/Mutex.html#child_spec/1) :

```elixir
children = [
  Mutex.child_spec(MyMutex)
]
{:ok, _pid} = Supervisor.start_link(children, strategy: :one_for_one)
```

Let's see a bad example of concurrent code without database transactions.
```elixir
resource_id = :some_user_id
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
spawn(fn -> update_user.("worker 4") end)

# Results :
# [worker 1] Reading user from database.
# [worker 2] Reading user from database.
# [worker 3] Reading user from database.
# [worker 1] Working with user.
# [worker 2] Working with user.
# [worker 3] Working with user.
# [worker 2] Saving user in database. # Order is even lost
# [worker 1] Saving user in database.
# [worker 3] Saving user in database.
```elixir

Serialized transactions could be a good fit for this specific case, but let's see a simple solution :

With a simple mutex mechanism, workers will be able to wait until the resource is saved in database before loading it, with the guarantee that any other worker will not be traying to touch the resource.

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

    spawn fn -> handler_order(:user_1, :user_2) end # Process 1
    spawn fn -> handler_order(:user_2, :user_1) end # Process 2

Process 1 will first lock `:user_1` and proces 2 will lock `:user_2`, and then each process is waiting for the key already locked by the other one.

**If any process should have, at any given time, several keys locked, those keys must have been locked all at once.**

This simple rule is mandatory and sufficient to be free from deadlocks, and `Mutex.await_all/2` is the simple way to respect that rule.

    # Do this instead

    def handle_order(buyer, seller) do
      lock = Mutex.await_all(MyMutex, [buyer, seller])
      do_some_work_with_users(buyer, seller)
      Mutex.release(MyMutex, lock)
    end

If you really have to lock keys in a loop, or in mutiple moment, the `Mutex.goodbye/1` function allows to simply release all the keys locked by the calling process in one call.
