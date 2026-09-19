defmodule Worker.Jack.Zeit.Mitschnitt do
  @moduledoc """
  #1247 (Z2): der Mitschnitt, wie der Zeit-Jack ihn liest — **eine Zeile je
  Utterance**, nicht je Block. Pur.

  ## Warum die Utterance und nicht der Block

  Die anderen Jacks lesen Blöcke, und für sie ist das richtig: Ein Block ist
  ein Sprecher in einem Atemzug, und eine Aussage entsteht selten in der Mitte
  davon. Für die Zeit bricht das, belegt an seattleV5 S3, Block 1599 — ein
  Sprecher, ein Atemzug, **zwei Welten**:

      „Wir machen nochmal zehn Minuten mehr."      ← der Abend, am Tisch
      „Nach einer weiteren halben Stunde …"        ← die Spielwelt

  Beide liegen in eigenen Utterances (der Block hat neun). Auf Blockebene
  müsste ein Anker sich für eine Welt entscheiden und verlöre entweder echte
  Spielzeit oder holte die Küchenuhr herein. Über alle vier Sitzungen sind
  **41 %** der Blöcke mehrteilig; dort ist die Utterance echt feiner.

  Dazu kommt: Utterances sind **stabil** (sie werden nie neu erstellt), Blöcke
  entstehen bei jeder Glättung neu. Eine Adresse auf Utterance-Ebene überlebt
  ein Re-Smoothing, eine Blocknummer nicht.

  ## Der Text bleibt trotzdem der geglättete

  Die rohe Utterance trägt, was die ASR verstanden hat — mit Stottern,
  Füllwörtern und bei einer erkannten Lücke nur ein Bruchstück. Der Block
  trägt den **wirksamen** Text: geglättet, und bei einer uncurierten Lücke
  den Gap-Fill-Vorschlag (`Smoothing.to_context/3`-Regel). In S3 betrifft das
  368 Blöcke.

  Deshalb zeigt die Liste beides: je Utterance ihren eigenen Text, und je
  **Block** einmal den wirksamen, wo er abweicht. Wer nur den Rohtext läse,
  läse eine andere Sitzung als die, auf der die Referenzliste entstanden ist.

  ## Die OOC-Verworfenen stehen mit drin

  Der Merge-Run der Glättung bricht an OOC-Stellen, und diese Utterances
  landen in **keinem** Block — in S1 sind es 43, in S3 107. Sie trotzdem zu
  zeigen ist Pflicht, nicht Freundlichkeit: Die Abschlussregel verlangt, dass
  jede Utterance zugeordnet ist (Maintainer, 19.09.2026), und was Jack nie
  zu sehen bekommt, kann er nicht zuordnen. Sie tragen `ooc?: true` — dass
  dort schon jemand anders entschieden hat, ist eine Information und keine
  Vorentscheidung.
  """

  @typedoc """
  Eine Zeile des Mitschnitts. `nr` ist die laufende Nummer in DIESER Liste
  (Jacks Zeigefinger im Gespräch); adressiert und gespeichert wird über
  `utterance_id`.
  """
  @type zeile :: %{
          nr: pos_integer(),
          utterance_id: String.t(),
          sprecher: String.t(),
          text: String.t(),
          block_id: String.t() | nil,
          block_text: String.t() | nil,
          ooc?: boolean()
        }

  @doc """
  Baut den Mitschnitt aus den Utterances einer Sitzung und ihrer Glättung.

  `utterances` in Erzählreihenfolge (wie `Worker.Repo.list_utterances/2` sie
  liefert), `blocks` die gespeicherte Glättung, `wirksam` eine Map
  `block_id => text` mit dem wirksamen Text (Vorschlag oder Kuration), wo er
  vom Blocktext abweicht.

  `namen` bildet die Discord-ID auf den Kampagnennamen ab — **eine Discord-ID
  erreicht Jack nie** (dieselbe Regel wie bei der Extraktion seit J4). Gebaut
  wird sie mit `Worker.Jack.Pipeline.sprecher/2`, das dieselbe Kaskade fährt
  wie die Extraktion: Figur oder Mitglied, sonst Anzeigename des Nutzers,
  sonst „Sprecher ohne Namen N". Hier eine zweite Auflösung zu schreiben
  hiesse, zwei Stellen zu haben, an denen eine Discord-ID durchrutschen kann.
  """
  @spec bauen([map()], [map()], %{optional(String.t()) => String.t()}, %{
          optional(String.t()) => String.t()
        }) :: [zeile()]
  def bauen(utterances, blocks, wirksam \\ %{}, namen \\ %{}) do
    block_je_utt = block_index(blocks)
    gezeigt = MapSet.new()

    {zeilen, _} =
      utterances
      |> Enum.with_index(1)
      |> Enum.map_reduce(gezeigt, fn {u, nr}, schon ->
        b = Map.get(block_je_utt, u.id)

        {text, schon} = block_text(b, wirksam, schon)

        zeile = %{
          nr: nr,
          utterance_id: u.id,
          sprecher: name(u, namen),
          text: to_string(Map.get(u, :text) || ""),
          block_id: b && b["id"],
          block_text: text,
          ooc?: is_nil(b)
        }

        {zeile, schon}
      end)

    zeilen
  end

  @doc """
  Die Zeilen eines Bereichs, als Text für das Modell. Blockwechsel und der
  wirksame Text stehen als eigene Zeilen dazwischen, damit der
  Zusammenhang sichtbar bleibt, ohne ihn je Utterance zu wiederholen.
  """
  @spec als_text([zeile()]) :: String.t()
  def als_text(zeilen) do
    zeilen
    |> Enum.map_reduce(nil, fn z, letzter_block ->
      kopf = kopfzeile(z, letzter_block)
      marke = if z.ooc?, do: " [ooc]", else: ""
      {kopf <> "#{z.nr}  #{z.sprecher}: #{z.text}#{marke}", z.block_id}
    end)
    |> elem(0)
    |> Enum.join("\n")
  end

  defp kopfzeile(%{block_id: nil}, _letzter), do: ""

  defp kopfzeile(%{block_id: b} = z, letzter) when b != letzter do
    case z.block_text do
      nil -> ""
      text -> "  ⟨geglättet: #{text}⟩\n"
    end
  end

  defp kopfzeile(_, _), do: ""

  # Der wirksame Text wird EINMAL je Block gezeigt, bei seiner ersten Zeile —
  # und nur, wenn er abweicht. Bei 1.803 Blöcken je Zeile zu wiederholen wäre
  # die Hälfte des Kontextfensters für nichts.
  defp block_text(nil, _wirksam, schon), do: {nil, schon}

  defp block_text(b, wirksam, schon) do
    id = b["id"]

    cond do
      MapSet.member?(schon, id) -> {nil, schon}
      is_nil(wirksam[id]) -> {nil, MapSet.put(schon, id)}
      true -> {wirksam[id], MapSet.put(schon, id)}
    end
  end

  defp block_index(blocks) do
    for b <- blocks, u <- b["quell_utterance_ids"] || [], into: %{}, do: {u, b}
  end

  # Wie bei der Extraktion (J4): Kampagnenname, sonst Nutzername, sonst eine
  # neutrale Bezeichnung — nie die Discord-ID.
  defp name(u, namen) do
    did = to_string(Map.get(u, :discord_id) || "")

    case Map.get(namen, did) do
      n when is_binary(n) and n != "" -> n
      _ -> "Sprecher ohne Namen"
    end
  end
end
