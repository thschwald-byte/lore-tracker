defmodule Worker.Jack.Beleg do
  @moduledoc """
  Die Belegprüfung: steht das Zitat wörtlich in den genannten Blöcken?

  Portiert aus dem Spike (`norm`, `belegStuecke`, `stueckTrifft`,
  `belegPruefen`, `belegOderFehler`, `rueckbezugOhneZweitblock`,
  `woertermenge`, `posVon`). Die Regeln, mit ihrem Anlass:

    * Ein Beleg darf aus mehreren Zitaten bestehen, mit „…“ getrennt, eines
      je Block. Jedes Stück muss in irgendeinem der genannten Blöcke stehen,
      **und** jeder genannte Block muss von mindestens einem Stück getroffen
      sein — ein source_ref ohne Zitat ist Dekoration (Lauf 19a, #31).
    * Verglichen wird normalisiert (Leerraum gefaltet, klein geschrieben);
      gemeldet wird im Wortlaut, den der Agent geschickt hat.
    * Stücke unter acht Zeichen zählen nicht, außer der ganze Beleg ist so
      kurz — oder ein kurzes Stück trifft einen genannten Block **ganz**
      („Ist die Tür verschlossen? … Nein.“): dann ist es kein Fetzen, sondern
      der ganze Block (Spike 7ecc9ea8, `kurzeStuecke`; Anlass: Frage und
      kurze Antwort waren sonst unbelegbar, Reihe C an 819/820 und 951/952).
    * Abgewiesen wird ein Beleg, der **nur aus Fragen** besteht: jedes Stück
      (an „…“ getrennt) endet auf „?“ (Spike 7ecc9ea8, `nurFragen`). Frage
      und Antwort zusammen tragen. Bis dahin prüfte der Port satzweise (Toms
      Entschärfung vom 10.09.); der Spike hat sie stückweise umgesetzt, der
      Port folgt ihm, damit J3 gegen denselben Vertrag misst.

  Blöcke kommen als `%{nummer => %{text: …}}` (siehe `Worker.Jack.Stand`).
  """

  @rueckbezug [
    "vorhin",
    "eben",
    "zuvor",
    "davor",
    "wie besprochen",
    "wie gesagt",
    "erwähnt",
    "erwaehnt",
    "genannt",
    "bereits",
    "schon vorher",
    "wieder",
    "erneut",
    "zurück",
    "zurueck",
    "seitdem",
    "inzwischen",
    "daraufhin",
    "danach",
    "deshalb",
    "dadurch"
  ]

  @type bloecke :: %{non_neg_integer() => %{text: String.t()}}
  @type pruefung :: %{
          ok: boolean(),
          ohne_treffer: [String.t()],
          refs_ohne_zitat: [integer()],
          teile: non_neg_integer()
        }

  @doc "Leerraum falten, trimmen, klein schreiben."
  @spec norm(term()) :: String.t()
  def norm(s), do: s |> falten() |> String.downcase()

  @doc "Die Stücke eines Belegs, je `%{n: normalisiert, roh: Wortlaut}`."
  @spec stuecke(term()) :: [%{n: String.t(), roh: String.t()}]
  def stuecke(beleg) do
    st =
      beleg
      |> to_string()
      |> String.split("…")
      |> Enum.map(fn s ->
        roh = falten(s)
        %{n: String.downcase(roh), roh: roh}
      end)
      |> Enum.filter(&(String.length(&1.n) >= 8))

    roh = falten(beleg)

    cond do
      st != [] -> st
      roh != "" -> [%{n: String.downcase(roh), roh: roh}]
      true -> []
    end
  end

  @doc "Die Stücke unter acht Zeichen, die `stuecke/1` beiseitelegt, normalisiert."
  @spec kurze_stuecke(term()) :: [String.t()]
  def kurze_stuecke(beleg) do
    beleg
    |> to_string()
    |> String.split("…")
    |> Enum.map(&norm/1)
    |> Enum.filter(&(&1 != "" and String.length(&1) < 8))
  end

  @doc "Die Blöcke unter `refs`, in denen das (normalisierte) Stück wörtlich steht."
  @spec trifft(String.t(), [integer()], bloecke()) :: [integer()]
  def trifft(stueck, refs, bloecke) do
    Enum.filter(refs, fn r ->
      txt = norm(get_in(bloecke, [r, :text]) || "")
      txt != "" and String.contains?(txt, stueck)
    end)
  end

  @doc "Volle Auskunft: welche Stücke nirgends stehen, welche Blöcke ohne Zitat sind."
  @spec pruefen(term(), [integer()], bloecke()) :: pruefung()
  def pruefen(beleg, refs, bloecke) do
    teile = stuecke(beleg)

    {ohne, getroffen} =
      Enum.reduce(teile, {[], MapSet.new()}, fn t, {ohne, getroffen} ->
        case trifft(t.n, refs, bloecke) do
          [] -> {ohne ++ [String.slice(t.roh, 0, 60)], getroffen}
          tr -> {ohne, Enum.into(tr, getroffen)}
        end
      end)

    # Ein kurzes Stück, das einen genannten Block ganz ausmacht, deckt ihn.
    getroffen =
      for k <- kurze_stuecke(beleg),
          r <- refs,
          norm(get_in(bloecke, [r, :text]) || "") == k,
          into: getroffen,
          do: r

    refs_ohne = Enum.reject(refs, &MapSet.member?(getroffen, &1))

    %{
      ok: teile != [] and ohne == [] and refs_ohne == [],
      ohne_treffer: ohne,
      refs_ohne_zitat: refs_ohne,
      teile: length(teile)
    }
  end

  @doc "Ist der Beleg nichts als Fragen? Jedes Stück (an „…“ getrennt) endet auf „?“."
  @spec nur_fragen?(term()) :: boolean()
  def nur_fragen?(beleg) do
    st =
      beleg
      |> to_string()
      |> String.split("…")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    st != [] and Enum.all?(st, &String.ends_with?(&1, "?"))
  end

  @doc "Die Fehlermeldungen zum Beleg, oder `nil`, wenn er trägt."
  @spec fehler(term(), [integer()], bloecke()) :: [String.t()] | nil
  def fehler(beleg, refs, bloecke) do
    if nur_fragen?(beleg) do
      [
        "Der Beleg besteht nur aus Fragen. Eine Frage belegt ihre eigene " <>
          "Antwort nicht — zitier zusätzlich die Stelle, die antwortet, mit " <>
          "„ … “ getrennt. Auch eine kurze Antwort wie „Nein.“ " <>
          "zählt, wenn du den ganzen Block zitierst."
      ]
    else
      pr = pruefen(beleg, refs, bloecke)
      if pr.ok, do: nil, else: fehler_texte(pr)
    end
  end

  defp fehler_texte(pr) do
    ohne =
      if pr.ohne_treffer == [],
        do: [],
        else: [
          "Diese Belegstücke stehen in keinem der genannten Blöcke: " <>
            Jason.encode!(pr.ohne_treffer)
        ]

    refs =
      if pr.refs_ohne_zitat == [],
        do: [],
        else: [
          "Zu diesen source_refs fehlt ein Zitat: #{Jason.encode!(pr.refs_ohne_zitat)}. " <>
            "Jeder genannte Block muss im Beleg vorkommen — mehrere Zitate mit " <>
            "„ … “ trennen, eines je Block. Oder den Block aus " <>
            "source_refs nehmen, wenn er nichts trägt. Auch eine kurze Antwort wie " <>
            "„Nein.“ zählt, wenn sie den ganzen Block ausmacht."
        ]

    ohne ++ refs
  end

  @doc """
  Zeigt der claim mit einem Wort nach hinten („vorhin“, „wieder“), während nur
  ein Block genannt ist? Liefert das erste solche Wort. Kein Ablehnungsgrund,
  nur ein Hinweis beim Eintragen.
  """
  @spec rueckbezug(term(), [integer()]) :: String.t() | nil
  def rueckbezug(_claim, refs) when length(refs) > 1, do: nil

  def rueckbezug(claim, _refs) do
    c = norm(claim)
    Enum.find(@rueckbezug, &String.contains?(c, &1))
  end

  @doc "Die Wörter eines Texts mit mehr als drei Zeichen — für die Dublettensuche."
  @spec woerter(term()) :: MapSet.t(String.t())
  def woerter(s) do
    s
    |> norm()
    |> String.split(~r/[^a-zäöüß0-9]+/u, trim: true)
    |> Enum.filter(&(String.length(&1) > 3))
    |> MapSet.new()
  end

  @doc "Wo eine Aussage im Mitschnitt sitzt: die früheste ihrer Fundstellen, sonst -1."
  @spec pos_von(term()) :: integer()
  def pos_von(refs) do
    case refs |> List.wrap() |> Enum.filter(&is_integer/1) do
      [] -> -1
      r -> Enum.min(r)
    end
  end

  defp falten(s), do: s |> to_string() |> String.replace(~r/\s+/u, " ") |> String.trim()
end
