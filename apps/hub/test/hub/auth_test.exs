defmodule Hub.AuthTest do
  @moduledoc """
  Issue #473 Cut 2: Open-Redirect-Guard in take_return_to (safe_local_path/2).
  Nur lokale Pfade dürfen als return_to durchgehen; protokoll-relative/externe
  URLs fallen auf den Default zurück.
  """

  use ExUnit.Case, async: true

  alias Hub.Auth

  test "lokaler Pfad bleibt erhalten" do
    assert Auth.safe_local_path("/campaigns/abc", "/") == "/campaigns/abc"
    assert Auth.safe_local_path("/invite/xyz?foo=1", "/") == "/invite/xyz?foo=1"
    assert Auth.safe_local_path("/", "/dash") == "/"
  end

  test "protokoll-relative URL (//host) → default" do
    assert Auth.safe_local_path("//evil.example.com", "/") == "/"
  end

  test "backslash-Trick (/\\host) → default" do
    assert Auth.safe_local_path("/\\evil.example.com", "/") == "/"
  end

  test "absolute externe URL / Nicht-Pfad → default" do
    assert Auth.safe_local_path("https://evil.example.com", "/") == "/"
    assert Auth.safe_local_path("evil", "/") == "/"
    assert Auth.safe_local_path(nil, "/dash") == "/dash"
  end
end
