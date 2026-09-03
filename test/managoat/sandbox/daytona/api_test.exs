defmodule Managoat.Sandbox.Daytona.ApiTest do
  use ExUnit.Case, async: false

  alias Managoat.Sandbox.Daytona.Api

  setup do
    previous = Application.get_env(:managoat_sandbox, Managoat.Sandbox.Daytona, [])

    Application.put_env(
      :managoat_sandbox,
      Managoat.Sandbox.Daytona,
      api_key: "daytona_test_key",
      api_url: "https://daytona.test/api",
      snapshot: "fountain-snapshot",
      req_options: [plug: {Req.Test, __MODULE__}, retry: false]
    )

    on_exit(fn ->
      Application.put_env(:managoat_sandbox, Managoat.Sandbox.Daytona, previous)
    end)

    :ok
  end

  test "configuration builds the authenticated client" do
    assert Api.base_url() == "https://daytona.test/api"
    assert Api.api_key!() == "daytona_test_key"
    assert Api.snapshot() == "fountain-snapshot"
    assert %Req.Request{} = Api.req()
  end

  test "control-plane operations and toolbox URL use provider contracts" do
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, raw_body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:request, conn.method, conn.request_path, raw_body})

      case {conn.method, conn.request_path} do
        {"POST", "/api/sandbox"} ->
          Req.Test.json(conn, %{"id" => "sbx-1"})

        {"GET", "/api/sandbox/one"} ->
          Req.Test.json(conn, %{
            "id" => "sbx-1",
            "name" => "one",
            "toolboxProxyUrl" => "https://proxy.test/toolbox/"
          })

        {"DELETE", "/api/sandbox/one"} ->
          Plug.Conn.send_resp(conn, 204, "")

        {"POST", "/api/sandbox/one/stop"} ->
          Plug.Conn.send_resp(conn, 204, "")

        {"POST", "/api/sandbox/one/start"} ->
          Plug.Conn.send_resp(conn, 204, "")

        {"POST", "/api/sandbox/one/network-settings"} ->
          Plug.Conn.send_resp(conn, 204, "")
      end
    end)

    assert {:ok, %{"id" => "sbx-1"}} = Api.create_sandbox("one")
    assert {:ok, %{"name" => "one"}} = Api.get_sandbox("one")
    assert :ok = Api.delete_sandbox("one")
    assert :ok = Api.stop("one")
    assert :ok = Api.start("one")
    assert :ok = Api.set_network("one", ["hex.pm", "github.com"])
    assert {:ok, "https://proxy.test/toolbox/sbx-1"} = Api.toolbox_url("one")

    assert_received {:request, "POST", "/api/sandbox", create_body}

    assert %{
             "name" => "one",
             "snapshot" => "fountain-snapshot",
             "labels" => %{"fountain" => "1"},
             "autoStopInterval" => 0,
             "ttlMinutes" => 0
           } = Jason.decode!(create_body)

    assert_received {:request, "POST", "/api/sandbox/one/network-settings", network_body}

    assert Jason.decode!(network_body) == %{
             "networkBlockAll" => true,
             "domainAllowList" => "hex.pm,github.com"
           }
  end

  test "create omits a snapshot when none is configured" do
    config = Application.fetch_env!(:managoat_sandbox, Managoat.Sandbox.Daytona)

    Application.put_env(
      :managoat_sandbox,
      Managoat.Sandbox.Daytona,
      Keyword.delete(config, :snapshot)
    )

    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:body, Jason.decode!(body)})
      Req.Test.json(conn, %{"id" => "sbx-1"})
    end)

    assert {:ok, _} = Api.create_sandbox("one")
    assert_received {:body, body}
    refute Map.has_key?(body, "snapshot")
  end

  test "listing follows cursors and accepts both response shapes" do
    Req.Test.stub(__MODULE__, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      case conn.query_params["cursor"] do
        nil ->
          Req.Test.json(conn, %{"items" => [%{"name" => "one"}, %{}], "nextCursor" => "next"})

        "next" ->
          Req.Test.json(conn, [%{"name" => "two"}])
      end
    end)

    assert {:ok, names} = Api.list_all_names()
    assert names == MapSet.new(["one", "two"])
    assert {:error, :truncated} = Api.list_all_names(0)
  end

  test "toolbox URL falls back to the proxy endpoint's map and string shapes" do
    {:ok, shape} = Agent.start_link(fn -> :map end)

    Req.Test.stub(__MODULE__, fn conn ->
      case conn.request_path do
        "/api/sandbox/one" ->
          Req.Test.json(conn, %{"id" => "sbx-1"})

        "/api/sandbox/sbx-1/toolbox-proxy-url" ->
          case Agent.get(shape, & &1) do
            :map -> Req.Test.json(conn, %{"url" => "https://proxy-map.test"})
            :string -> Req.Test.json(conn, "https://proxy-string.test/")
          end
      end
    end)

    assert {:ok, "https://proxy-map.test/sbx-1"} = Api.toolbox_url("one")
    Agent.update(shape, fn _ -> :string end)
    assert {:ok, "https://proxy-string.test/sbx-1"} = Api.toolbox_url("one")
  end

  test "not-found delete and get are idempotent and definitive respectively" do
    Req.Test.stub(__MODULE__, &Plug.Conn.send_resp(&1, 404, "gone"))
    assert {:error, :not_found} = Api.get_sandbox("gone")
    assert :ok = Api.delete_sandbox("gone")
  end

  test "each operation preserves non-success HTTP errors" do
    Req.Test.stub(__MODULE__, fn conn ->
      conn |> Plug.Conn.put_status(418) |> Req.Test.json(%{"error" => "teapot"})
    end)

    error = {:error, {:api_error, 418, %{"error" => "teapot"}}}
    assert Api.create_sandbox("one") == error
    assert Api.get_sandbox("one") == error
    assert Api.delete_sandbox("one") == error
    assert Api.stop("one") == error
    assert Api.start("one") == error
    assert Api.list_all_names() == error
    assert Api.set_network("one", []) == error
    assert Api.toolbox_url("one") == error
  end

  test "proxy endpoint failures are preserved" do
    Req.Test.stub(__MODULE__, fn conn ->
      case conn.request_path do
        "/api/sandbox/one" -> Req.Test.json(conn, %{"id" => "sbx-1"})
        _ -> conn |> Plug.Conn.put_status(503) |> Req.Test.json(%{"error" => "down"})
      end
    end)

    assert {:error, {:api_error, 503, %{"error" => "down"}}} = Api.toolbox_url("one")
  end

  test "missing credentials fail before a request is made" do
    Application.put_env(:managoat_sandbox, Managoat.Sandbox.Daytona, api_key: nil)
    assert_raise RuntimeError, ~r/DAYTONA_API_KEY is not set/, &Api.req/0
  end
end
