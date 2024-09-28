defmodule Mutex.LockError do
  @moduledoc false
  defexception [:key]

  def message(%{key: key}) do
    "key #{inspect(key)} is already locked"
  end
end
