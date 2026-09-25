defmodule Worker.Timeline.VorlaufUeberholtTest do
  @moduledoc """
  #1247: **eine Uhrzeit darf die Linie nicht 69 Jahre zurückwerfen.**

  Gefunden am Lauf vom 25.09.2026 (seattleV5). Der einzige taggenaue Anker der
  Kampagne ist „am 24. Dezember 2011" — alle anderen sind Jahresangaben und
  damit zu grob, um einen Tag zu vererben (`taggenau?/1`, und das ist richtig:
  aus „2080" einen 1. Januar zu machen war der #1092-Fehler).

  Die Lücke lag daneben: Es wurde nicht geprüft, ob der taggenaue Punkt
  **inzwischen überholt** ist. Also holte jede Uhrzeit ihren Tag von Ryumyo am
  Mount Fuji — auch „nachts um halb zwei" in Sitzung 4. Die Reihenfolge war
  korrekt, die Zeit lief trotzdem rückwärts.

  Jack hat es gefunden und richtig entschieden, nichts zu erfinden: „If I
  change it to 2079 or 2080, that's inventing a date that wasn't stated."
  """
  use ExUnit.Case, async: true

  alias Worker.Timeline.{Ausdruck, Calendar, Linie}

  @tag_minuten 1440

  defp stelle(i), do: %{utterance_id: "u#{i}", session_nr: 1, pos: i}
  defp stellen(n), do: Enum.map(1..n, &stelle/1)

  # **Aufgelöst, nicht roh** — `Linie.bauen/2` erwartet Anker, die schon durch
  # `Ausdruck.aufloesen/2` gelaufen sind (so kommen sie aus
  # `Repo.Zeit.anker/1`). Der erste Anlauf übergab rohe: Dann trägt keiner eine
  # Minute, es gibt gar keine festen Punkte, und der Test prüft eine Linie, die
  # es nicht gibt (drei Fehlschläge, alle irreführend).
  defp anker(i, wert, art \\ :zeitpunkt) do
    %{
      anker_id: "z_#{i}",
      utterance_ids: ["u#{i}"],
      art: art,
      wert: wert,
      welt: "spielwelt",
      beleg: "…",
      zweifel: "",
      quelle: "jack"
    }
    |> Ausdruck.aufloesen(Calendar.default())
  end

  defp linie(anker, n \\ 30), do: Linie.bauen(stellen(n), anker)
  defp minute(l, i), do: l.nach_utterance["u#{i}"][:minute]
  defp herkunft(l, i), do: to_string(l.nach_utterance["u#{i}"][:herkunft])
  defp tag(l, i), do: minute(l, i) && Integer.floor_div(minute(l, i), @tag_minuten)

  describe "der echte Fall" do
    test "eine Uhrzeit nach einem Jahres-Anker landet NICHT im alten Tag" do
      # 1: taggenau 2011 · 10: Jahr 2080 (zu grob für einen Tag) · 20: Uhrzeit
      l = linie([anker(1, "am 24. Dezember 2011"), anker(10, "2080"), anker(20, "01:30")])

      assert herkunft(l, 1) == "belegt"
      assert herkunft(l, 10) == "belegt"

      refute tag(l, 20) == tag(l, 1),
             "die Uhrzeit darf nicht den Tag von 2011 bekommen — das war der Defekt"
    end

    @tag :offen
    test "OFFEN: die Linie läuft weiterhin rückwärts, nur anders" do
      # **Halbe Wegstrecke, und das steht hier statt in einer grünen Fassade.**
      #
      # `vorlauf/2` nimmt den überholten Tag nicht mehr — damit ist der falsche
      # 24.12.2011 weg. Ohne Tagesbasis fällt die Uhrzeit aber auf die relative
      # Rechnung (`absolute_minute(_, zahl, nil)` → Tag 0), und Tag 0 liegt vor
      # 2080: Die Linie läuft weiter rückwärts, jetzt ins Jahr 0 statt 2011.
      #
      # Die Gegenrichtung zu reparieren bricht eine ANDERE, bewusst getestete
      # Regel (19.09.2026, Maintainer-Fall): „Die Spielleitung erzählt
      # Vergangenheit — ‚seit dem Beben 2044' —, und gleich danach fällt eine
      # Uhrzeit der Gegenwart." Dort MUSS die Uhrzeit relativ bleiben, sonst
      # spielt die Sitzung 2044.
      #
      # Beide Fälle sind echt, und die Regeln widersprechen sich:
      #
      #     Uhrzeit nach grobem Anker, KEIN späterer Punkt   → relativ (2044-Fall)
      #     Uhrzeit nach grobem Anker, späterer Punkt davor  → ?        (seattleV5)
      #
      # Drei Auswege, alle mit Preis: den letzten Tag erben (erfindet einen
      # Tag), relativ bleiben (läuft rückwärts), oder gar keine Minute setzen
      # (verliert die Uhrzeit für Abstände). Die Entscheidung gehört dem
      # Maintainer; bis dahin ist der Zustand hier festgehalten, nicht
      # weggeschrieben.
      l = linie([anker(1, "am 24. Dezember 2011"), anker(10, "2080"), anker(20, "01:30")])

      assert minute(l, 20) < minute(l, 10),
             "noch nicht behoben — wenn dieser Test rot wird, ist die Entscheidung gefallen"
    end

    test "aber der falsche Tag aus 2011 ist weg" do
      # Das ist der Teil, der trägt: Der überholte taggenaue Anker gibt seinen
      # Tag nicht mehr her. Vorher stand hier Tag 734372 (24.12.2011).
      l = linie([anker(1, "am 24. Dezember 2011"), anker(10, "2080"), anker(20, "01:30")])

      refute tag(l, 20) == tag(l, 1)
      assert tag(l, 20) == 0, "ohne Tagesbasis ist die Uhrzeit relativ (Tag 0)"
    end
  end

  describe "was der Fix NICHT wegnimmt" do
    test "ohne überholenden Punkt vererbt der taggenaue Anker weiter" do
      # Der Normalfall: ein Datum, danach Uhrzeiten am selben Tag.
      l = linie([anker(1, "am 24. Dezember 2011"), anker(5, "01:30")])

      assert tag(l, 5) == tag(l, 1), "am selben Tag muss der Tag erben"
      assert herkunft(l, 5) == "belegt"
    end

    test "zwei Uhrzeiten nach demselben Datum bleiben beide am Tag" do
      l = linie([anker(1, "am 24. Dezember 2011"), anker(5, "10:00"), anker(9, "14:00")])

      assert tag(l, 5) == tag(l, 1)
      assert tag(l, 9) == tag(l, 1)
      assert minute(l, 9) > minute(l, 5)
    end

    test "ein SPÄTERER taggenauer Anker gewinnt gegen einen früheren" do
      # „Überholt" darf nicht heissen „irgendein späterer Punkt" — ein
      # taggenauer Punkt danach ist der bessere Tagesgeber, nicht ein Hindernis.
      l =
        linie([
          anker(1, "am 24. Dezember 2011"),
          anker(10, "am 3. März 2080"),
          anker(20, "01:30")
        ])

      assert tag(l, 20) == tag(l, 10), "der Tag kommt vom jüngeren Datum"
      assert herkunft(l, 20) == "belegt"
    end

    test "eine Linie ganz ohne Datum bleibt relativ" do
      # Ohne Datums-Anker zählen die Abstände; das war schon so und bleibt.
      l = linie([anker(3, "10:00"), anker(7, "14:00")])

      assert is_integer(minute(l, 3))
      assert minute(l, 7) - minute(l, 3) == 4 * 60
    end
  end

  describe "die Herkunft, zweiter Teil der offenen Frage" do
    @tag :offen
    test "OFFEN: die Uhrzeit heisst weiterhin belegt, obwohl ihr Tag geraten ist" do
      # Der zweite Halbsatz von Jacks Befund, und er hängt an derselben
      # Entscheidung: `verankern/2` schreibt jede Uhrzeit als festen Punkt
      # (`punkt(a, minute, true, …)`), also `:belegt` — auch wenn nur die
      # Tageszeit belegt ist und der Tag aus dem Vorlauf kommt oder fehlt.
      #
      # Genau daran ist Jack gescheitert: Er liest „belegt" als Aussage der
      # Daten und versucht, sie zu korrigieren — „If I remove it, I lose the
      # date. If I change it to 2079 or 2080, that's inventing." Ein Name wie
      # „Uhrzeit belegt, Tag unbekannt" hätte ihm die Sackgasse erspart.
      l = linie([anker(1, "am 24. Dezember 2011"), anker(10, "2080"), anker(20, "01:30")])

      assert herkunft(l, 20) == "belegt",
             "noch nicht behoben — wird dieser Test rot, ist die Herkunft differenziert"
    end
  end
end
