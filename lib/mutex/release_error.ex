defmodule Mutex.ReleaseError do
  @moduledoc false

  defexception [:lock_type, :key_or_keys, :owner, :releaser, :action, :cause]

  def of(reason, lock_type, key_or_keys, action, releaser) do
    base = %__MODULE__{
      lock_type: lock_type,
      key_or_keys: key_or_keys,
      action: action,
      releaser: releaser
    }

    add_reason(base, reason)
  end

  defp add_reason(e, {:bad_owner = c, _key, owner}), do: %__MODULE__{e | cause: c, owner: owner}
  defp add_reason(e, {:unknown_key = c, _key}), do: %__MODULE__{e | cause: c}

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
