defmodule Worker.Jack.Resuemee.Mitschnitte do
  @moduledoc """
  Der Mitschnitt aller Sitzungen bis einschließlich der laufenden (E0, #1210):
  `bloecke` und `block` mit optionaler `sitzung`, die Belegblöcke früherer
  Fakten für `fakt(id)` und das Laden für `suche_bisher`.

  **Erst beim Zugriff geladen.** Bei vielen Sitzungen sind es zehntausende
  Blöcke; die Eingabe trägt deshalb keinen Mitschnitt früherer Sitzungen,
  sondern einen Lader (`mitschnitt_laden`, im Stand `lader` — gesetzt von
  `Worker.Jack.Resuemee.Eingabe.aus_repo/1`, in Tests ein Fake). Beim ersten
  Zugriff auf eine frühere Sitzung ruft ihn das Werkzeug und legt das Ergebnis
  im Stand ab (`mitschnitte`, je Sitzungsnummer) — auch einen Fehler, damit
  eine Sitzung ohne Glättung nicht bei jedem Aufruf neu gelesen wird. Ein
  frischer Lauf beginnt ohne geladene Mitschnitte.

  **Dieselbe Nummerierung wie beim Fakten-Jack jener Sitzung:** der Lader
  liefert ihre Kontextliste (`Worker.Jack.Pipeline.gespeicherter_kontext/1` +
  `kontext/1`), und nur in genau dieser Liste zeigt Blocknummer n auf die
  Block-ID, die ein Fakt zitiert. Gelesen wird mit `Worker.Jack.Lesen` auf
  einem eigenen `Worker.Jack.Stand` je Sitzung.

  **Ohne Lader oder ohne Glättung** antworten die Werkzeuge mit einem klaren
  Satz statt eines Absturzes; wirft der Lader, gilt das als Fehler dieser
  Sitzung.

  Pur: Stand und Argumente hinein, neuer Stand und Ergebnis heraus. Die
  Funktionen lesen nur die Felder `sitzung`, `fruehere`, `mitschnitt`,
  `lader` und `mitschnitte` — ein anderer Jack mit denselben Feldern kann sie
  mitbenutzen.
  """

  alias Worker.Jack.Lesen, as: Mitschnitt
  alias Worker.Jack.Resuemee.Stand

  @type geladen :: {:ok, Worker.Jack.Stand.t()} | {:hinweis, String.t()} | {:error, String.t()}

  @doc """
  `bloecke` und `block` des Fakten-Jack, dazu das optionale Feld `sitzung`:
  ohne Angabe (oder mit der Nummer dieser Sitzung) diese Sitzung, sonst eine
  frühere, beim ersten Zugriff geladen.
  """
  @spec werkzeuge(map()) :: [map()]
  def werkzeuge(%{mitschnitt: m} = s) do
    defs = Map.new(Mitschnitt.werkzeuge(m), &{&1.name, &1})

    for name <- ~w(bloecke block) do
      d = Map.fetch!(defs, name)
      fun = d.ausfuehren

      d
      |> Map.merge(%{
        beschreibung: d.beschreibung <> zum_verstehen(s) <> frueher_satz(s),
        parameter:
          update_in(d.parameter, ["properties"], &Map.put(&1, "sitzung", sitzung_feld())),
        ausfuehren: fn stand, argumente -> lesen(stand, argumente, fun) end
      })
      |> Map.put(:optional, Map.get(d, :optional, []) ++ ["sitzung"])
    end
  end

  # Wofür der Mitschnitt da ist — je Jack (#1210): beim Epos-Jack das Kapitel.
  defp zum_verstehen(%{art: :epos}),
    do:
      " Im Epos-Kapitel dient der Mitschnitt zum Verstehen der Fakten — der Stoff sind die " <>
        "Fakten."

  defp zum_verstehen(%{art: :chronik}),
    do:
      " In der Chronik dient der Mitschnitt zum Verstehen der Fakten — der Stoff sind die " <>
        "Fakten."

  defp zum_verstehen(_s),
    do: " Im Resümee dient der Mitschnitt zum Verstehen der Fakten — der Stoff sind die Fakten."

  defp sitzung_feld,
    do: %{
      "type" => "integer",
      "minimum" => 1,
      "description" => "Nummer einer früheren Sitzung; ohne Angabe diese Sitzung"
    }

  defp frueher_satz(%{fruehere: []}), do: ""

  defp frueher_satz(s) do
    " Die Blockzahl gilt für diese Sitzung (#{s.sitzung.nummer}). Mit sitzung liest du den " <>
      "Mitschnitt einer früheren Sitzung (#{Enum.map_join(s.fruehere, ", ", & &1.nummer)}) — " <>
      "dieselben Nummern, auf die ihre Fakten zeigen; er wird beim ersten Zugriff geladen."
  end

  # Ohne Angabe oder mit der eigenen Nummer der Mitschnitt dieser Sitzung;
  # sonst der geladene einer früheren, mit einem Kopf, der sie nennt.
  defp lesen(s, argumente, fun) do
    {nr, rest} = Map.pop(argumente, "sitzung")

    if nr in [nil, s.sitzung.nummer] do
      {m, ergebnis} = fun.(s.mitschnitt, rest)
      {%{s | mitschnitt: m}, ergebnis}
    else
      case laden(s, nr) do
        {s, {:ok, m}} ->
          {m, ergebnis} = fun.(m, rest)
          {%{s | mitschnitte: Map.put(s.mitschnitte, nr, {:ok, m})}, mit_kopf(ergebnis, nr)}

        {s, {:hinweis, text}} ->
          {s, {:ok, text}}

        {s, {:error, text}} ->
          {s, {:error, text}}
      end
    end
  end

  defp mit_kopf({:ok, text}, nr), do: {:ok, "Mitschnitt von Sitzung #{nr}:\n" <> text}
  defp mit_kopf({art, text}, nr), do: {art, "Sitzung #{nr}: " <> text}

  @doc """
  Der Mitschnitt einer Sitzung als `Worker.Jack.Stand`: diese Sitzung sofort,
  eine frühere aus dem Stand oder — beim ersten Zugriff — über den Lader.
  Ohne frühere Sitzungen der neutrale Hinweis
  (`Worker.Jack.Resuemee.Stand.keine_frueheren/0`), für eine Nummer, die nicht
  früher ist, ein Fehler, der die früheren nennt.
  """
  @spec laden(map(), integer()) :: {map(), geladen()}
  def laden(%{sitzung: %{nummer: n}} = s, n), do: {s, {:ok, s.mitschnitt}}
  def laden(%{fruehere: []} = s, _nr), do: {s, {:hinweis, Stand.keine_frueheren()}}

  def laden(s, nr) do
    cond do
      not Enum.any?(s.fruehere, &(&1.nummer == nr)) ->
        {s, {:error, nicht_frueher(s, nr)}}

      Map.has_key?(s.mitschnitte, nr) ->
        {s, antwort(s.mitschnitte[nr], nr)}

      s.lader == nil ->
        {s, {:error, fehlertext(:kein_lader, nr)}}

      true ->
        geladen = laden_ueber(s, nr)
        {%{s | mitschnitte: Map.put(s.mitschnitte, nr, geladen)}, antwort(geladen, nr)}
    end
  end

  defp laden_ueber(%{lader: lader, mitschnitt: m}, nr) do
    case lader.(nr) do
      {:ok, bloecke} when is_list(bloecke) ->
        {:ok, Worker.Jack.Stand.neu(bloecke: bloecke, cast: m.cast, straenge: m.straenge)}

      {:error, grund} ->
        {:error, grund}

      anderes ->
        {:error, {:unerwartet, anderes}}
    end
  rescue
    e -> {:error, {:ausnahme, Exception.message(e)}}
  end

  defp antwort({:ok, m}, _nr), do: {:ok, m}
  defp antwort({:error, grund}, nr), do: {:error, fehlertext(grund, nr)}

  defp fehlertext({:extraction, {:jack, :keine_glaettung}}, nr),
    do: "Zu Sitzung #{nr} liegt kein Mitschnitt vor: sie ist nicht geglättet."

  defp fehlertext(:kein_lader, nr),
    do:
      "Der Mitschnitt von Sitzung #{nr} ist in diesem Lauf nicht verfügbar; was ihre Fakten " <>
        "sagen, liefert fakten(sitzung: #{nr}, …)."

  defp fehlertext(grund, nr),
    do: "Der Mitschnitt von Sitzung #{nr} ließ sich nicht laden (#{inspect(grund, limit: 5)})."

  defp nicht_frueher(s, nr) do
    "Sitzung #{nr} gehört nicht zu den früheren Sitzungen. Früher sind: " <>
      "#{Enum.map_join(s.fruehere, ", ", & &1.nummer)}. Ohne sitzung liest du diese Sitzung " <>
      "(#{s.sitzung.nummer})."
  end

  @doc """
  Die Mitschnitte aller Sitzungen bis einschließlich dieser, aufsteigend:
  `[{nummer, {:ok, Worker.Jack.Stand} | {:error, text}}]`. Lädt, was noch
  nicht geladen ist (für `suche_bisher`).
  """
  @spec alle(map()) :: {map(), [{integer(), {:ok, Worker.Jack.Stand.t()} | {:error, String.t()}}]}
  def alle(s) do
    {frueher, s} =
      Enum.map_reduce(s.fruehere, s, fn f, acc ->
        {acc, r} = laden(acc, f.nummer)
        {{f.nummer, r}, acc}
      end)

    {s, frueher ++ [{s.sitzung.nummer, {:ok, s.mitschnitt}}]}
  end

  @doc """
  Die Belegblöcke eines Fakts einer früheren Sitzung als Text, aus dem
  Mitschnitt jener Sitzung (geladen beim ersten Zugriff). Ohne Lader der Satz,
  dass ihr Mitschnitt hier nicht geladen ist; ohne Glättung der Grund.
  """
  @spec belege(map(), map()) :: {map(), String.t()}
  def belege(%{lader: nil} = s, f),
    do:
      {s,
       "Der Fakt stammt aus Sitzung #{f.sitzung}. Deren Mitschnitt ist hier nicht geladen; " <>
         "was er sagt, steht in der Zeile oben."}

  def belege(s, f) do
    case laden(s, f.sitzung) do
      {s, {:ok, m}} -> {s, belegtext(m, f)}
      {s, {_art, text}} -> {s, "Der Fakt stammt aus Sitzung #{f.sitzung}. " <> text}
    end
  end

  defp belegtext(m, f) do
    positionen = Map.new(m.bloecke, fn {i, b} -> {Map.get(b, :block_id), i} end)
    refs = Map.get(f, :refs, [])

    nummern =
      refs
      |> Enum.map(&Map.get(positionen, &1))
      |> Enum.filter(&is_integer/1)
      |> Enum.uniq()
      |> Enum.sort()

    zeilen = for n <- nummern, {_, {:ok, z}} <- [Mitschnitt.block(m, %{"nummer" => n})], do: z
    ohne = Enum.count(refs, &(not Map.has_key?(positionen, &1)))

    kopf =
      if zeilen == [],
        do: "Belegblöcke: keine im Mitschnitt von Sitzung #{f.sitzung}.",
        else: "Belegblöcke im Mitschnitt von Sitzung #{f.sitzung} (block(nummer, sitzung)):"

    rest =
      if ohne > 0,
        do: [
          "#{ohne} Beleg(e) liegen außerhalb des Mitschnitts von Sitzung #{f.sitzung} " <>
            "(neu geglättet oder als unbrauchbar markiert)."
        ],
        else: []

    Enum.join(["Der Fakt stammt aus Sitzung #{f.sitzung}.", kopf | zeilen] ++ rest, "\n")
  end
end
