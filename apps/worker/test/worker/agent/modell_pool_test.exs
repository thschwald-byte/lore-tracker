defmodule Worker.Agent.Modell.PoolTest do
  @moduledoc """
  #1247: der Modell-Pool ist verdrahtet **und** wird benutzt.

  Beides einzeln ist wirkungslos, und beides scheitert still: Ein Pool, den
  niemand nennt, läuft leer mit (Reqs Default-Pool bedient dann weiter die
  Aufrufe, ohne Frist), und ein `finch:`-Eintrag auf einen Pool, der nicht im
  Baum steht, wirft erst beim ersten echten Aufruf — also im Lauf, nicht im
  Test. Deshalb Quelltext-Wächter für die Verdrahtung: Die Wirkung ist ein
  Verbindungszustand, den kein Test hier herstellen kann.
  """
  use ExUnit.Case, async: true

  alias Worker.Agent.Modell.Pool

  test "der Pool läuft — nicht nur im Quelltext" do
    # Stärker als ein Quelltext-Wächter, und hier möglich: Der Pool steht VOR
    # dem Pairing-Gate, läuft also auch in der Testumgebung. Beim ersten
    # Anlauf stand er im gepaarten Zweig, und drei Tests mit echten
    # HTTP-Aufrufen fielen mit `unknown registry` um.
    assert Process.whereis(Pool.name()),
           "der Pool muss im Baum stehen, und zwar vor dem Pairing-Gate"
  end

  test "und JEDER Aufruf des Ollama-Clients nennt ihn" do
    # **Eine** Aufrufstelle, seit der Client immer streamt (#1247: der
    # nicht gestreamte Pfad `ganz/3` ist entfallen, weil die
    # Schleifen-Erkennung den Strom braucht und nicht daran hängen darf, ob
    # ein Beobachter zusieht). Vorher waren es zwei — und die eine, die den
    # Pool vergisst, läuft still über den Default-Pool, genau der Zustand, der
    # behoben werden sollte.
    quelle = File.read!("lib/worker/agent/modell/ollama.ex")

    posts = quelle |> String.split("|> Req.post(") |> tl()
    assert length(posts) == 1, "die Zahl der Aufrufstellen hat sich geändert — Wächter prüfen"

    for {abschnitt, i} <- Enum.with_index(posts, 1) do
      kopf = String.slice(abschnitt, 0, 400)

      assert kopf =~ "finch: Worker.Agent.Modell.Pool.name()",
             "Aufrufstelle #{i} nennt den Pool nicht"
    end
  end

  test "die Frist ist gesetzt und liegt über der Dauer eines Werkzeugschritts" do
    # Zwischen zwei Werkzeugaufrufen liegt die Antwortzeit des Modells —
    # Sekunden. Läge die Frist darunter, baute jeder Schritt die Verbindung
    # neu auf.
    assert Pool.idle_ms() >= 10_000

    {Finch, opts} = Pool.kind()
    assert opts[:name] == Pool.name()
    assert get_in(opts, [:pools, :default])[:pool_max_idle_time] == Pool.idle_ms()
  end
end
