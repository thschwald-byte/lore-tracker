defmodule Worker.LifecycleTest do
  @moduledoc """
  Issue #496: shutdown/0 muss im dedizierten Worker-BEAM den Node halten (statt
  nur die App zu stoppen → Zombie unter systemd Restart=always). Discriminator:
  läuft `:hub` im selben Node?

  Hinweis: `shutdown/0` / `graceful_halt/0` selbst werden NICHT aufgerufen — sie
  würden via `:erlang.halt/1` (#776, flush-frei) die Test-VM beenden. Getestet
  wird nur der Discriminator (die sicherheitskritische Entscheidung).
  """

  use ExUnit.Case, async: true

  test "dedicated_worker_beam? ist true ohne :hub im Node (Worker-Suite läuft ohne Hub)" do
    refute List.keymember?(Application.started_applications(), :hub, 0),
           "Vorbedingung: die Worker-Test-Suite läuft NICHT mit :hub im selben Node"

    assert Worker.Lifecycle.dedicated_worker_beam?()
  end
end
