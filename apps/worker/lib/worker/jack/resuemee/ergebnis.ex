defmodule Worker.Jack.Resuemee.Ergebnis do
  @moduledoc """
  Was aus dem Schreiben des Resümee-Jack herauskommt (J5, #1209, B2), pur
  und in der Pipeline genutzt (B4, `Worker.Jack.Resuemee.Pipeline`): das Resümee als Markdown
  (`markdown/1`), die Quellen je Satz (`satzquellen/1`) und die Zählwerte
  für die Auswertung (`zaehlwerte/1`).

  Alle drei arbeiten auf dem Entwurf des Stands, den sie bekommen: auf dem
  Stand der Durchsicht (B3) ist das der Entwurf nach der Durchsicht, und
  `zaehlwerte/1` trägt dann zusätzlich `durchsicht`
  (`Worker.Jack.Resuemee.Durchsicht.zaehlwerte/1`).

  **Ein Absatztitel wird eine fette Zeile `**Titel**`, keine Überschrift
  `###`.** Drei Gründe:

    * Es ist die Form, die das Resümee bis B4 hatte — der frühere
      Render-Prompt (`Worker.Recording.Pipeline.Prompts.build_summary_render_prompt/2`,
      #909) verlangte je Bogen „die fette Bogen-Überschrift“. Die Spalte sieht
      mit Jacks Resümee aus wie vorher.
    * Die Spalte hat ihre eigene Überschriften-Ordnung (Spaltentitel, je
      Sitzung ein Kopf); eine Markdown-Überschrift im Resümee stünde darin
      auf gleicher oder höherer Stufe als der Sitzungskopf.
    * Beides übersteht `render_md_safe/1` (Earmark mit `escape: true`, dann
      `HtmlSanitizeEx.basic_html/1`, das `strong` wie `h1`–`h6` durchlässt).

  Der Titel steht auf eigener Zeile direkt vor dem Text. Earmark läuft ohne
  `breaks: true`, dort erscheint er deshalb als fetter Vorspann des Absatzes
  — genau wie die fetten Bogen-Zeilen heute. Absätze trennt eine Leerzeile,
  Sätze ein Leerzeichen.

  **Zwei Schutzmaßnahmen am Markdown:** im Titel werden `*`, `_`, `` ` ``,
  `[` und `]` maskiert (sonst bräche ein Sternchen im Titel den Fettdruck),
  und ein Absatz, der wie ein Markdown-Block beginnt (`#`, `>`, `- `, `+ `,
  `* `, `3. `), bekommt einen Backslash davor — ein Satz, der mit „3. Mai“
  beginnt, würde sonst eine nummerierte Liste. Sonst geht Jacks Text
  unverändert durch; Hervorhebungen mit Sternchen bleiben seine Sache.
  """

  alias Worker.Jack.Resuemee.{Durchsicht, Entwurf, Stand, Weg}

  @doc "Das Resümee als Markdown, siehe Moduldoc."
  @spec markdown(Stand.t()) :: String.t()
  def markdown(%Stand{entwurf: e}), do: Enum.map_join(e, "\n\n", &absatz_md/1)

  defp absatz_md(%{titel: titel, saetze: saetze}) do
    text = saetze |> Enum.map_join(" ", & &1.text) |> anfang_schuetzen()

    case titel do
      nil -> text
      t -> "**" <> titel_md(t) <> "**\n" <> text
    end
  end

  defp titel_md(t), do: String.replace(t, ~r/([\\*_`\[\]])/, "\\\\\\1")

  defp anfang_schuetzen(text) do
    cond do
      Regex.match?(~r/^\d+[.)]\s/, text) -> Regex.replace(~r/^(\d+)([.)])/, text, "\\1\\\\\\2")
      Regex.match?(~r/^(#|>|[-+*]\s)/, text) -> "\\" <> text
      true -> text
    end
  end

  @doc """
  Je Satz des Entwurfs: `%{absatz:, satz:, text:, fakten:, fakt_ids:,
  uebergang:, rueckblick:}`. `absatz` und `satz` zählen ab 1 wie in
  `entwurf()`, `fakten` sind die kurzen IDs, `fakt_ids` die
  inhaltsbasierten Fakt-IDs der Pipeline, auf die sie zeigen. Ein Fakt ohne
  ID im Bestand (`fakt_id: nil`) fehlt in `fakt_ids`.
  """
  @spec satzquellen(Stand.t()) :: [map()]
  def satzquellen(%Stand{} = s) do
    echt = Map.new(s.fakten ++ Enum.flat_map(s.fruehere, & &1.fakten), &{&1.id, &1.fakt_id})

    for {a, an} <- Enum.with_index(s.entwurf, 1),
        {satz, sn} <- Enum.with_index(a.saetze, 1) do
      %{
        absatz: an,
        satz: sn,
        text: satz.text,
        fakten: satz.fakten,
        fakt_ids: satz.fakten |> Enum.map(&Map.get(echt, &1)) |> Enum.reject(&is_nil/1),
        uebergang: satz.uebergang,
        rueckblick: satz.rueckblick
      }
    end
  end

  @doc """
  Die Zählwerte für die Auswertung, JSON-fähig: `absaetze`, `saetze`,
  `uebergaenge`, `rueckblicke`, `woerter` (Sätze und Titel,
  `Worker.Jack.Resuemee.Stand.woerter/1`), `max_woerter` (das Ziel, das
  galt, #1209), `obergrenze` (das Doppelte), `laenge_begruendung` (wie
  `fertig` im Schreiben sie angenommen hat, sonst `nil`),
  `gliederung_ohne_satz` (Stationen der GLIEDERUNG ohne Satz, je
  `%{"schluessel", "zeile"}`, `Worker.Jack.Resuemee.Weg.ohne_satz/1`),
  `fakten` (dieser Sitzung), `fakten_im_text`
  (davon von einem Satz genannt), dazu aus dem Journal `abgelehnte_absaetze`
  (abgelehnte Aufrufe von `absatz`/`absatz_ersetzen`), `abgelehnte_saetze`
  und `gruende` (je Code, wie oft er einen Satz oder Titel abgelehnt hat;
  ein Satz mit zwei Gründen zählt bei beiden). Auf dem Stand der Durchsicht
  zählen die abgelehnten die Ersetzungen der Durchsicht (ihr Journal beginnt
  frisch), und `durchsicht` kommt dazu.
  """
  @spec zaehlwerte(Stand.t()) :: map()
  def zaehlwerte(%Stand{durchsicht: %{}} = s),
    do: s |> schreibwerte() |> Map.put("durchsicht", Durchsicht.zaehlwerte(s))

  def zaehlwerte(%Stand{} = s), do: schreibwerte(s)

  defp schreibwerte(s) do
    z = Stand.entwurf_zahlen(s)
    datei = Entwurf.journal_datei()

    abgelehnt =
      for {^datei, %{"art" => "abgelehnt"} = e} <- Stand.journal_liste(s), do: e

    saetze = Enum.flat_map(abgelehnt, & &1["saetze"])

    %{
      "absaetze" => z.absaetze,
      "saetze" => z.saetze,
      "uebergaenge" => z.uebergaenge,
      "rueckblicke" => z.rueckblicke,
      "woerter" => z.woerter,
      "max_woerter" => s.max_woerter,
      "obergrenze" => Stand.obergrenze(s),
      "laenge_begruendung" => s.laenge_begruendung,
      "gliederung_ohne_satz" => Weg.abbild(Weg.ohne_satz(s)),
      "fakten" => length(s.fakten),
      "fakten_im_text" => MapSet.size(Stand.im_text(s)),
      "abgelehnte_absaetze" => length(abgelehnt),
      "abgelehnte_saetze" => length(saetze),
      "gruende" =>
        Enum.frequencies(
          Enum.flat_map(saetze, & &1["gruende"]) ++
            Enum.flat_map(abgelehnt, & &1["titel_gruende"])
        )
    }
  end
end
