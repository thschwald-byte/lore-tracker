defmodule Worker.Jack.Epos.Weg do
  @moduledoc """
  Der Weg aus dem Resümee im Überblick des Epos-Jack (E1, #1210): die
  Stationen, die der Resümee-Jack als GLIEDERUNG notiert hat (im Stand
  `resuemee_weg`, gebaut von `Worker.Jack.Epos.Eingabe`), das Werkzeug
  `resuemee()` und die Frage, welche Station noch weder in einer Szene noch
  unter ABWEICHUNG steht. Pur.

  Maintainer, 13.09.2026: „Grundlage: den Weg aus dem Resümee übergeben, aber
  prüfen — und eigene Szenen aufstellen, ohne Obergrenze für ihre Zahl.“ Der
  Weg ist eine Vorlage, keine Gliederung, die das Epos übernimmt. Verlangt
  wird nur, dass keine Station still verloren geht:

    * **Pflicht** ist eine Station, die mindestens einen Fakt **dieser**
      Sitzung nennt (`pflicht/1`) — eine Station ohne ihn ließe sich nie
      tragen (dieselbe Regel wie `Worker.Jack.Resuemee.Weg.pruefbar/1`).
    * **Getragen** ist sie, wenn eine Szene einen ihrer Fakten dieser Sitzung
      nennt (`szenen_von/2`); **abgewichen**, wenn unter ABWEICHUNG ein
      Eintrag mit ihrem Schlüssel steht (`abgewichen?/2`).
    * **Offen** (`offen/1`) ist eine Pflicht-Station, die weder getragen noch
      abgewichen ist — `fertig` lehnt ab, solange es eine gibt
      (`Worker.Jack.Epos.Abschluss`).

  Dazu der Hinweis zur Spanne der SZENEN in Blocknummern und zu ihrer
  Reihenfolge (`hinweis/1`, gerechnet mit `Worker.Jack.Resuemee.Weg.spanne/2`)
  — ein Fingerzeig wie beim Resümee, keine Ablehnung: die Szenen stehen in
  Erzählreihenfolge, eine Rückblende darf von der Blockreihenfolge abweichen.

  **Ehrliche Grenze:** geprüft wird, dass eine Szene einen Fakt der Station
  nennt, nicht, dass sie die Station erzählt — die Prüfung hängt an den
  genannten Fakten, wie überall bei Jack.
  """

  alias Worker.Jack.Resuemee.Stand
  alias Worker.Jack.Resuemee.Weg, as: Gliederung

  # Wie lang eine Aussage in `resuemee()` höchstens erscheint — gegriffen.
  @aussage_max 100

  @doc "Die Stationen des Wegs aus dem Resümee, in ihrer Reihenfolge."
  @spec stationen(Stand.t()) :: [map()]
  def stationen(%Stand{resuemee_weg: w}), do: w || []

  @doc "Eine Station über ihren Schlüssel (Groß-/Kleinschreibung und Leerraum egal), sonst `nil`."
  @spec station(Stand.t(), term()) :: map() | nil
  def station(%Stand{} = s, schluessel) when is_binary(schluessel) do
    k = kanonisch(schluessel)
    Enum.find(stationen(s), &(kanonisch(&1.schluessel) == k))
  end

  def station(_s, _schluessel), do: nil

  defp kanonisch(t), do: t |> String.trim() |> String.downcase()

  @doc "Die Stationen, die mindestens einen Fakt dieser Sitzung nennen."
  @spec pflicht(Stand.t()) :: [map()]
  def pflicht(%Stand{} = s), do: Enum.filter(stationen(s), &(Gliederung.eigene(s, &1) != []))

  @doc "Die SZENEN, die einen Fakt dieser Sitzung der Station nennen."
  @spec szenen_von(Stand.t(), map()) :: [Stand.notiz()]
  def szenen_von(%Stand{} = s, station) do
    ids = MapSet.new(Gliederung.eigene(s, station), & &1.id)

    Enum.filter(Stand.abschnitt(s, "SZENEN"), fn szene ->
      Enum.any?(szene.fakten, &MapSet.member?(ids, &1))
    end)
  end

  @doc "Ob unter ABWEICHUNG ein Eintrag mit dem Schlüssel der Station steht."
  @spec abgewichen?(Stand.t(), map()) :: boolean()
  def abgewichen?(%Stand{} = s, station),
    do: Enum.any?(Stand.abschnitt(s, "ABWEICHUNG"), &(&1.schluessel == station.schluessel))

  @doc "Die Pflicht-Stationen, die weder eine Szene trägt noch ABWEICHUNG nennt."
  @spec offen(Stand.t()) :: [map()]
  def offen(%Stand{} = s),
    do: Enum.reject(pflicht(s), &(szenen_von(s, &1) != [] or abgewichen?(s, &1)))

  @doc "Stationen als Text: `„1“ — Zeile; „3“ — Zeile`."
  @spec text([map()]) :: String.t()
  def text(stationen), do: Gliederung.text(stationen)

  # ─── resuemee() ───────────────────────────────────────────────────────

  @doc "Das Werkzeug `resuemee` für einen Stand, siehe `Worker.Jack.Lesen.werkzeuge/1`."
  @spec werkzeuge(Stand.t()) :: [map()]
  def werkzeuge(%Stand{} = s) do
    [
      %{
        name: "resuemee",
        beschreibung: beschreibung(s),
        parameter: %{"type" => "object", "properties" => %{}},
        wiederholung: :frei,
        ausfuehren: &resuemee/2
      }
    ]
  end

  # Im Schreiben (E2) und in der Durchsicht (E3) ist der Weg zum Nachlesen
  # da, geplant ist schon.
  defp beschreibung(%Stand{lauf: lauf}) when lauf in [:schreiben, :durchsicht],
    do:
      "Das Resümee dieser Sitzung und der Weg der Gruppe, den es festhält: der Text, darunter " <>
        "je Station Schlüssel, Zeile und ihre Fakten (ID und Aussage, gekürzt) und in welcher " <>
        "deiner Szenen sie steht. Zum Nachlesen — deine Szenen stehen in deinen Notizen."

  defp beschreibung(%Stand{}),
    do:
      "Das Resümee dieser Sitzung und der Weg der Gruppe, den es festhält: der Text, " <>
        "darunter je Station Schlüssel, Zeile und ihre Fakten (ID und Aussage, gekürzt), " <>
        "dazu, ob sie schon in einer deiner Szenen oder unter ABWEICHUNG steht. Der Weg " <>
        "ist deine Vorlage: prüf ihn gegen die Fakten und stell daraus deine eigenen " <>
        "Szenen auf."

  @doc "Das Resümee dieser Sitzung samt Weg (Werkzeug `resuemee`)."
  @spec resuemee(Stand.t(), map()) :: {Stand.t(), Worker.Agent.Werkzeug.ergebnis()}
  def resuemee(%Stand{} = s, _args), do: {s, {:ok, resuemee_text(s)}}

  defp resuemee_text(s) do
    n = s.sitzung.nummer

    text =
      case s.resuemee_diese do
        t when is_binary(t) -> ["## Das Resümee von Sitzung #{n}", "", String.trim(t)]
        _ -> ["Zu Sitzung #{n} liegt kein Resümee vor."]
      end

    weg =
      case stationen(s) do
        [] ->
          [
            "",
            "Aus dem Resümee liegt kein Weg der Gruppe vor. Du stellst ihn selbst auf: in " <>
              "deinen SZENEN, vom Anfang bis zum Ende der Sitzung."
          ]

        st ->
          ["", "## Der Weg der Gruppe aus dem Resümee — #{anzahl(length(st))}", ""] ++
            Enum.flat_map(st, &station_text(s, &1)) ++
            [
              "Jede Station, die einen Fakt dieser Sitzung nennt, steht am Ende in einer " <>
                "deiner SZENEN — einer Szene, die einen ihrer Fakten nennt — oder unter " <>
                "ABWEICHUNG: Schlüssel ist der Schlüssel der Station, die Zeile sagt, warum " <>
                "das Kapitel sie anders erzählt oder weglässt."
            ]
      end

    Enum.join(text ++ weg, "\n")
  end

  defp anzahl(1), do: "1 Station"
  defp anzahl(n), do: "#{n} Stationen"

  defp station_text(s, st) do
    kopf = "Station „#{st.schluessel}“ — #{st.zeile}  (#{status(s, st)})"
    fakten = Enum.map(st.fakten, &fakt_zeile(s, &1))
    [kopf | fakten] ++ [""]
  end

  defp status(s, st) do
    szenen = szenen_von(s, st)

    teile =
      Enum.reject(
        [
          if(szenen != [],
            do: "in Szene " <> Enum.map_join(szenen, ", ", &"„#{&1.schluessel}“")
          ),
          if(abgewichen?(s, st), do: "unter ABWEICHUNG")
        ],
        &is_nil/1
      )

    cond do
      Gliederung.eigene(s, st) == [] -> "nennt keinen Fakt dieser Sitzung"
      teile == [] -> "noch offen"
      true -> Enum.join(teile, "; ")
    end
  end

  defp fakt_zeile(s, id) do
    case Stand.fakt(s, id) do
      nil ->
        "  #{id} · (diesen Fakt gibt es nicht)"

      f ->
        vor = if Stand.diese_sitzung?(s, f), do: "", else: "(Sitzung #{f.sitzung}) "
        "  #{f.id} · #{vor}#{kuerzen(f.aussage)}"
    end
  end

  defp kuerzen(text) do
    g = String.graphemes(text)
    if length(g) <= @aussage_max, do: text, else: Enum.join(Enum.take(g, @aussage_max)) <> "…"
  end

  # ─── Wo du stehst ─────────────────────────────────────────────────────

  @doc """
  Die Zeile zum Weg für `notizen_lesen`, die Antwort von `notiz` und die
  Zusammenfassung: wie viele Pflicht-Stationen in einer Szene oder unter
  ABWEICHUNG stehen und welche noch offen sind.
  """
  @spec stand_zeile(Stand.t()) :: String.t()
  def stand_zeile(%Stand{} = s) do
    case {stationen(s), pflicht(s), offen(s)} do
      {[], _, _} ->
        "Weg aus dem Resümee: liegt nicht vor — deine SZENEN sind der Weg der Gruppe, vom " <>
          "Anfang bis zum Ende der Sitzung."

      {_, [], _} ->
        "Weg aus dem Resümee: keine seiner Stationen nennt einen Fakt dieser Sitzung — keine " <>
          "muss in einer Szene oder unter ABWEICHUNG stehen."

      {_, p, []} ->
        "Weg aus dem Resümee: jede der #{length(p)} Stationen steht in einer Szene oder unter " <>
          "ABWEICHUNG."

      {_, p, o} ->
        "Weg aus dem Resümee: #{length(p) - length(o)} von #{length(p)} Stationen stehen in " <>
          "einer Szene oder unter ABWEICHUNG. Noch in keiner Szene und nicht unter " <>
          "ABWEICHUNG: #{text(o)}."
    end
  end

  @doc """
  Der Hinweis zur Spanne der SZENEN in Blocknummern und zu ihrer Reihenfolge
  — ein Fingerzeig, keine Ablehnung. `nil` ohne SZENEN oder ohne
  Blocknummern in der Sitzung.
  """
  @spec hinweis(Stand.t()) :: String.t() | nil
  def hinweis(%Stand{} = s) do
    if Stand.abschnitt(s, "SZENEN") == [],
      do: nil,
      else: hinweis_text(Gliederung.spanne(s, "SZENEN"))
  end

  defp hinweis_text(%{sitzung: nil}), do: nil

  defp hinweis_text(%{gliederung: nil, sitzung: {a, b}}),
    do:
      "Die Fakten deiner SZENEN tragen keine Blocknummern; die Fakten dieser Sitzung reichen " <>
        "von Block #{a} bis #{b}."

  defp hinweis_text(%{gliederung: {g1, g2}, sitzung: {a, b}, reihenfolge: r}) do
    Enum.join(
      [
        "Die Fakten deiner SZENEN reichen von Block #{g1} bis #{g2}, die Fakten dieser " <>
          "Sitzung von Block #{a} bis #{b}."
      ] ++ ausserhalb(g1, g2, a, b) ++ reihenfolge_text(r),
      " "
    )
  end

  defp ausserhalb(g1, g2, a, b) do
    teile =
      Enum.reject(
        [if(a < g1, do: "vor Block #{g1}"), if(g2 < b, do: "nach Block #{g2}")],
        &is_nil/1
      )

    case teile do
      [] ->
        []

      _ ->
        [
          "#{gross(Enum.join(teile, " und "))} liegen Fakten, die keine Szene nennt — das " <>
            "Kapitel erzählt den Weg der Gruppe vom Anfang bis zum Ende der Sitzung."
        ]
    end
  end

  defp gross(t) do
    {erster, rest} = String.split_at(t, 1)
    String.upcase(erster) <> rest
  end

  defp reihenfolge_text(:ja), do: ["Die Szenen stehen in Blockreihenfolge."]
  defp reihenfolge_text(:offen), do: []

  defp reihenfolge_text({:nein, {p, a}, {q, b}}),
    do: [
      "Die Szenen stehen nicht in Blockreihenfolge: „#{q.schluessel}“ beginnt bei Block #{b}, " <>
        "vor „#{p.schluessel}“ (Block #{a}), steht aber dahinter. Die SZENEN stehen in der " <>
        "Reihenfolge, in der das Kapitel erzählt; eine Rückblende darf davon abweichen."
    ]
end
