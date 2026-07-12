defmodule HubWeb.RateLimitControllerTest do
  @moduledoc """
  Issue #629: End-to-End Controller-Tests — Burst gegen die drei
  Rate-Limit-geschützten Routes über den echten Router.

  10-Minuten-Fenster im Test-Overlay garantiert, dass alle Requests im
  selben `window_id` landen — kein Wanduhr-Rollover-Flake auch bei
  ausgelastetem CI-Runner (Lesson aus #795/#801).
  """
  use HubWeb.ConnCase, async: false

  alias Hub.RateLimit
  alias HubWeb.Plugs.RateLimit, as: RateLimitPlug

  setup do
    prev = Application.get_env(:hub, RateLimitPlug)

    Application.put_env(:hub, RateLimitPlug,
      proxy_config: :direct,
      limits: %{pair: {5, 600_000}, invite: {5, 600_000}, auth_callback: {5, 600_000}}
    )

    on_exit(fn ->
      if prev do
        Application.put_env(:hub, RateLimitPlug, prev)
      else
        Application.delete_env(:hub, RateLimitPlug)
      end

      RateLimit.reset(:pair, "127.0.0.1")
      RateLimit.reset(:invite, "127.0.0.1")
      RateLimit.reset(:auth_callback, "127.0.0.1")
    end)

    :ok
  end

  test "GET /pair — 5 ok, 6. == 429", %{conn: conn} do
    statuses = for _ <- 1..6, do: get(conn, "/pair?worker_id=x&callback=x").status
    {ok_statuses, [last]} = Enum.split(statuses, 5)
    assert Enum.all?(ok_statuses, &(&1 != 429))
    assert last == 429
  end

  test "GET /invite/:token — 5 ok, 6. == 429", %{conn: conn} do
    statuses = for _ <- 1..6, do: get(conn, "/invite/dummy-token").status
    {ok_statuses, [last]} = Enum.split(statuses, 5)
    assert Enum.all?(ok_statuses, &(&1 != 429))
    assert last == 429
  end

  test "GET /auth/discord/callback — 5 ok, 6. == 429", %{conn: conn} do
    statuses = for _ <- 1..6, do: get(conn, "/auth/discord/callback").status
    {ok_statuses, [last]} = Enum.split(statuses, 5)
    assert Enum.all?(ok_statuses, &(&1 != 429))
    assert last == 429
  end
end
