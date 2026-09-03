defmodule Managoat.Sandbox.E2B.CommandServerTest do
  use ExUnit.Case, async: false

  alias Managoat.Sandbox.E2B.CommandServer
  alias Managoat.Sandbox.E2B.Envd

  setup do
    previous = Application.get_env(:managoat_sandbox, Managoat.Sandbox.E2B, [])

    Application.put_env(
      :managoat_sandbox,
      Managoat.Sandbox.E2B,
      api_key: "e2b_test_key",
      base_url: "https://api.test",
      req_options: [plug: {Req.Test, __MODULE__}, retry: false]
    )

    on_exit(fn ->
      Application.put_env(:managoat_sandbox, Managoat.Sandbox.E2B, previous)
    end)

    :ok
  end

  test "chunk handling maps start, output, ignored data, and exit events" do
    state = state()

    data =
      Enum.map_join(
        [
          %{"ignored" => true},
          %{"event" => %{"unknown" => true}},
          %{"event" => %{"start" => %{"pid" => 42}}},
          %{
            "event" => %{
              "data" => %{"stdout" => Base.encode64(""), "stderr" => "not base64"}
            }
          },
          %{
            "event" => %{
              "data" => %{
                "stdout" => Base.encode64("out"),
                "stderr" => Base.encode64("err")
              }
            }
          }
        ],
        &Envd.encode_frame/1
      )

    assert {:noreply, started} = CommandServer.handle_info({:chunk, data}, state)
    assert started.started?
    assert_receive {:stdout, %{ref: ref}, "out"} when ref == state.ref
    assert_receive {:stderr, %{ref: ref}, "err"} when ref == state.ref

    terminal = Envd.encode_frame(%{"event" => %{"end" => %{"exitCode" => 6}}})
    assert {:stop, :normal, exited} = CommandServer.handle_info({:chunk, terminal}, started)
    assert exited.exited?
    assert_receive {:exit, %{ref: ref}, 6} when ref == state.ref
  end

  test "end-stream errors and clean closes emit exactly one terminal frame" do
    state = state()
    error_frame = end_stream(%{"error" => %{"code" => "unavailable"}})

    assert {:stop, :normal, exited} =
             CommandServer.handle_info({:chunk, error_frame}, state)

    assert_receive {:error, %{ref: ref}, %{"code" => "unavailable"}} when ref == state.ref

    # Once terminal, later frames cannot produce a second verdict.
    assert {:stop, :normal, ^exited} =
             CommandServer.handle_info({:chunk, end_stream()}, exited)

    refute_receive {:exit, _, _}

    clean = state()
    assert {:stop, :normal, _} = CommandServer.handle_info({:chunk, end_stream()}, clean)
    assert_receive {:exit, %{ref: ref}, 0} when ref == clean.ref
  end

  test "stdin calls map 404 to command_exited and pass through other results" do
    {:ok, status} = Agent.start_link(fn -> 200 end)

    Req.Test.stub(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_status(Agent.get(status, & &1))
      |> Req.Test.json(%{"error" => "gone"})
    end)

    state = state()

    assert {:reply, {:ok, %{"error" => "gone"}}, ^state} =
             CommandServer.handle_call({:write_stdin, "hello"}, nil, state)

    assert {:reply, {:ok, %{"error" => "gone"}}, ^state} =
             CommandServer.handle_call(:close_stdin, nil, state)

    Agent.update(status, fn _ -> 404 end)

    assert {:reply, {:error, :command_exited}, ^state} =
             CommandServer.handle_call({:write_stdin, "late"}, nil, state)
  end

  test "await-start state variants reply immediately" do
    started = %{state() | started?: true}
    exited = %{state() | exited?: true}

    assert {:reply, :ok, ^started} = CommandServer.handle_call(:await_start, nil, started)

    assert {:reply, {:error, :command_exited}, ^exited} =
             CommandServer.handle_call(:await_start, nil, exited)

    waiting = state()
    assert {:noreply, result} = CommandServer.handle_call(:await_start, :from, waiting)
    assert result.await_from == :from
  end

  test "heartbeat handles success and provider failure" do
    {:ok, status} = Agent.start_link(fn -> 204 end)

    Req.Test.stub(__MODULE__, fn conn ->
      Plug.Conn.send_resp(conn, Agent.get(status, & &1), "failure")
    end)

    state = state()
    assert {:noreply, ^state} = CommandServer.handle_info(:heartbeat, state)
    Agent.update(status, fn _ -> 503 end)
    assert {:noreply, ^state} = CommandServer.handle_info(:heartbeat, state)
  end

  test "completed and failed stream tasks produce terminal frames" do
    for result <- [{:ok, :response}, {:error, :closed}] do
      task_pid = spawn(fn -> Process.sleep(:infinity) end)
      monitor_ref = Process.monitor(task_pid)

      task = %Task{owner: self(), pid: task_pid, ref: monitor_ref, mfa: {__MODULE__, :unused, []}}
      state = %{state() | stream_task: task}

      assert {:stop, :normal, %{stream_task: nil}} =
               CommandServer.handle_info({monitor_ref, result}, state)

      case result do
        {:ok, _} -> assert_receive {:exit, %{ref: ref}, 0} when ref == state.ref
        {:error, reason} -> assert_receive {:error, %{ref: ref}, ^reason} when ref == state.ref
      end

      Process.exit(task_pid, :kill)
    end
  end

  test "task DOWN and unrelated messages have explicit handling" do
    state = state()
    assert {:noreply, ^state} = CommandServer.handle_info(:unrelated, state)

    assert {:stop, :normal, exited} =
             CommandServer.handle_info({:DOWN, make_ref(), :process, self(), :boom}, state)

    assert exited.exited?
    assert_receive {:error, %{ref: ref}, {:stream_task_down, :boom}} when ref == state.ref
  end

  test "attach mode reads the real exit code and falls back on invalid or absent sentinels" do
    {:ok, response} = Agent.start_link(fn -> {200, "9\n"} end)

    Req.Test.stub(__MODULE__, fn conn ->
      {status, body} = Agent.get(response, & &1)
      Plug.Conn.send_resp(conn, status, body)
    end)

    for {{status, body}, expected} <- [{{200, "9\n"}, 9}, {{200, "bad"}, 4}, {{404, ""}, 4}] do
      Agent.update(response, fn _ -> {status, body} end)
      state = %{state() | exit_file: "/tmp/fountain/tag.exit"}
      terminal = Envd.encode_frame(%{"event" => %{"end" => %{"exitCode" => 4}}})

      assert {:stop, :normal, _} = CommandServer.handle_info({:chunk, terminal}, state)
      assert_receive {:exit, %{ref: ref}, ^expected} when ref == state.ref
    end
  end

  defp state do
    %{
      sandbox_id: "sbx-1",
      tag: "tag",
      ref: make_ref(),
      owner: self(),
      stdin_tag: "tag",
      request: {"process.Process/Start", %{}},
      exit_file: nil,
      buffer: <<>>,
      exited?: false,
      started?: false,
      await_from: nil,
      heartbeat: nil,
      stream_task: nil
    }
  end

  defp end_stream(map \\ %{}) do
    json = Jason.encode!(map)
    <<2, byte_size(json)::32-big, json::binary>>
  end
end
