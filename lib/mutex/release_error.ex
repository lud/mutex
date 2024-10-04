defmodule Mutex.ReleaseError do
  @moduledoc false
  defexception [:key, :owner, :releaser, :action]

  def message(e) do
    %{key: key, owner: owner, releaser: releaser, action: action} = e

    action =
      case action do
        :release -> "release"
        :give_away -> "give away"
      end

    owning =
      case owner do
        pid when is_pid(pid) -> ["locked by ", inspect(owner)]
        nil -> "(unknown key)"
      end

    to_string(["cannot ", action, " key #{inspect(key)} ", owning, " from #{inspect(releaser)} "])
  end
end
