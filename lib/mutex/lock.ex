defmodule Mutex.Lock do
  @moduledoc """
  This module defines a struct containing the key(s) locked with all the
  locking functions in `Mutex`.
  """
  defstruct [:type, :key, :keys]

  @typedoc """
  The struct containing the key(s) locked during a lock operation. `:type`
  specifies wether there is one or more keys.
  """
  @type t :: %__MODULE__{
          type: :single | :multi,
          key: nil | Mutex.key(),
          keys: nil | [Mutex.key()]
        }
end
