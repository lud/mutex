defmodule Mutex.ExampleTest do
  require Logger
  use ExUnit.Case, async: true

  @moduletag :capture_log

  setup do
    {:ok, _pid} = start_supervised({Mutex, name: MyApp.Mutex})
    :ok
  end

  describe "basic usage" do
    test "file count" do
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

      # counter = String.to_integer(File.read!(path))
      # IO.puts("Total count is: #{counter}")
    end
  end

  describe "give away" do
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

    test "readme example" do
      Process.register(self(), :test_process)
      {:ok, _} = Task.Supervisor.start_link(name: Encoding.Supervisor)
      handle_request(%{path: "/some/path"})
      assert_receive {:encoding, "/some/path"}
      assert %Mutex.Lock{} = Mutex.await(MyApp.Mutex, :encoding_server)
      assert_receive {:cleaning, "/some/path"}
    end
  end
end
