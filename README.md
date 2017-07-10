# A simple mutex for Elixir.

`Mutex` is a simple mutex module that fits under your supervision tree and allows processes to work on shared ressources without one by one. This can be a simple alternative to database transactions. Also, `Mutex` supports multiple keys locking without deadlocks.

## Installation

This package can be installed by adding `mut` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [{:mut, "~> 1.0.0"}]
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

Now you can use the mutex to allow different processes to work with a same resource identified by a key. A key can be anything : `:my_resource`, `{User, user_id}`, "http://example.com".

Each worker will wait for the key to be available on the mutex and attempt to lock it. When the lock is eventually acquired, the worker can work with the resource with the guarantee that any other worker will touch the resource. Of course, this works only if all your workers use the mutex, with the same key :

```elixir
ressource_id = :some_user_id
expensive_function = fn(worker) ->
  :ok = Mutex.await(MyMutex, ressource_id)
  IO.puts "[#{worker}] Begining work on resource."
  Process.sleep(500)
  IO.puts "[#{worker}] Done."
  :ok = Mutex.release(MyMutex, ressource_id)
end
spawn(fn -> expensive_function.("worker 1") end)
spawn(fn -> expensive_function.("worker 2") end)
spawn(fn -> expensive_function.("worker 3") end)
spawn(fn -> expensive_function.("worker 4") end)

# Result :
# [worker 1] Begining work on resource.
# [worker 1] Done.
# [worker 2] Begining work on resource.
# [worker 2] Done.
# [worker 3] Begining work on resource.
# [worker 3] Done.
# [worker 4] Begining work on resource.
# [worker 4] Done.
```

## Error Handling

Whenever a process that locked a key on the mutex crashes, the mutex
automatically unlocks the key so any other process can lock it in its turn.

If you lock a key within a `try` expression in a long running process, you may
keep unnecessary keys locked for a while :

```elixir
try do
  Mutex.await(MyMutex, :some_key)
  throw(:fail)
  Mutex.release(MyMutex, :some_key) # This will never happen
catch
  :throw, :fail -> :ok
end
```

Whenever possible, avoid to lock keys in such constructs.

The mutex provides a mechanism to automatically handle this situation. Using `:under`, the calling process will wait for the key to be available and lock it. Then the passed `fn` will be executed and if it raises or throws, the lock will automatically be removed. Exceptions and thrown values are reraised and rethrown so you still have to handle them.

```elixir
try do
  Mutex.await(MyMutex, :some_key)
  Mutex.under(MyMutex, :some_key, fn ->
    throw(:fail)
  end)
catch
  :throw, :fail -> :ok
end
```

## Avoiding Deadlocks

A deadlock would occur if the keys were locked one by one with a race condition :

    # DO NOT DO THAT

    def handle_order(buyer, seller) do
      Mutex.await(MyMutex, buyer)
      Mutex.await(MyMutex, seller)
      do_some_work_with_users(buyer, seller)
    end

    spawn fn -> handler_order(:user_1, :user_2) end # Process 1
    spawn fn -> handler_order(:user_2, :user_1) end # Process 2

    spawn fn -> handler_order(:user_1, :user_2) end # Process 1
    spawn fn -> handler_order(:user_2, :user_1) end # Process 2

Process 1 will first lock `:user_1` and proces 2 will lock `:user_2`, and then each process is waiting for the key locked by the other one.

**If any process should have, at any given time, several keys locked, those keys must have been locked at once.**

This simple rule is mandatory and sufficient to be free from deadlocks, and `await_all/2` is the simple way to respect that rule.

    # Do this instead :

    def handle_order(buyer, seller) do
      Mutex.await_all(MyMutex, [buyer, seller])
      do_some_work_with_users(buyer, seller)
    end
