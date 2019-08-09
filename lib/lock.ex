defmodule Mutex.Lock do
  @moduledoc """
  This module defines a struct containing the key(s) locked with all the
  locking functions in `Mutex`.
  """
  defstruct [:type, :key, :keys, :meta]

  @typedoc """
  The struct containing the key(s) locked during a lock operation. `:type`
  specifies wether there is one or more keys.
  """
  @type t :: %__MODULE__{
          type: :single | :multi,
          key: nil | Mutex.key(),
          keys: nil | [Mutex.key()],
          meta: any
        }

  @doc """
  Returns the metadata associated with the lock. The metadata is given
  to the mutex on initialization:

      Mutex.start_link(name: MyMutex, meta: metadata)
  """
  @spec get_meta(lock :: __MODULE__.t()) :: any
  def get_meta(%{meta: meta}),
    do: meta
end
