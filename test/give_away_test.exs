defmodule Mutex.GiveAwayTest do
  alias Mutex.Lock
  alias Mutex.ReleaseError
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
    assert {:ok, lock} = Mutex.lock(@mut, :gift)
    parent = self()
    assert parent == Mutex.whereis_name({@mut, :gift})

    pid =
      xspawn(fn ->
        assert_receive {:"MUTEX-TRANSFER", ^parent, ^lock, :some_data}
        hang()
      end)

    assert :ok = Mutex.give_away(@mut, lock, pid, :some_data)

    assert pid == Mutex.whereis_name({@mut, :gift})
    kill(pid)

    # Once the pid is cleaned we can lock again. We need to await because the
    # mutex will not always receive the :DOWN message from the previous owner
    # immediately.
    assert %_{} = Mutex.await(@mut, :gift)
  end

  test "default give away data is nil" do
    assert {:ok, lock} = Mutex.lock(@mut, :gift2)
    parent = self()

    pid =
      xspawn(fn ->
        assert_receive {:"MUTEX-TRANSFER", ^parent, ^lock, nil}
        hang()
      end)

    assert :ok = Mutex.give_away(@mut, lock, pid)
    assert pid == Mutex.whereis_name({@mut, :gift2})
  end

  test "cannot give away if now owning" do
    {ack, wack} = vawack()

    xspawn(fn ->
      assert {:ok, lock} = Mutex.lock(@mut, :gift3)
      ack.(lock)
      hang()
    end)

    lock = wack.()

    pid =
      xspawn(fn ->
        receive do
          :stop_from_test -> :ok
          # Should not receive any transfer message
          msg -> flunk("received message: #{inspect(msg)}")
        end
      end)

    assert_raise ReleaseError, fn -> Mutex.give_away(@mut, lock, pid) end

    # The transfer message is send from the giver process, that ensures that
    # here we can test that the givee will only receive our :stop_from_test
    # message.
    send(pid, :stop_from_test)
    await_down(pid)
  end

  test "cannot give away an unknown lock" do
    lock = %Mutex.Lock{type: :single, key: :made_up, keys: nil}
    pid = xspawn(&hang/0)
    assert_raise ReleaseError, fn -> Mutex.give_away(@mut, lock, pid) end
  end

  test "can give away to non existing pid" do
    {dead_pid, mref} = spawn_monitor(fn -> :ok end)
    assert_receive {:DOWN, ^mref, :process, ^dead_pid, :normal}
    refute Process.alive?(dead_pid)
    assert {:ok, lock} = Mutex.lock(@mut, :dead)
    assert :ok = Mutex.give_away(@mut, lock, dead_pid)

    # We can lock immediately.  Theoretically there could be a race condition
    # where the mutex would receive this lock attempt before it receives the
    # {:DOWN,_,_,_,:noproc} message when monitoring the dead pid. In practice
    # the :DOWN message is immediate by the BEAM implementation so this is not a
    # problem.
    assert {:ok, _lock} = Mutex.lock(@mut, :dead)
  end

  test "give away to self is forbidden" do
    this = self()
    assert {:ok, lock} = Mutex.lock(@mut, :to_self)
    assert_raise ArgumentError, fn -> Mutex.give_away(@mut, lock, this, :some_data) end
  end

  test "give away with multilocks" do
    # For now multilocks are considered independent locks and can be given away
    # unitarily.
    {ack, wack} = vawack()
    parent = self()

    pid =
      xspawn(fn ->
        receive do
          {:"MUTEX-TRANSFER", ^parent, lock, _} ->
            ack.(lock)
            hang()
        end
      end)

    assert %{keys: [:k1, :k2]} = Mutex.await_all(@mut, [:k1, :k2])
    assert :ok = Mutex.give_away(@mut, %Lock{type: :single, key: :k2}, pid)
    assert %Mutex.Lock{type: :single, key: :k2, keys: nil} = wack.()

    # ownership of :k2 was given but we ketp :k1
    assert self() == Mutex.whereis_name({@mut, :k1})
    assert pid == Mutex.whereis_name({@mut, :k2})
  end

  test "gift loop" do
    key = :counter
    assert {:ok, lock} = Mutex.lock(@mut, key)
    # start X processes, each one will be give the key in its turn and increment
    # the transfer_data
    n_procs = 1000

    # Note we start the loop from the "back", the first item will receive self()
    # as the "give_to" and will receive the lock last and give it to the test
    # process.
    first_pid =
      Enum.reduce(1..n_procs, self(), fn _, give_to ->
        xspawn(fn ->
          receive do
            {:"MUTEX-TRANSFER", _, lock, counter} -> Mutex.give_away(@mut, lock, give_to, counter + 1)
          end
        end)
      end)

    assert :ok = Mutex.give_away(@mut, lock, first_pid, 0)
    assert_receive({:"MUTEX-TRANSFER", _, ^lock, ^n_procs})
  end

  describe "readme example" do
    setup do
      pid = GenServer.whereis(@mut)
      Process.unregister(@mut)
      Process.register(pid, MyMutex)
      GenServer.whereis(MyMutex)
      :ok
    end

    defmodule Encoder do
      def encode_video(video_path) do
        send(:test_process, {:encoding, video_path})
        :ok
      end

      def cleanup(video_path) do
        send(:test_process, {:cleaning, video_path})
        :ok
      end
    end

    def handle_request(encoding_request) do
      case Mutex.lock(MyMutex, :encoding_server) do
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
          :ok = Mutex.give_away(MyMutex, lock, task_pid, encoding_request.path)
          "encoding started"
      end
    end

    def encode_video do
      receive do
        {:"MUTEX-TRANSFER", _, lock, video_path} ->
          Encoder.encode_video(video_path)
          Mutex.release(MyMutex, lock)
          Encoder.cleanup(video_path)
      after
        1000 -> exit(:no_lock_received)
      end
    end

    test "duc" do
      Process.register(self(), :test_process)
      {:ok, _} = Task.Supervisor.start_link(name: Encoding.Supervisor)
      handle_request(%{path: "/some/path"})
      assert_receive {:encoding, "/some/path"}
      assert {:ok, _} = Mutex.lock(MyMutex, :encoding_server)
      assert_receive {:cleaning, "/some/path"}
    end
  end
end
