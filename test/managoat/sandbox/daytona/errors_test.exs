defmodule Managoat.Sandbox.Daytona.ErrorsTest do
  use ExUnit.Case, async: true

  alias Managoat.Sandbox.Daytona.Errors

  @http_cases [
    {{:api_error, 404, %{"message" => "gone"}}, :not_found},
    {{:api_error, 401, %{"message" => "bad key"}},
     {:denied, {:http, 401, %{"message" => "bad key"}}}},
    {{:api_error, 403, %{"message" => "forbidden"}},
     {:denied, {:http, 403, %{"message" => "forbidden"}}}},
    {{:api_error, 429, %{"retryAfter" => 23}}, {:rate_limited, 23}},
    {{:api_error, 429, %{"retryAfter" => -1}}, {:rate_limited, nil}},
    {{:api_error, 429, %{"retryAfter" => "23"}}, {:rate_limited, nil}},
    {{:api_error, 429, %{"message" => "slow down"}}, {:rate_limited, nil}},
    {{:api_error, 500, %{"message" => "down"}},
     {:unavailable, {:http, 500, %{"message" => "down"}}}},
    {{:api_error, 599, "gateway"}, {:unavailable, {:http, 599, "gateway"}}},
    {{:api_error, 400, %{"message" => "bad request"}},
     {:invalid, {:http, 400, %{"message" => "bad request"}}}},
    {{:api_error, 422, ["bad input"]}, {:invalid, {:http, 422, ["bad input"]}}}
  ]

  test "normalizes every Daytona HTTP error class into the closed taxonomy" do
    for {raw, expected} <- @http_cases do
      assert Errors.normalize(raw) == expected
    end
  end

  test "normalizes provider-neutral sentinel atoms" do
    assert Errors.normalize(:not_found) == :not_found
    assert Errors.normalize(:truncated) == :truncated
    assert Errors.normalize(:timeout) == {:unavailable, :timeout}
  end

  test "normalizes Req and Mint transport failures as unavailable" do
    req = %Req.TransportError{reason: :nxdomain}
    mint = %Mint.TransportError{reason: :closed}

    assert Errors.normalize(req) == {:unavailable, req}
    assert Errors.normalize(mint) == {:unavailable, mint}
  end

  test "unknown shapes retain their provider identity in the escape hatch" do
    assert Errors.normalize({:unexpected, %{detail: 1}}) ==
             {:provider, :daytona, {:unexpected, %{detail: 1}}}
  end
end
