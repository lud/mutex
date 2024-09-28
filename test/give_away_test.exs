defmodule Mutex.GiveAwayTest do
  import Mutex.Test.Utils
  require Logger
  use ExUnit.Case, async: true

  @moduletag :capture_log
  @mut rand_mod()

  setup do
    {:ok, _pid} = start_supervised({Mutex, name: @mut})
    :ok
  end

  test "can give away a lock" do
  end
end
