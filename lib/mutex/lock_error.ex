defmodule Mutex.LockError do
  @moduledoc """
  Reports a key that could not be locked.

  This exception is returned by `Mutex.lock/2` and raised by `Mutex.lock!/2`,
  `Mutex.await/3`, `Mutex.await_all/2`, `Mutex.with_lock/4` and
  `Mutex.with_lock_all/3`.

  The following fields are public:

  * `:key` - the key that could not be locked.
  * `:cause` - the reason why locking failed:
    * `{:locked, owner_pid}` - the key was locked by `owner_pid` when the
      mutex handled the request.
    * `:self_deadlock` - the calling process awaited a key that it already
      owns.
  """

  @typedoc "The reason why a key could not be locked."
  @type cause :: {:locked, owner_pid :: pid} | :self_deadlock

  @type t :: %__MODULE__{key: Mutex.key(), cause: cause}

  @enforce_keys [:key, :cause]
  defexception [:key, :cause]

  def message(%{cause: {:locked, owner}} = e) do
    "key #{inspect(e.key)} is already locked by #{inspect(owner)}"
  end

  def message(%{cause: :self_deadlock} = e) do
    "cannot await lock for key #{inspect(e.key)} when already owning it"
  end
end
