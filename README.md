# A simple mutex for Elixir

[![Module Version](https://img.shields.io/hexpm/v/mutex.svg)](https://hex.pm/packages/mutex)
[![Hex Docs](https://img.shields.io/badge/hex-docs-lightgreen.svg)](https://hexdocs.pm/mutex/)
[![License](https://img.shields.io/hexpm/l/mutex.svg)](https://github.com/lud/mutex/blob/master/LICENSE.md)
[![Last Updated](https://img.shields.io/github/last-commit/lud/mutex.svg)](https://github.com/lud/mutex/commits/main)

`Mutex` is a lightweight mutex or "locks" implementation that fits under your
supervision tree and allows processes to work on shared ressources one by one.

This can be a simple alternative to job queues or filesystem transactions and
allows to limit resource usage on a server.

Also, `Mutex` supports locking multiple keys without deadlocks.


- [Documentation](#documentation)
- [Installation](#installation)
- [Basic usage](#basic-usage)
- [Error Handling](#error-handling)
- [Avoiding Deadlocks](#avoiding-deadlocks)
- [Lock handover](#lock-handover)
- [Name registration](#name-registration)
- [Metadata (Removed)](#metadata-removed)
- [Copyright and License](#copyright-and-license)


## [Documentation](https://hexdocs.pm/mutex/)

The documentation is hosted on [Hexdocs](https://hexdocs.pm/mutex/).


## Installation

This package can be installed by adding `:mutex` to your list of dependencies in
`mix.exs`:

```elixir
def deps do
  [
    {:mutex, "~> 3.0"},
  ]
end
```


## Basic usage

This library implements a mutex as a process that you would generally start
under a supervision tree.

See [start_link/1](https://hexdocs.pm/mutex/Mutex.html#start_link/1) for options.

```elixir
defmodule MyApp.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Mutex, name: MyApp.Mutex}
    ]

    Supervisor.start_link(children, strategy: :one_for_one)
  end
end
```

Now from anywhere in the application code you can lock access to a a resource
with the guarantee that no concurrent execution of that code can be executed.

Of course, this requires that all code attempting to access that resource uses
the mutex as well.

```elixir
lock = Mutex.await(MyApp.Mutex, :file_manager)
do_something_with_the_filesystem(arg)
:ok = Mutex.release(MyApp.Mutex, lock)
```

To automatically lock and release the key, use `Mutex.with_lock/3`:

```elixir
Mutex.with_lock(MyApp.Mutex, :file_manager, fn ->
  do_something_with_the_filesystem(arg)
end)
```

Here is a more complete example of working with storing data in a file:

```elixir
path = "/tmp/counter-#{System.system_time(:microsecond)}"

File.write!(path, "0")

tasks =
  for _ <- 1..10 do
    Task.async(fn ->
      Mutex.with_lock(MyApp.Mutex, :file_manager, fn ->
        counter = String.to_integer(File.read!(path))
        File.write!(path, Integer.to_string(counter + 1))
      end)
    end)
  end

Enum.each(tasks, &Task.await/1)

counter = String.to_integer(File.read!(path))
IO.puts("Total count is: #{counter}")
```

This will output:

```
Total count is: 10
```

The same code but without the mutex will generally give a final value of `1`.


## Error Handling

Whenever a process that locked a key on the mutex crashes, the mutex
automatically unlocks the key so any other process can lock it in its turn.

But if you catch exceptions you may forget to release the keys and keep
unnecessary keys locked for a while :

```elixir
# Do not do this
try do
  lock = Mutex.await(MyApp.Mutex, :some_key)
  throw(:fail)
  # This will never be called:
  Mutex.release(MyApp.Mutex, lock)
catch
  :throw, :fail -> :ok
end
```

Whenever possible, avoid to lock keys in `try`, `if`, `for`, ... blocks.

When using `Mutex.with_lock/3`, the lock will be automatically released if the
given fun raises, throws, or exits.

Exceptions and thrown values are reraised and rethrown so you still have to
handle them.

```elixir
# Do this instead
try do
  Mutex.with_lock(MyApp.Mutex, :some_key, fn ->
    throw(:fail)
  end)
catch
  :throw, :fail -> :ok
end
```

A multilock version is also available with `Mutex.with_lock_all/3`.

Both functions can accept a fun of arity `1` that will be given the lock as its
argument.


## Avoiding Deadlocks

A deadlock would occur if multiple processes would attempt to lock the same keys
in a different order:

```elixir
  # Do not do this

  def handle_order(buyer, seller) do
    lock1 = Mutex.await(MyApp.Mutex, buyer)
    lock2 = Mutex.await(MyApp.Mutex, seller)
    do_some_work_with_users(buyer, seller)
    Mutex.release(MyApp.Mutex, lock1)
    Mutex.release(MyApp.Mutex, lock2)
  end

  spawn(fn -> handler_order(:user_1, :user_2) end) # Process 1
  spawn(fn -> handler_order(:user_2, :user_1) end) # Process 2
```

Process 1 will first lock `:user_1` and process 2 will lock `:user_2`, and then
each process is waiting for the key that is already locked by the other one.

**If any process should have, at any given time, several keys locked, those keys
shall have been locked all at once.**

This simple rule is enough to be free from deadlocks, and `Mutex.await_all/2` is
the simplest way to respect that rule.

```elixir
# Do this instead

def handle_order(buyer, seller) do
  lock = Mutex.await_all(MyApp.Mutex, [buyer, seller])
  do_some_work_with_users(buyer, seller)
  Mutex.release(MyApp.Mutex, lock)
end
```

If you really have to lock keys in a loop, or at different places, the
`Mutex.goodbye/1` function allows to simply release all the keys locked by the
calling process at once.


## Lock handover

It is possible to transfer ownership of a lock to another process with the
`Mutex.give_away/4` function.

This is useful if you need to check that a resource is available and then start
a long running process that needs the lock and terminate quickly.

For instance, we want to have one instance only of a video encoding process in
our application. Video encoding is started from a web controller that needs to
send an HTTP response in a timely fashion.

```elixir
def handle_request(encoding_request) do
  case Mutex.lock(MyApp.Mutex, :encoding_server) do
    {:error, :busy} ->
      "encoding not available"

    {:ok, lock} ->
      {:ok, task_pid} =
        Task.Supervisor.start_child(
          Encoding.Supervisor,
          &encode_video/0
        )

      # Here we pass the video path as the "gift data" but in the real world
      # that should be given as an argument to the task function.
      :ok = Mutex.give_away(MyApp.Mutex, lock, task_pid, encoding_request.path)
      "encoding started"
  end
end

def encode_video do
  receive do
    {:"MUTEX-TRANSFER", _, lock, video_path} ->
      Encoder.encode_video(video_path)
      Mutex.release(MyApp.Mutex, lock)
      Encoder.cleanup(video_path)
  after
    1000 -> exit(:no_lock_received)
  end
end
```


## Name registration

Processes having a key locked in a `Mutex` can be called using a `:via` tuple with `GenServer.call/3` or `GenServer.cast/2`.

The `:via` tuple is built as follows:

```elixir
{
  :via,
  Mutex,
  {<mutex_name_or_pid>, <key>}
}
```

Example calling a `GenServer` process with such tuples:

```elixir
{:ok, _} = Mutex.start_link(name: MyApp.Mutex)

defmodule MyGenServer do
  def init(_), do: Mutex.lock(MyApp.Mutex, :some_key)
  def handle_call(:greetings, _, state), do: {:reply, :hello, state}
end

{:ok, _} = GenServer.start_link(MyGenServer, [])
:hello = GenServer.call({:via, Mutex, {MyApp.Mutex, :some_key}}, :greetings)
```

This lets you check if a key is currently locked in the Mutex:

```
# Returns #PID<…> or nil
GenServer.whereis({:via, Mutex, {MyApp.Mutex, :some_key}})
```

As any other name registry, you can directly set the name of your process in `GenServer.start_link/3`:

```elixir
GenServer.start_link(MyGenServer, [], name: {:via, Mutex, {MyApp.Mutex, :some_key}})
```

In this case the lock is automatically taken by the `GenServer` process.

**Important**, this mechanism is intended for use with mutexes handling a small
amount of processes working together. Do not use name registration with a single
mutex in you application or you could get bottlenecks. The
[Registry](https://hexdocs.pm/elixir/Registry.html#module-using-in-via) module
is intended for such uses and supports unique keys and partitionning registered
keys for performance.



## Metadata (Removed)

A Mutex process could carry metadata attached to it and would send it to any
process acquiring a lock. This has been removed as it was confusing. Metadata
was not tied to a given key but to the mutex itself.

To replace this functionality, you may use a `Registry`, an ETS table,
`:persistent_term` or other shared data mechanisms provided by the Elixir and
Erlang platforms.



## Copyright and License

Copyright (c) 2017, Ludovic Demblans

This work is free. You can redistribute it and/or modify it under the
terms of the MIT License. See the [LICENSE.md](./LICENSE.md) file for more details.
