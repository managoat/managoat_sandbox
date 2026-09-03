defmodule Managoat.Sandbox.Daytona.ToolboxTest do
  use ExUnit.Case, async: false

  alias Managoat.Sandbox.Daytona.Toolbox

  @url "https://proxy.test/toolbox/sbx-1"

  setup do
    previous = Application.get_env(:managoat_sandbox, Managoat.Sandbox.Daytona, [])

    Application.put_env(
      :managoat_sandbox,
      Managoat.Sandbox.Daytona,
      api_key: "daytona_test_key",
      req_options: [plug: {Req.Test, __MODULE__}, retry: false]
    )

    on_exit(fn ->
      Application.put_env(:managoat_sandbox, Managoat.Sandbox.Daytona, previous)
    end)

    :ok
  end

  test "exec and session operations use the toolbox wire contract" do
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, raw_body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:request, conn.method, conn.request_path, conn.query_string, raw_body})

      case {conn.method, conn.request_path} do
        {"POST", "/toolbox/sbx-1/process/execute"} ->
          Req.Test.json(conn, %{"result" => "hello", "exitCode" => 7})

        {"POST", "/toolbox/sbx-1/process/session"} ->
          Plug.Conn.send_resp(conn, 204, "")

        {"GET", "/toolbox/sbx-1/process/session"} ->
          Req.Test.json(conn, [%{"sessionId" => "sess-1"}])

        {"POST", "/toolbox/sbx-1/process/session/sess-1/exec"} ->
          Req.Test.json(conn, %{"cmdId" => "cmd-1"})

        {"GET", "/toolbox/sbx-1/process/session/sess-1/command/cmd-1"} ->
          Req.Test.json(conn, %{"id" => "cmd-1", "exitCode" => nil})

        {"POST", "/toolbox/sbx-1/process/session/sess-1/command/cmd-1/input"} ->
          Plug.Conn.send_resp(conn, 204, "")

        {"GET", "/toolbox/sbx-1/process/session/sess-1/command/cmd-1/logs"} ->
          Plug.Conn.send_resp(conn, 200, <<1, 1, 1, "output">>)

        {"POST", "/toolbox/sbx-1/files/upload-v2"} ->
          Plug.Conn.send_resp(conn, 204, "")
      end
    end)

    assert %Req.Request{} = Toolbox.req(@url)

    assert {:ok, "hello", 7} =
             Toolbox.execute(@url, "echo hello",
               dir: "/work",
               env: [{:A, 1}],
               timeout: 500
             )

    assert :ok = Toolbox.create_session(@url, "sess-1")
    assert {:ok, [%{"sessionId" => "sess-1"}]} = Toolbox.list_sessions(@url)
    assert {:ok, "cmd-1"} = Toolbox.exec_async(@url, "sess-1", "bash -lc true")
    assert {:ok, %{"id" => "cmd-1"}} = Toolbox.get_command(@url, "sess-1", "cmd-1")
    assert :ok = Toolbox.send_input(@url, "sess-1", "cmd-1", ["hel", "lo"])
    assert {:ok, <<1, 1, 1, "output">>} = Toolbox.get_logs(@url, "sess-1", "cmd-1")
    assert :ok = Toolbox.write_file(@url, "/work/file.txt", ["con", "tents"])

    assert_received {:request, "POST", "/toolbox/sbx-1/process/execute", _, execute_body}

    assert Jason.decode!(execute_body) == %{
             "command" => "echo hello",
             "cwd" => "/work",
             "env" => %{"A" => "1"},
             "timeout" => 1
           }

    assert_received {:request, "POST", "/toolbox/sbx-1/process/session/sess-1/exec", _,
                     async_body}

    assert Jason.decode!(async_body) == %{
             "command" => "bash -lc true",
             "runAsync" => true,
             "suppressInputEcho" => true
           }

    assert_received {:request, "POST",
                     "/toolbox/sbx-1/process/session/sess-1/command/cmd-1/input", _, input_body}

    assert Jason.decode!(input_body) == %{"data" => "hello"}
    assert_received {:request, "POST", "/toolbox/sbx-1/files/upload-v2", query, _}
    assert query =~ "path=%2Fwork%2Ffile.txt"
  end

  test "execute accepts fallback output/code keys and defaults" do
    {:ok, response} = Agent.start_link(fn -> %{"output" => "fallback", "code" => 3} end)
    Req.Test.stub(__MODULE__, &Req.Test.json(&1, Agent.get(response, fn value -> value end)))

    assert {:ok, "fallback", 3} = Toolbox.execute(@url, "false", [])
    Agent.update(response, fn _ -> %{} end)
    assert {:ok, "", 0} = Toolbox.execute(@url, "true", timeout: :infinity)
  end

  test "session listing accepts the wrapped response shape" do
    Req.Test.stub(__MODULE__, &Req.Test.json(&1, %{"sessions" => [%{"id" => "sess-1"}]}))
    assert {:ok, [%{"id" => "sess-1"}]} = Toolbox.list_sessions(@url)
  end

  test "async exec accepts all documented id keys and rejects missing ids" do
    {:ok, response} = Agent.start_link(fn -> %{"commandId" => "cmd-2"} end)
    Req.Test.stub(__MODULE__, &Req.Test.json(&1, Agent.get(response, fn value -> value end)))

    assert {:ok, "cmd-2"} = Toolbox.exec_async(@url, "sess", "true")
    Agent.update(response, fn _ -> %{"id" => "cmd-3"} end)
    assert {:ok, "cmd-3"} = Toolbox.exec_async(@url, "sess", "true")
    Agent.update(response, fn _ -> %{"unexpected" => true} end)

    assert {:error, {:no_command_id, %{"unexpected" => true}}} =
             Toolbox.exec_async(@url, "sess", "true")
  end

  test "already-existing sessions and absent commands have semantic results" do
    Req.Test.stub(__MODULE__, fn conn ->
      status = if conn.method == "POST", do: 409, else: 404
      Plug.Conn.send_resp(conn, status, "gone")
    end)

    assert :ok = Toolbox.create_session(@url, "sess")
    assert {:error, :not_found} = Toolbox.get_command(@url, "sess", "gone")
  end

  test "each operation preserves non-success HTTP errors" do
    Req.Test.stub(__MODULE__, fn conn ->
      conn |> Plug.Conn.put_status(418) |> Req.Test.json(%{"error" => "teapot"})
    end)

    error = {:error, {:api_error, 418, %{"error" => "teapot"}}}
    assert Toolbox.execute(@url, "true", []) == error
    assert Toolbox.create_session(@url, "sess") == error
    assert Toolbox.list_sessions(@url) == error
    assert Toolbox.exec_async(@url, "sess", "true") == error
    assert Toolbox.get_command(@url, "sess", "cmd") == error
    assert Toolbox.send_input(@url, "sess", "cmd", "data") == error
    assert Toolbox.get_logs(@url, "sess", "cmd") == error
    assert Toolbox.write_file(@url, "/tmp/file", "data") == error
  end

  test "each operation preserves transport failures" do
    Req.Test.stub(__MODULE__, &Req.Test.transport_error(&1, :econnrefused))

    assert_transport_error(Toolbox.execute(@url, "true", []))
    assert_transport_error(Toolbox.create_session(@url, "sess"))
    assert_transport_error(Toolbox.list_sessions(@url))
    assert_transport_error(Toolbox.exec_async(@url, "sess", "true"))
    assert_transport_error(Toolbox.get_command(@url, "sess", "cmd"))
    assert_transport_error(Toolbox.send_input(@url, "sess", "cmd", "data"))
    assert_transport_error(Toolbox.get_logs(@url, "sess", "cmd"))
    assert_transport_error(Toolbox.write_file(@url, "/tmp/file", "data"))
  end

  defp assert_transport_error({:error, %Req.TransportError{reason: :econnrefused}}), do: :ok
end
