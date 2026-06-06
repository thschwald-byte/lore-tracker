defmodule Worker.LLM.GoogleAuthTest do
  @moduledoc """
  Issue #633: Gemini-API-Key wird via `x-goog-api-key`-Header übertragen,
  NICHT mehr als `?key=…`-URL-Query-Parameter. Defense gegen latente
  Logging-Leaks (Req-Default-Logger / Telemetry-Events zeigen URLs eher
  als Headers).
  """

  use ExUnit.Case, async: true

  alias Worker.LLM.Google

  test "auth_headers/1 setzt x-goog-api-key, kein klassisches Bearer/Authorization" do
    headers = Google.auth_headers("sk-test-12345")
    assert {"x-goog-api-key", "sk-test-12345"} in headers
    # Keine Authorization-/Bearer-Header — Gemini nutzt seine eigene Header-Konvention.
    refute Enum.any?(headers, fn {k, _} -> String.downcase(k) == "authorization" end)
  end

  test "auth_headers/1 enthält den vollen Key — kein Truncation/Mask" do
    long_key = String.duplicate("k", 200)
    headers = Google.auth_headers(long_key)
    assert {"x-goog-api-key", long_key} in headers
  end
end
