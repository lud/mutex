defmodule Mutex.ReleaseError do
  @moduledoc """
  Reports a lock that could not be released or given away.

  This exception is returned by `Mutex.release/2` and raised by
  `Mutex.release!/2` and `Mutex.give_away/4`.

  The following fields are public:

  * `:key_or_keys` - the key of a single lock, or the list of keys of a
    multilock.
  * `:lock_type` - `:single` or `:multi`.
  * `:action` - the attempted operation, `:release` or `:give_away`.
  * `:releaser` - the pid of the process that attempted the operation.
  * `:cause` - the reason why the operation failed:
    * `:bad_owner` - a key is locked by another process. The pid of that
      process is then set in the `:owner` field.
    * `:unknown_key` - a key is not locked in the mutex.
  * `:owner` - the pid of the process owning a key of the lock when the cause
    is `:bad_owner`, otherwise `nil`.
  """

  @type t :: %__MODULE__{
          lock_type: :single | :multi,
          key_or_keys: Mutex.key() | [Mutex.key()],
          owner: pid | nil,
          releaser: pid,
          action: :release | :give_away,
          cause: :bad_owner | :unknown_key
        }

  defexception [:lock_type, :key_or_keys, :owner, :releaser, :action, :cause]

  @doc false
  def of(reason, lock_type, key_or_keys, action, releaser) do
    base = %__MODULE__{
      lock_type: lock_type,
      key_or_keys: key_or_keys,
      action: action,
      releaser: releaser
    }

    add_reason(base, reason)
  end

  defp add_reason(%__MODULE__{} = e, {:bad_owner = c, _key, owner}), do: %{e | cause: c, owner: owner}
  defp add_reason(%__MODULE__{} = e, {:unknown_key = c, _key}), do: %{e | cause: c}

  def message(e) do
    %{lock_type: lock_type, key_or_keys: key_or_keys, owner: owner, releaser: releaser, action: action, cause: cause} =
      e

    action =
      case action do
        :release -> "release"
        :give_away -> "give away"
      end

    cause =
      case {owner, cause} do
        {pid, _} when is_pid(pid) -> ["locked by ", inspect(owner)]
        {_, :unknown_key} -> "unknown key"
      end

    to_string(["cannot ", action, " ", format_key(lock_type, key_or_keys), " from #{inspect(releaser)}, ", cause])
  end

  defp format_key(:single, key), do: ["key ", inspect(key)]
  defp format_key(:multi, keys), do: ["keys ", inspect(keys)]
end
