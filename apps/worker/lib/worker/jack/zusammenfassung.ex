defmodule Worker.Jack.Zusammenfassung do
  @moduledoc """
  Was nach einer Kompaktierung an die Stelle des weggeschnittenen Verlaufs
  tritt: ein Arbeitsstand, den die Werkzeuge aus ihren Daten schreiben, keine
  Zusammenfassung durch das Modell. Portiert aus dem Hook
  `session_before_compact` des Spikes (`werkzeuge.ts`, Stand 60aa1e84); die
  Texte sind wörtlich übernommen.

  Die Laufzeit (`Worker.Agent.Kontext`, Option `zusammenfassen:`) ruft
  `fuer/1` bei jedem Schnitt; der Text wird jedes Mal ganz neu gebaut, die
  vorige Zusammenfassung fällt weg — wie im Spike.

  Ohne diesen Rückruf bekäme Jack nach einem Schnitt nur den Vermerk
  „[Gekürzt: N ältere Nachrichten …]“: der Auftrag bliebe angeheftet, aber
  wo er steht, was im Gedächtnis ist und wie es weitergeht, wäre weg.

  **Abweichung vom Spike:** das Journal `zusammenfassung.txt` trägt keine
  Tokenzahl vor dem Schnitt (die Laufzeit gibt sie dem Rückruf nicht mit;
  sie steht im Protokoll-Ereignis `kompaktierung`) und keinen Zeitstempel,
  wie das übrige Journal des Ports.
  """

  alias Worker.Agent.Kontext
  alias Worker.Jack.{Gedaechtnis, Halter, Stand}

  @auftrag [
    "Du sammelst aus einem Gespraechsmitschnitt die Aussagen ueber die besprochene",
    "Welt — einzeln, belegt, in der Reihenfolge, in der sie fallen. Jede Aussage",
    "traegt zehn Pflichtfelder und nennt in `source_refs` die Bloecke, aus denen sie",
    "stammt, sowie in `beleg` den Wortlaut von dort. Der `beleg` wird gegen den",
    "echten Blocktext geprueft: schreib ihn nie aus der Erinnerung."
  ]

  @doc """
  Der Rückruf für `kontext: [zusammenfassen: …]` eines Laufs mit diesem
  Halter. Er baut den Text aus dem aktuellen Stand und schreibt ihn ins
  Journal. Scheitert das, fällt er auf `Kontext.standard_zusammenfassung/1`
  zurück — ein Schnitt ohne Text würde den Lauf abbrechen.
  """
  @spec fuer(pid()) :: (map() -> String.t())
  def fuer(halter) do
    fn %{weggefallen: weg} = arg ->
      ergebnis =
        Halter.aufrufen(
          halter,
          fn s, _ ->
            t = text(s)

            eintrag = %{
              "phase" => s.phase,
              "durchgang" => s.durchgang,
              "weggefallen" => length(weg),
              "text" => t
            }

            {Stand.journal(s, "zusammenfassung.txt", eintrag), t}
          end,
          %{}
        )

      if is_binary(ergebnis), do: ergebnis, else: Kontext.standard_zusammenfassung(arg)
    end
  end

  @doc "Der Arbeitsstand als Text."
  @spec text(Stand.t()) :: String.t()
  def text(%Stand{} = s) do
    notizen = String.trim(Gedaechtnis.notizen_text(s))

    Enum.join(
      [
        "# Stand deiner Arbeit (von deinen Werkzeugen geschrieben, nicht zusammengefasst)",
        "",
        "## Auftrag"
      ] ++
        @auftrag ++
        [
          "",
          "## Wo du stehst",
          Gedaechtnis.stand_text(s),
          "",
          "## Dein Gedaechtnis",
          if(notizen == "", do: "(noch keine Notizen)", else: notizen),
          "",
          "## Naechster Schritt",
          naechster_schritt(s)
        ],
      "\n"
    )
  end

  defp naechster_schritt(%Stand{phase: 1, beppo: true}) do
    "Du bist im ERSTEN von zwei Auftraegen: lesen und das Gedaechtnis " <>
      "anlegen. aussage() gibt es hier nicht. Ruf weiter() und mach dort " <>
      "weiter, wo du warst — und schreib dabei ins Gedaechtnis. Faengst du " <>
      "jetzt am Anfang neu an, verlierst du alles, was du schon gelesen hast."
  end

  defp naechster_schritt(%Stand{phase: 1} = s) do
    ab = if s.gelesen == [], do: 0, else: (s.gelesen |> Enum.map(&elem(&1, 1)) |> Enum.max()) + 1

    "Du bist im ERSTEN von zwei Auftraegen: lesen und das Gedaechtnis " <>
      "anlegen. aussage() gibt es hier nicht. Lies weiter ab " <>
      "Block #{ab} und schreib dabei weiter ins Gedaechtnis. Faengst du jetzt am Anfang " <>
      "neu an, verlierst du alles, was du schon gelesen hast."
  end

  defp naechster_schritt(%Stand{} = s) do
    gesammelt = Gedaechtnis.bis_wohin_gesammelt(s)

    cond do
      gesammelt < s.max_block and s.beppo ->
        "Du bist NICHT fertig. Mach genau da weiter, wo du warst: ruf " <>
          "weiter(), arbeite den Abschnitt ab, ruf wieder weiter() — bis das " <>
          "Werkzeug sagt, dass nichts mehr kommt. Das Gedaechtnis oben sagt dir, " <>
          "wer wer ist. Fang nicht von vorn an."

      gesammelt < s.max_block ->
        "Du bist NICHT fertig: beim Sammeln bist du bis Block #{gesammelt}" <>
          " von #{s.max_block} gekommen. Arbeite weiter, Bereich fuer Bereich: " <>
          "bloecke(von, bis) ab Block #{gesammelt + 1}, dann die Aussagen " <>
          "aus diesem Bereich eintragen, dann der naechste. Das Gedaechtnis oben " <>
          "sagt dir, wer wer ist; den Wortlaut nimmst du aus dem Bereich, den du " <>
          "gerade vor dir hast. Nicht jeder Block traegt eine Aussage — dass ein " <>
          "Bereich wenig hergibt, ist normal und kein Grund aufzuhoeren."

      true ->
        "Du bist beim Sammeln bis zum letzten Block gekommen. Pruefe die offenen " <>
          "Punkte in deinem Gedaechtnis und schliesse dann mit der Abschlussmeldung ab."
    end
  end
end
