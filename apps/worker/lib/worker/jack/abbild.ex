defmodule Worker.Jack.Abbild do
  @moduledoc """
  Der Stand eines Jack-Laufs als Daten: für die lokale Laufsicht (#1202) und
  als Dateien im Laufverzeichnis.

  Die Dateien tragen die Namen des Spikes, damit dessen Auswertungen
  weiterlaufen: `aussagen.jsonl` (der Bestand, eine Aussage je Zeile, mit den
  internen Feldern `_iter`, `_pos`, `_verworfen` …), `notizen.txt` (das
  Gedächtnis als Text) und das Journal (`abgelehnt.jsonl`, `dubletten.jsonl`,
  `notizen_verlauf.txt`, `abschluss.jsonl`, `beppo.jsonl`, …), dazu
  `stand.json` mit allem, was die Seite zeigt. Auch `.txt`-Dateien des
  Journals enthalten eine JSON-Zeile je Eintrag; im Spike waren sie Text.

  Geschrieben wird daneben und dann umbenannt (wie `werkzeuge.ts:411`): wer
  liest, sieht nie eine halbe Datei. Die Ablage enthält den Mitschnitt der
  echten Runde und gehört außerhalb des öffentlichen Repos.
  """

  alias Worker.Jack.{Abschluss, Gedaechtnis, Ordnung, Stand}

  @doc "Der Stand als JSON-fähige Map."
  @spec von(Stand.t()) :: map()
  def von(%Stand{} = s) do
    %{
      "phase" => s.phase,
      "rolle" => s.ordnung.rolle,
      "runde" => s.ordnung.runde,
      "durchgang" => s.durchgang,
      "beppo" => s.beppo,
      "beppo_pos" => s.beppo_pos,
      "max_block" => s.max_block,
      "bestand" => s.lfd,
      "abgelehnt" => s.abgelehnt,
      "geraten" => s.geraten,
      "gelesen" => Enum.map(s.gelesen, &Tuple.to_list/1),
      "gesammelt_bis" => Gedaechtnis.bis_wohin_gesammelt(s),
      "hindernisse" => hindernisse(s),
      "geruest_fehlt" => Stand.geruest_fehlt(s),
      "ablauf_luecken" => Gedaechtnis.ablauf_luecken(s),
      "stand_text" => Gedaechtnis.stand_text(s),
      "notizen" => Gedaechtnis.notizen_text(s),
      "register" => s.register,
      "themen" => s.themen,
      "kollisionen" => Map.new(s.kollisionen, fn {nr, n} -> {to_string(nr), n} end),
      "journal" => s |> Stand.journal_liste() |> Enum.frequencies_by(&elem(&1, 0)),
      "aussagen" => Enum.map(s.eingetragen, & &1.voll),
      "ordnung" => ordnung(s)
    }
  end

  # Phase 3: der Verlauf (die letzten 14 Schritte, samt Zahl je Art) und die
  # offene Arbeit — was die Seite als Redaktion zeigt.
  defp ordnung(%Stand{phase: 3} = s) do
    %{
      "verlauf_n" => Enum.frequencies_by(s.ordnung.verlauf, & &1["was"]),
      "verlauf" => Enum.take(s.ordnung.verlauf, -14),
      "offene_arbeit" => Ordnung.offene_arbeit(s)
    }
  end

  defp ordnung(_s), do: nil

  # Was `fertig` im Moment ablehnen würde — die Seite zeigt es als offene Arbeit.
  defp hindernisse(s), do: Abschluss.hindernisse(s)

  @doc "Schreibt das Abbild ins Verzeichnis `dir` (wird angelegt)."
  @spec schreiben(Path.t(), Stand.t()) :: :ok
  def schreiben(dir, %Stand{} = s) do
    File.mkdir_p!(dir)
    abbild = von(s)

    atomar(dir, "stand.json", Jason.encode_to_iodata!(abbild, pretty: true))
    atomar(dir, "aussagen.jsonl", zeilen(abbild["aussagen"]))
    atomar(dir, "notizen.txt", abbild["notizen"])

    s
    |> Stand.journal_liste()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.each(fn {datei, eintraege} -> atomar(dir, datei, zeilen(eintraege)) end)
  end

  defp zeilen(liste), do: Enum.map(liste, &[Jason.encode_to_iodata!(&1), ?\n])

  defp atomar(dir, datei, inhalt) do
    ziel = Path.join(dir, datei)
    File.write!(ziel <> ".neu", inhalt)
    File.rename!(ziel <> ".neu", ziel)
  end
end
