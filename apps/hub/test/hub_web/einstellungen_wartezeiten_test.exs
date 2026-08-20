defmodule HubWeb.EinstellungenWartezeitenTest do
  @moduledoc """
  Issue #1062: der Wartezeiten-Block in `/settings` schreibt in
  `Worker.Settings`. Ein Tippfehler im Feldnamen erzeugt dabei **keinen
  Fehler**, sondern ein totes Feld: der Wert läuft durch das Formular, der
  Worker weist ihn an seiner Write-Whitelist (`@known_keys`) stumm ab, und die
  Oberfläche zeigt beim nächsten Laden wieder den alten Stand. Niemand sieht
  etwas — dieselbe Klasse wie der ausgegraute REC-Knopf aus #1090.

  **Die Existenz der Keys prüft dieser Test NICHT** — das tut
  `Worker.SettingsUiDriftTest` (#755) in der Worker-Suite, und zwar besser: er
  hat `Worker.Settings.known_keys/0` zur Hand, während der Hub keine Worker-Dep
  hat. Er wurde für diesen Block um die Auflösung von `settings[\#{key}]`
  erweitert; ohne das wäre der datengetriebene Block für ihn unlesbar gewesen
  und hätte die Prüfung stillschweigend umgangen.

  Hier bleibt, was nur diesseits sichtbar ist: die Form der Liste und das
  `_ms`-Suffix, an dem das Clamping hängt.
  """

  use ExUnit.Case, async: true

  alias HubWeb.EinstellungenLive.Wartezeiten

  test "die Keys sind eindeutig — kein Feld doppelt einsortiert" do
    keys = Wartezeiten.keys()
    assert length(keys) == length(Enum.uniq(keys))
  end

  test "jede Gruppe hat einen Titel und mindestens ein Feld" do
    for {titel, felder} <- Wartezeiten.gruppen() do
      assert is_binary(titel) and titel != ""
      assert felder != [], "Gruppe #{titel} ist leer"

      for {key, beschriftung, hilfe} <- felder do
        assert is_atom(key)
        assert is_binary(beschriftung) and beschriftung != ""
        assert is_binary(hilfe)
      end
    end
  end

  test "jeder Key endet auf _ms — sonst greift das 24-h-Clamping nicht" do
    # `HubClient.Rpc.clamp_ms/2` erkennt Wartezeiten am Suffix. Ein Key ohne
    # `_ms` käme ungeprüft durch und ein Tippfehler wie 1_200_000_000 (~13 Tage)
    # würde den Worker blockieren — real passiert, s. CLAUDE.md.
    ohne_suffix = Enum.reject(Wartezeiten.keys(), &String.ends_with?(Atom.to_string(&1), "_ms"))
    assert ohne_suffix == [], "ohne _ms-Suffix kein Clamping: #{inspect(ohne_suffix)}"
  end
end
