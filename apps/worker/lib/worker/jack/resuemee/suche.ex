defmodule Worker.Jack.Resuemee.Suche do
  @moduledoc """
  Die zwei Suchen des Resümee-Jack (E0, #1210, Epic #1195):
  `suche_sitzung(begriff, weiter?)` in der laufenden Sitzung,
  `suche_bisher(begriff, weiter?)` in allem bis einschließlich der laufenden
  Sitzung. Sie ersetzen das `suche` des Fakten-Jack, das nur den Mitschnitt
  der laufenden Sitzung kannte. Zwei Werkzeuge statt einer Suche mit
  Parametern: Jack entscheidet mit der Wahl des Werkzeugs, wo er sucht
  (Maintainer, 13.09.2026; Linie „so viele Pflichtfelder wie sinnvoll“).

  **Quellen.** `suche_sitzung`: die Fakten, der Mitschnitt und die Bögen
  (Titel, Leitfrage) dieser Sitzung. `suche_bisher`: Fakten und Mitschnitte
  aller Sitzungen bis einschließlich dieser, die Resümees und Epos-Kapitel
  (auch die bisherige Fassung dieser Sitzung), die Notizen der Jacks
  (Gedächtnis des Fakten-Jack, Notizen des Resümee-Jack — für diese Sitzung
  die des laufenden Überblicks), die Bögen der Kampagne mit Leitfragen und
  die Chronik. Die Mitschnitte früherer Sitzungen lädt der erste Aufruf
  (`Worker.Jack.Resuemee.Mitschnitte`); eine Sitzung ohne Glättung steht als
  Hinweis in der Antwort.

  **Treffer.** Groß-/Kleinschreibung egal, ein Wortteil genügt, Leerraum
  zählt als ein Leerzeichen (`Worker.Jack.Beleg.norm/1`, wie die Suche des
  Fakten-Jack); mindestens drei Zeichen. Je Quelle gruppiert, je Treffer eine
  Zeile mit der Adresse zum Nachlesen (`S3-F12` für `fakt`, `S3 Block 17` für
  `block`, Resümee und Kapitel mit Sitzung und Absatz, der Bogen-Titel, die
  Chronik mit Sitzung, Datum und Titel) und einem Ausschnitt um den Treffer.
  Höchstens 20 je Quelle.

  **Blättern.** Derselbe Begriff mit `weiter: true` liefert je Quelle die
  nächsten 20; Quellen ohne weitere Treffer fallen heraus; ist alles
  gezeigt, sagt die Antwort „keine weiteren Treffer“. Die Position je
  (Werkzeug, Begriff) steht im Stand (`suche`); ein Aufruf ohne `weiter`
  beginnt vorn, `weiter` zu einem Begriff ohne vorige Suche ebenso.

  **Die Wiederholungssperre trifft das Blättern nicht:** das Werkzeug trägt
  seine Position als `wiederholung_merkmal` (`Worker.Agent.Werkzeug`) —
  solange jede Seite Neues bringt, ist jeder `weiter`-Aufruf ein anderer.
  Bleibt die Position stehen, weil alles gezeigt ist, zählt die Sperre wie
  sonst. Ein Aufruf ohne `weiter` hat immer dasselbe Merkmal und zählt wie
  jeder andere.

  Nur lesend; der Stoff eines Satzes bleiben die Fakten.
  """

  alias Worker.Jack.Beleg
  alias Worker.Jack.Resuemee.{Bisher, Mitschnitte}

  @deckel 20
  # Länge eines Ausschnitts in Zeichen und wie viel davon vor dem Treffer
  # steht — gegriffen.
  @ausschnitt 160
  @davor 60

  @titel %{
    "fakten" => "Fakten",
    "mitschnitt" => "Mitschnitt",
    "resuemees" => "Resümees",
    "kapitel" => "Epos-Kapitel",
    "gedanken" => "Notizen der Jacks",
    "boegen" => "Bögen",
    "chronik" => "Chronik"
  }

  @type ergebnis :: {map(), Worker.Agent.Werkzeug.ergebnis()}

  @doc "Wie viele Treffer je Quelle eine Antwort höchstens zeigt."
  @spec deckel() :: pos_integer()
  def deckel, do: @deckel

  @doc "Die Werkzeuge dieses Moduls, siehe `Worker.Jack.Lesen.werkzeuge/1`."
  @spec werkzeuge(map()) :: [map()]
  def werkzeuge(s) do
    n = s.sitzung.nummer

    [
      %{
        name: "suche_sitzung",
        beschreibung:
          "Sucht einen Begriff in dieser Sitzung (#{n}): in ihren Fakten, ihrem Mitschnitt " <>
            "und ihren Bögen (Titel, Leitfrage). Nimm es, wenn du wissen willst, wo in dieser " <>
            "Sitzung etwas vorkommt; für alles bis hierher nimm suche_bisher. " <>
            gemeinsam("fakt(id), block(nummer)"),
        parameter: parameter(),
        optional: ["weiter"],
        wiederholung_merkmal: merkmal("suche_sitzung"),
        ausfuehren: &suche_sitzung/2
      },
      %{
        name: "suche_bisher",
        beschreibung:
          "Sucht einen Begriff in allem, was bis einschließlich dieser Sitzung (#{n}) " <>
            "vorliegt: Fakten und Mitschnitte aller Sitzungen, Resümees, Epos-Kapitel, die " <>
            "Notizen der Jacks, die Bögen der Kampagne mit Leitfragen und die Chronik. Nimm " <>
            "es, wenn du wissen willst, was über eine Figur, einen Ort oder eine Sache schon " <>
            "bekannt ist; für diese Sitzung allein nimm suche_sitzung. " <>
            gemeinsam(
              "fakt(id), block(nummer, sitzung), vorige_resuemees, vorige_kapitel, " <>
                "vorige_gedanken, boegen_kampagne"
            ) <>
            " Die Mitschnitte früherer Sitzungen lädt der erste Aufruf.",
        parameter: parameter(),
        optional: ["weiter"],
        wiederholung_merkmal: merkmal("suche_bisher"),
        ausfuehren: &suche_bisher/2
      }
    ]
  end

  defp gemeinsam(nachlesen) do
    "Groß-/Kleinschreibung ist egal, ein Wortteil genügt. Die Treffer kommen je Quelle, " <>
      "höchstens #{@deckel} je Quelle, jeder mit seiner Adresse zum Nachlesen (#{nachlesen}) " <>
      "und einem Ausschnitt. Jede Antwort nennt je Quelle, wie viele Treffer es gibt und wie " <>
      "viele noch folgen; die nächsten holst du mit demselben Begriff und weiter: true — das " <>
      "bringt jedes Mal Neues, solange Treffer folgen."
  end

  defp parameter do
    %{
      "type" => "object",
      "properties" => %{
        "begriff" => %{
          "type" => "string",
          "description" => "Wort oder Wortteil, mindestens drei Zeichen"
        },
        "weiter" => %{
          "type" => "boolean",
          "description" => "true: die nächsten Treffer zu demselben Begriff; ohne Angabe von vorn"
        }
      }
    }
  end

  @doc """
  Das Merkmal für die Wiederholungssperre (`fn stand, argumente -> term end`,
  eingebunden über `Worker.Jack.Resuemee.Werkzeuge`): mit `weiter: true` die
  Position des Blätterns zu diesem Begriff, sonst immer dasselbe.
  """
  @spec merkmal(String.t()) :: (map(), map() -> term())
  def merkmal(werkzeug) do
    fn s, argumente ->
      case argumente do
        %{"weiter" => true, "begriff" => b} when is_binary(b) ->
          {:weiter, Map.get(s.suche, {werkzeug, Beleg.norm(b)})}

        _ ->
          :vorn
      end
    end
  end

  @doc "In dieser Sitzung suchen (Werkzeug `suche_sitzung`)."
  @spec suche_sitzung(map(), map()) :: ergebnis()
  def suche_sitzung(s, p), do: suchen(s, p, "suche_sitzung")

  @doc "In allem bis einschließlich dieser Sitzung suchen (Werkzeug `suche_bisher`)."
  @spec suche_bisher(map(), map()) :: ergebnis()
  def suche_bisher(s, p), do: suchen(s, p, "suche_bisher")

  defp suchen(s, %{"begriff" => begriff} = p, werkzeug) do
    nadel = Beleg.norm(begriff)

    if String.length(nadel) < 3 do
      {s, {:error, "Der Begriff ist zu kurz — nimm mindestens drei Zeichen."}}
    else
      {s, kandidaten, hinweise} = quellen(s, werkzeug)
      gruppen = for {q, k} <- kandidaten, do: {q, Enum.filter(k, &trifft?(&1, nadel))}
      schluessel = {werkzeug, nadel}
      weiter? = p["weiter"] == true
      vorher = if weiter?, do: Map.get(s.suche, schluessel)
      kopf = kopf(s, werkzeug, begriff, weiter?, vorher)
      {text, pos} = antwort(kopf, gruppen, vorher, weiter? and vorher != nil, nadel)
      text = Enum.join([text | hinweise], "\n\n")
      {%{s | suche: Map.put(s.suche, schluessel, pos)}, {:ok, text}}
    end
  end

  defp trifft?(k, nadel), do: String.contains?(Beleg.norm(k.such), nadel)

  # ─── Antwort ──────────────────────────────────────────────────────────

  defp kopf(s, werkzeug, begriff, weiter?, vorher) do
    n = s.sitzung.nummer

    ort =
      if werkzeug == "suche_sitzung",
        do: "in Sitzung #{n} (ihre Fakten, ihr Mitschnitt, ihre Bögen)",
        else: "in allem bis einschließlich Sitzung #{n}"

    zusatz =
      cond do
        weiter? and vorher == nil ->
          " Zu diesem Begriff gab es noch keine Suche — hier die ersten Treffer."

        weiter? ->
          " Die nächsten Treffer."

        true ->
          ""
      end

    "Suche nach „#{String.trim(begriff)}“ #{ort}." <> zusatz
  end

  defp antwort(kopf, gruppen, vorher, blaettern?, nadel) do
    start = vorher || %{}

    teile =
      for {q, treffer} <- gruppen do
        ab = min(Map.get(start, q, 0), length(treffer))
        %{quelle: q, treffer: treffer, ab: ab, teil: Enum.slice(treffer, ab, @deckel)}
      end

    pos = Map.new(teile, &{&1.quelle, &1.ab + length(&1.teil)})
    gezeigt = Enum.filter(teile, &(&1.teil != []))

    text =
      cond do
        gezeigt == [] and blaettern? ->
          [kopf, "Keine weiteren Treffer — alle Treffer zu diesem Begriff sind gezeigt."]

        gezeigt == [] ->
          [kopf, "Keine Treffer."]

        true ->
          ohne = if blaettern?, do: [], else: ohne_treffer(teile)
          [kopf | Enum.map(gezeigt, &abschnitt(&1, nadel))] ++ ohne
      end

    {Enum.join(text, "\n\n"), pos}
  end

  defp abschnitt(t, nadel) do
    gesamt = length(t.treffer)
    bis = t.ab + length(t.teil)
    rest = gesamt - bis

    folgen =
      if rest > 0,
        do: "#{rest} folgen (derselbe Begriff mit weiter: true)",
        else: "keine weiteren"

    kopf = "## #{@titel[t.quelle]} — #{gesamt} Treffer, hier #{t.ab + 1} bis #{bis}, #{folgen}"
    Enum.join([kopf | Enum.map(t.teil, &zeile(&1, nadel))], "\n")
  end

  defp ohne_treffer(teile) do
    case for(t <- teile, t.treffer == [], do: @titel[t.quelle]) do
      [] -> []
      namen -> ["Ohne Treffer: #{Enum.join(namen, ", ")}."]
    end
  end

  defp zeile(k, nadel) do
    [k.adresse, k.vor, ausschnitt(k.text, nadel)]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" · ")
  end

  @doc """
  Ein Ausschnitt von höchstens #{@ausschnitt} Zeichen um die erste
  Fundstelle von `nadel` (normalisiert wie `Worker.Jack.Beleg.norm/1`);
  Leerraum zusammengezogen, „…“ an gekürzten Enden. Ohne Fundstelle (der
  Treffer lag in einem anderen Feld) der Anfang.
  """
  @spec ausschnitt(String.t(), String.t()) :: String.t()
  def ausschnitt(text, nadel) do
    t = text |> to_string() |> String.replace(~r/\s+/u, " ") |> String.trim()
    g = String.graphemes(t)
    laenge = length(g)

    if laenge <= @ausschnitt do
      t
    else
      i = fundstelle(g, nadel) || 0
      bis = min(max(i - @davor, 0) + @ausschnitt, laenge)
      von = max(bis - @ausschnitt, 0)

      if(von > 0, do: "…", else: "") <>
        (g |> Enum.slice(von, bis - von) |> Enum.join()) <>
        if(bis < laenge, do: "…", else: "")
    end
  end

  # Der Graphem-Index der ersten Fundstelle: jedes Graphem klein geschrieben,
  # die Byte-Stelle des Treffers auf das Graphem zurückgerechnet, das sie
  # enthält.
  defp fundstelle(g, nadel) do
    klein = Enum.map(g, &String.downcase/1)
    enden = Enum.scan(klein, 0, &(byte_size(&1) + &2))

    case :binary.match(Enum.join(klein), nadel) do
      {byte, _} -> Enum.find_index(enden, &(&1 > byte))
      :nomatch -> nil
    end
  end

  # ─── Quellen ──────────────────────────────────────────────────────────

  # Je Quelle die Kandidaten `%{adresse:, vor:, text:, such:}` — `such` ist,
  # was durchsucht wird, `text`, woraus der Ausschnitt kommt.
  defp quellen(s, "suche_sitzung") do
    n = s.sitzung.nummer

    {s,
     [
       {"fakten", Enum.map(s.fakten, &fakt/1)},
       {"mitschnitt", bloecke(n, s.mitschnitt)},
       {"boegen", Enum.map(s.boegen, &bogen/1)}
     ], []}
  end

  defp quellen(s, "suche_bisher") do
    {s, mitschnitte} = Mitschnitte.alle(s)
    fehler = for {_nr, {:error, text}} <- mitschnitte, do: text

    hinweise =
      if fehler == [], do: [], else: ["Mitschnitt nicht durchsucht: #{Enum.join(fehler, " ")}"]

    {s,
     [
       {"fakten", s |> Bisher.alle_fakten() |> Enum.map(&fakt/1)},
       {"mitschnitt", for({nr, {:ok, m}} <- mitschnitte, k <- bloecke(nr, m), do: k)},
       {"resuemees", absaetze("Resümee", resuemees(s), s.sitzung.nummer)},
       {"kapitel", absaetze("Kapitel", s.kapitel, s.sitzung.nummer)},
       {"gedanken", gedanken(s)},
       {"boegen", s |> Bisher.alle_boegen() |> Enum.map(&bogen/1)},
       {"chronik", Enum.map(s.chronik, &chronik/1)}
     ], hinweise}
  end

  defp fakt(f) do
    figur = Map.get(f, :figur)
    %{adresse: f.id, vor: figur, text: f.aussage, such: "#{figur} #{f.aussage}"}
  end

  defp bloecke(nr, m) do
    for i <- 0..m.max_block//1, %{} = blk <- [Map.get(m.bloecke, i)] do
      text = blk.text || ""
      %{adresse: "S#{nr} Block #{i}", vor: Map.get(blk, :sprecher), text: text, such: text}
    end
  end

  defp bogen(b) do
    text = if b.leitfrage, do: "#{b.titel} — Leitfrage: #{b.leitfrage}", else: b.titel

    %{
      adresse: "Bogen „#{b.titel}“",
      vor: [b.art, b.status] |> Enum.reject(&is_nil/1) |> Enum.join(", "),
      text: text,
      such: text
    }
  end

  defp resuemees(s) do
    diese =
      if s.resuemee_diese, do: [%{nummer: s.sitzung.nummer, text: s.resuemee_diese}], else: []

    s.vorige_resuemees ++ diese
  end

  # Resümee und Kapitel, je Absatz ein Kandidat; das dieser Sitzung ist die
  # bisherige Fassung.
  defp absaetze(art, texte, diese) do
    for t <- texte,
        {absatz, k} <-
          t.text
          |> String.split(~r/\n\s*\n/u)
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))
          |> Enum.with_index(1) do
      fassung = if t.nummer == diese, do: " (bisherige Fassung)", else: ""

      %{
        adresse: "#{art} S#{t.nummer}#{fassung}, Absatz #{k}",
        vor: nil,
        text: absatz,
        such: absatz
      }
    end
  end

  defp gedanken(s) do
    frueher =
      Enum.flat_map(s.vorige_gedanken, fn g ->
        notizen(g.nummer, "Gedächtnis", g.fakten_jack) ++
          notizen(g.nummer, "Resümee-Notiz", notizliste(g.resuemee_jack))
      end)

    n = s.sitzung.nummer

    frueher ++
      notizen(n, "Gedächtnis", s.register_diese) ++ notizen(n, "Resümee-Notiz", s.notizen)
  end

  defp notizliste(%{"notizen" => n}), do: n
  defp notizliste(%{notizen: n}), do: n
  defp notizliste(_keine), do: []

  defp notizen(nr, art, eintraege) when is_list(eintraege) do
    for %{} = e <- eintraege,
        zeile <- [feld(e, :zeile)],
        is_binary(zeile) and String.trim(zeile) != "" do
      schluessel = to_string(feld(e, :schluessel))

      %{
        adresse: "S#{nr} #{art} #{feld(e, :abschnitt)} / #{schluessel}",
        vor: nil,
        text: zeile,
        such: "#{schluessel} #{zeile}"
      }
    end
  end

  defp notizen(_nr, _art, _keine), do: []

  defp feld(m, k), do: Map.get(m, k) || Map.get(m, Atom.to_string(k))

  defp chronik(e) do
    wo = if e.nummer, do: "Chronik S#{e.nummer}", else: "Chronik (ohne Sitzung)"

    %{
      adresse: wo,
      vor: [e.datum, e.label] |> Enum.reject(&is_nil/1) |> Enum.join(" · "),
      text: e.text,
      such: "#{e.datum} #{e.label} #{e.text}"
    }
  end
end
