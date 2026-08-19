defmodule Worker.Timeline.Vorlauf do
  @moduledoc """
  Issue #1069 (Etappe E5): sucht Zeitanker im geglätteten Transkript —
  deterministisch, ohne LLM, in Millisekunden und bei jedem Lauf identisch.

  ## Wozu

  Die Handlung läuft über Sessiongrenzen hinweg weiter; es ist eine
  **Kampagnen-Uhr**, keine Session-Uhr. Sprünge werden am Tisch angesagt („es
  vergehen zwei Tage"), und wo nichts angesagt wird, läuft die Zeit weiter.
  Bislang wird kein einziger dieser Hinweise genutzt: gemessen an
  `free-seattle-bereinigt` trugen 13 von 416 Fakten ein Datum.

  Dabei stehen die Belege im Text. Dieses Modul findet sie.

  ## Drei Stufen, klare Rangordnung

      1 hart              „24. Dezember 2011", „2070", „es dämmert"
                          steht wörtlich da, eindeutig  →  bindend

      2 weich belegt      „Guten Abend", „bei Dunkelheit"
                          steht wörtlich da, mehrdeutig →  verengt, überstimmt
                                                           NIE Stufe 1

      3 weich erschlossen Club → abends, Party → abends
                          steht NICHT da, ist Alltagswissen

  **Stufe 3 ist per Default AUS** (`vorlauf_erschlossene_anker`). Sie ist die
  einzige ohne Textbeleg, die einzige mit genrespezifischer Wissensbasis und
  die einzige, die Autorität ohne Fundstelle erzeugt — in Konzern-Seattle mit
  Schichtbetrieb kann ein Club auch mittags offen sein.

  ## Härte ist keine reine Formfrage

  Ein formal harter Anker aus einem Block mit `asr_unsicher`, `hat_luecke` oder
  `konfidenz: "niedrig"` wird auf **weich** degradiert. Der Anlass ist ein
  realer Fall: Block 37 in `seattle-bereinigt-1` liest „um 20.10 Uhr" — gemeint
  ist die Jahreszahl **2010** (im selben Satz folgen „Ende 2011" und „24.
  Dezember 2011"). Syntaktisch ein perfekter Uhrzeit-Anker, inhaltlich ein
  ASR-Bruch, und der Block trug das Warnsignal bereits.

  Gemessen an S1: **sechs von neun** harten Ankern fallen so heraus. Ohne die
  Regel hätte einer davon die ganze Session auf „ein Abend um 20:10"
  festgenagelt. Ziffern sind die anfälligste ASR-Klasse, und Zeitangaben
  bestehen fast nur daraus.

  Fehlt die Konfidenz-Angabe ganz (Aufnahmen vor #376/#381), gilt der Block
  ebenfalls als degradiert — fehlende Flags sehen im Code aus wie „alles in
  Ordnung", und das ist die gefährliche Richtung.

  ## Widerspruch verwirft, Übereinstimmung verengt

  „Guten Morgen, und falls wir uns nicht mehr sehen, guten Tag, guten Abend und
  gute Nacht" enthält vier weiche Anker für vier Tageszeiten. Nur der erste ist
  eine Aussage über jetzt. Irrealis, Verneinung und Zitat auf ASR-verstümmeltem
  Tischdeutsch zuverlässig zu erkennen ist schwer — die billige Regel fängt
  denselben Fall:

  **Widersprechen sich weiche Anker im selben Fenster, werden ALLE verworfen.**
  Null Anker sind besser als ein falscher. Umgekehrt VERENGEN mehrfach
  übereinstimmende: in S1 steht „Guten Abend" dreimal in den Blöcken 591, 592
  und 594.

  Das Fenster ist **±5 Blöcke**, und die Zahl ist gemessen, nicht geraten:
  zusammengehörige weiche Anker liegen 1–3 Blöcke auseinander, der nächste
  unabhängige 93 Blöcke entfernt. Ein sessionweites Fenster würde jede
  legitime Tageszeit-Progression als Widerspruch werten.

  ## Was dieses Modul NICHT tut

  Es deutet nicht. Es liefert **Fundstellen** mit Position, Härte und Wortlaut
  — die Bedeutung ergibt sich später. Diese Trennung ist der Grund, warum die
  Übergabe an das Modell Zitate schickt und keine Befunde (s. #1069,
  „Prompt-Übergabe: Zeiger, nicht Befund"): ein Modell widerspricht einer
  Werkzeugausgabe so gut wie nie, und sobald das Werkzeug interpretiert, wird
  es zur Fehlerquelle **mit Autorität**.
  """

  @typedoc """
  Eine Fundstelle. `block_index` ist die Position im geglätteten Transkript,
  `wortlaut` der tatsächlich getroffene Text — nicht seine Deutung.
  """
  @type fund :: %{
          block_index: non_neg_integer(),
          block_id: String.t(),
          haerte: :hart | :weich,
          art: atom(),
          wortlaut: String.t(),
          degradiert: boolean()
        }

  # Fenster für die Widerspruchs-/Bestätigungsregel, in Blöcken.
  @fenster 5

  # ─── Muster ──────────────────────────────────────────────────────────
  #
  # Wortgrenzen sind Pflicht. Teilstring-Suche ist auf Deutsch unbrauchbar,
  # dreimal gemessen (#1069): „Nacht" trifft Nachteil und Nachtentzug (4 von 6
  # Treffern Müll), „Gang" trifft VerGANGenheit (10 von 14), „heiss" trifft
  # heisst, „dunkel" trifft Dunkelzahn — einen Drachennamen.

  @harte [
    {:uhrzeit, ~r/\b\d{1,2}[:.]\d{2}\s*uhr\b/iu},
    # Das Jahr gehört ins Muster, nicht daneben: „24. Dezember 2011" ist EIN
    # Anker. Ohne das optionale Jahr endet der Datums-Treffer vor der
    # Jahreszahl, das Jahr-Muster greift zusätzlich, und ein Block trüge zwei
    # Anker statt einem.
    {:datum,
     ~r/\b\d{1,2}\.\s*(januar|februar|märz|april|mai|juni|juli|august|september|oktober|november|dezember)(\s+\d{2,4})?\b/iu},
    {:jahr, ~r/\b(19|20|21)\d{2}\b/u},
    {:tagesgrenze, ~r/\b(es\s+dämmert|sonnenaufgang|sonnenuntergang|morgengrauen)\b/iu}
  ]

  @weiche [
    {:gruss, ~r/\b(guten\s+morgen|guten\s+tag|guten\s+abend|gute\s+nacht)\b/iu},
    {:tageszeit, ~r/\b(morgens|vormittags|mittags|nachmittags|abends|nachts)\b/iu},
    {:licht, ~r/\b(bei\s+dunkelheit|im\s+dunkeln|stockdunkel)\b/iu}
  ]

  # Wörter, die ein Muster fälschlich auslösen würden. Werden VOR der Suche
  # entfernt — nicht danach gefiltert, sonst müsste jede Regel ihre eigene
  # Ausnahmeliste führen.
  @negativliste ~r/\b(nachteil\w*|nachtentzug\w*|vergangen\w*|heisst|heißt|dunkelzahn\w*|gangart\w*)\b/iu

  @doc """
  Sucht Anker in geglätteten Blöcken. Liefert die Fundstellen in
  Transkript-Reihenfolge.

  `blocks` sind die Roh-Blöcke aus dem Smoothing-Snapshot (mit `"text"`,
  `"id"`, `"asr_unsicher"`, `"hat_luecke"`, `"konfidenz"`).
  """
  @spec finde([map()]) :: [fund()]
  def finde(blocks) when is_list(blocks) do
    blocks
    |> Enum.with_index()
    |> Enum.flat_map(fn {b, i} -> funde_im_block(b, i) end)
  end

  defp funde_im_block(b, index) do
    text = b["text"] || ""
    sauber = String.replace(text, @negativliste, " ")
    degradiert = degradiert?(b)

    harte =
      for {art, re} <- @harte, {von, laenge} <- treffer_stelle(re, sauber) do
        %{
          block_index: index,
          block_id: b["id"],
          # Ein unsicherer Block trägt keinen harten Anker — s. Moduldoc.
          haerte: if(degradiert, do: :weich, else: :hart),
          art: art,
          wortlaut: binary_part(sauber, von, laenge),
          degradiert: degradiert,
          stelle: {von, laenge}
        }
      end

    weiche =
      for {art, re} <- @weiche, {von, laenge} <- treffer_stelle(re, sauber) do
        %{
          block_index: index,
          block_id: b["id"],
          haerte: :weich,
          art: art,
          wortlaut: binary_part(sauber, von, laenge),
          degradiert: degradiert,
          stelle: {von, laenge}
        }
      end

    (entschachtele(harte) ++ entschachtele(weiche))
    |> Enum.map(&Map.delete(&1, :stelle))
  end

  defp treffer_stelle(re, text) do
    case Regex.run(re, text, return: :index) do
      [stelle | _] -> [stelle]
      nil -> []
    end
  end

  # „Am 24. Dezember 2011" trifft ZWEI Muster: das Datum und das Jahr darin.
  # Das ist EIN Anker, nicht zwei — eine Doppelzählung würde die
  # Ankerstatistik verfälschen, an der die Bau-Entscheidung hängt.
  #
  # Der umfassendere Treffer gewinnt: er trägt mehr Information (Tag und Monat
  # zusätzlich zum Jahr). Getrennte Angaben im selben Block überlappen nicht
  # und bleiben beide erhalten.
  defp entschachtele(funde) do
    sortiert = Enum.sort_by(funde, fn %{stelle: {_, len}} -> -len end)

    Enum.reduce(sortiert, [], fn fund, behalten ->
      if Enum.any?(behalten, &enthaelt?(&1.stelle, fund.stelle)),
        do: behalten,
        else: behalten ++ [fund]
    end)
    |> Enum.sort_by(fn %{stelle: {von, _}} -> von end)
  end

  defp enthaelt?({a_von, a_len}, {b_von, b_len}) do
    b_von >= a_von and b_von + b_len <= a_von + a_len
  end

  @doc """
  Issue #1069 (D8/D9/D11): trägt dieser Block einen verlässlichen Anker?

  `false` heisst nicht „unbrauchbar", sondern „nicht bindend" — der Fund wird
  auf weich degradiert und zählt nur noch als Hinweis.

  **Fehlende Angaben zählen als unsicher.** Ein Block ohne Konfidenzfelder
  (Aufnahmen vor #376/#381) sieht im Code aus wie ein einwandfreier — das ist
  die Richtung, in der ein Fehler teuer wird.
  """
  @spec degradiert?(map()) :: boolean()
  def degradiert?(b) when is_map(b) do
    b["asr_unsicher"] == true or b["hat_luecke"] == true or
      b["konfidenz"] in ["niedrig", nil]
  end

  def degradiert?(_), do: true

  @doc """
  Wendet die Widerspruchsregel an: weiche Anker DERSELBEN Art im Fenster
  bestätigen einander, weiche Anker VERSCHIEDENER Tageszeit-Art widersprechen
  sich und werden samt ihres Fensters verworfen.

  Harte Anker bleiben unberührt — sie sind eindeutig und stehen nicht zur
  Abstimmung.
  """
  @spec bereinige([fund()]) :: [fund()]
  def bereinige(funde) when is_list(funde) do
    {harte, weiche} = Enum.split_with(funde, &(&1.haerte == :hart))

    # Nur Tageszeit-tragende Arten können sich widersprechen. „bei Dunkelheit"
    # und „Guten Abend" sind verträglich; „Guten Morgen" und „gute Nacht" nicht.
    widersprochen =
      for a <- weiche,
          b <- weiche,
          a.block_index < b.block_index,
          b.block_index - a.block_index <= @fenster,
          widerspruch?(a, b),
          into: MapSet.new(),
          do: a.block_index

    ganz_verworfen =
      for a <- weiche,
          b <- weiche,
          a.block_index < b.block_index,
          b.block_index - a.block_index <= @fenster,
          widerspruch?(a, b),
          reduce: widersprochen do
        acc -> MapSet.put(acc, b.block_index)
      end

    harte ++ Enum.reject(weiche, &MapSet.member?(ganz_verworfen, &1.block_index))
  end

  # Zwei Grussformeln/Tageszeiten, die verschiedene Tageszeiten meinen.
  defp widerspruch?(a, b) do
    a.art in [:gruss, :tageszeit] and b.art in [:gruss, :tageszeit] and
      tageszeit(a.wortlaut) != nil and tageszeit(b.wortlaut) != nil and
      tageszeit(a.wortlaut) != tageszeit(b.wortlaut)
  end

  defp tageszeit(wortlaut) do
    w = String.downcase(wortlaut)

    cond do
      String.contains?(w, "morgen") -> :morgen
      String.contains?(w, "vormittag") -> :morgen
      String.contains?(w, "mittag") -> :mittag
      String.contains?(w, "nachmittag") -> :nachmittag
      String.contains?(w, "abend") -> :abend
      String.contains?(w, "nacht") -> :nacht
      String.contains?(w, "tag") -> :tag
      true -> nil
    end
  end

  @doc """
  Bestätigte Paare: zwei weiche Anker derselben Tageszeit im Fenster. Sie sind
  das Signal, dem man trauen kann — ein einzelner Gruss kann ein Zitat sein,
  drei in drei Blöcken sind eine Szene.
  """
  @spec bestaetigte_paare([fund()]) :: [{fund(), fund()}]
  def bestaetigte_paare(funde) when is_list(funde) do
    weiche = Enum.filter(funde, &(&1.haerte == :weich))

    for a <- weiche,
        b <- weiche,
        a.block_index < b.block_index,
        b.block_index - a.block_index <= @fenster,
        tageszeit(a.wortlaut) != nil,
        tageszeit(a.wortlaut) == tageszeit(b.wortlaut),
        do: {a, b}
  end

  @doc "Fenstergrösse in Blöcken — gemessen, nicht geraten (s. Moduldoc)."
  @spec fenster() :: pos_integer()
  def fenster, do: @fenster
end
