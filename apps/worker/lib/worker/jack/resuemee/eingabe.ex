defmodule Worker.Jack.Resuemee.Eingabe do
  @moduledoc """
  Was der Resümee-Jack (J5, #1209) von einer Sitzung zu lesen bekommt. Die
  Eingabe ist eine reine Map; `aus_repo/1` baut sie aus Mnesia, alles
  dahinter (`Worker.Jack.Resuemee.Stand` und die Werkzeuge) arbeitet ohne
  Mnesia und ist so testbar.

  **Die Fakten liest Jack wie der heutige Render-Pfad:** den gespeicherten
  Bestand der Sitzung über `Worker.Jack.Pipeline.geprueft/1`
  (`Worker.Repo.get_session_facts/1`), davon die mit `verified? == true`
  (`Render.render_prose/5` filtert dasselbe). Die Kuration der
  Fakten-Spalte wirkt dort nicht und hier auch nicht — sie wird gerade neu
  gedacht (Maintainer, 12.09.2026). Alle Fakten der Sitzung kommen an, auch
  die eines `rauschen`-Strangs: Jack liest alle, die Art steht an jedem.

  **Bögen wie der Render:** `Worker.Repo.fact_render_assignments/2` ordnet
  jedem Fakt seine Bögen samt Art (`arc`, `context`, `rauschen`) zu, dieselbe
  Präzedenz wie das Fäden-Panel. Leitfrage und Status kommen aus dem Strang
  (`Worker.Repo.Threads.campaign_threads/1`). Jack erfindet keine Bögen; die
  kampagnenweiten Stränge sind die Grundlage.

  **Der Mitschnitt ist die Kontextliste des Fakten-Jack:**
  `Worker.Jack.Pipeline.gespeicherter_kontext/1`, dann `kontext/1` (ohne
  OOC-Blöcke). Nur in genau dieser Liste zeigt Blocknummer n auf die
  Block-ID, die ein Fakt in `source_refs` zitiert. Belege, die dort nicht
  (mehr) stehen — neu geglättet, `unbrauchbar` kuratiert, Alt-Fakten mit
  Utterance-IDs —, zählt der Fakt als `ohne_block`.

  **Vorgeschichte:** frühere Sitzungen sind die mit kleinerer Nummer, nicht
  die zuletzt erzeugten — auch bei Neu-Generierung in anderer Reihenfolge
  richtig. Von jeder: die geprüften Fakten (ohne Blocknummern; ihr Mitschnitt
  wird nicht geladen), das Resümee (`get_session_summary/1`, die angezeigte
  Fassung) und die Gedanken. Die Gedanken des Fakten-Jack sind das Register
  aus `JackStandAbgelegt`, die des Resümee-Jack seine Notizen aus
  `JackResuemeeStandAbgelegt` (seit B4, `Worker.Jack.Resuemee.Pipeline`) —
  `nil`, solange er die Sitzung nicht geschrieben hat.

  **Ehrliche Grenze:** `fact_render_assignments/2` liest die Stränge der
  Kampagne selbst noch einmal; der Doppel-Read kostet Rechenzeit im Worker,
  keinen Speicher im Hub.
  """

  require Logger

  alias Worker.Jack.Pipeline
  alias Worker.Recording.Pipeline.Prompts

  @standard_ueberschrift "Resümee"

  @type t :: map()

  @doc """
  Die Eingabe für eine Sitzung aus dem Repo:

      %{sitzung: %{id:, nummer:, name:}, fakten: [fakt], fruehere: [...],
        boegen: [...], vorige_resuemees: [...], vorige_gedanken: [...],
        bloecke: [...], cast: [...], straenge: [...], ueberschrift:, flavor:,
        max_woerter:}

  Fehler: `{:error, :keine_sitzung}`, `{:error, :keine_kampagne}`,
  `{:error, :no_facts}` (noch keine Extraktion), der Fehler von
  `Worker.Jack.Pipeline.gespeicherter_kontext/1` (keine Glättung) oder von
  `Worker.Jack.Pipeline.eingabe/4`.
  """
  @spec aus_repo(String.t()) :: {:ok, t()} | {:error, term()}
  def aus_repo(session_id) do
    with {:ok, sitzung} <- sitzung(session_id),
         {:ok, campaign} <- kampagne(sitzung.campaign_id),
         {:ok, facts} <- Pipeline.geprueft(session_id),
         {:ok, gespeichert} <- Pipeline.gespeicherter_kontext(session_id) do
      mit_kampagne(sitzung, campaign, verifiziert({:ok, facts}), Pipeline.kontext(gespeichert))
    end
  end

  defp mit_kampagne(sitzung, campaign, diese, kontext) do
    cid = campaign.id
    threads = Worker.Repo.Threads.campaign_threads(cid)
    cast = Worker.Repo.character_roster_for(cid)

    with {:ok, m} <-
           Pipeline.eingabe(
             kontext,
             Pipeline.sprecher(cid, kontext),
             cast,
             Enum.map(threads, & &1.canonical)
           ) do
      frueher = cid |> Worker.Repo.list_sessions() |> Enum.filter(&(&1.number < sitzung.number))
      frueher_facts = Map.new(frueher, &{&1.id, verifiziert(Pipeline.geprueft(&1.id))})

      zuordnung =
        Worker.Repo.fact_render_assignments(
          cid,
          diese ++ Enum.flat_map(frueher, &frueher_facts[&1.id])
        )

      positionen = kontext |> Enum.with_index() |> Map.new(fn {b, i} -> {b.id, i} end)
      fakten = fakten(diese, sitzung.number, zuordnung, positionen)

      {:ok,
       %{
         sitzung: %{id: sitzung.id, nummer: sitzung.number, name: sitzung.name},
         fakten: fakten,
         fruehere:
           Enum.map(frueher, fn s ->
             %{
               nummer: s.number,
               name: s.name,
               fakten: fakten(frueher_facts[s.id], s.number, zuordnung, nil)
             }
           end),
         boegen: boegen(fakten, threads),
         vorige_resuemees: vorige_resuemees(frueher),
         vorige_gedanken: vorige_gedanken(frueher),
         bloecke: m.bloecke,
         cast: m.cast,
         straenge: m.straenge,
         ueberschrift: ueberschrift(campaign),
         flavor: flavor(campaign),
         max_woerter: max_woerter(campaign)
       }}
    end
  end

  defp sitzung(session_id) do
    case Worker.Repo.get_session(session_id) do
      nil -> {:error, :keine_sitzung}
      s -> {:ok, s}
    end
  end

  defp kampagne(campaign_id) do
    case Worker.Repo.get_campaign(campaign_id) do
      nil -> {:error, :keine_kampagne}
      c -> {:ok, c}
    end
  end

  defp verifiziert({:ok, facts}), do: Enum.filter(facts, &(&1["verified?"] == true))
  defp verifiziert(_kein_bestand), do: []

  defp vorige_resuemees(frueher) do
    for s <- frueher,
        %{content_md: text} when is_binary(text) <- [Worker.Repo.get_session_summary(s.id)],
        String.trim(text) != "",
        do: %{nummer: s.number, name: s.name, text: text}
  end

  defp vorige_gedanken(frueher) do
    for s <- frueher do
      %{
        nummer: s.number,
        name: s.name,
        fakten_jack: register(Worker.Repo.jack_stand_for_session(s.id)),
        # Ohne abgelegten Stand sagt das Werkzeug, dass es keine Notizen gibt.
        resuemee_jack: notizen(Worker.Repo.jack_resuemee_stand_for_session(s.id))
      }
    end
  end

  defp register(%{stand: %{"fortsetzung" => %{"register" => r}}}) when is_list(r), do: r
  defp register(_kein_stand), do: nil

  # Dieselbe Form, die `Stand.ablage/1` liefert und die Werkzeuge lesen.
  defp notizen(%{stand: %{"notizen" => n}}) when is_list(n), do: %{"notizen" => n}
  defp notizen(_kein_stand), do: nil

  @doc """
  Die Überschrift der Resümee-Spalte aus „Stil setzen“
  (`vorgaben["summary"].name`), sonst „Resümee“ — derselbe Default wie der
  Spaltentitel im Hub.
  """
  @spec ueberschrift(map()) :: String.t()
  def ueberschrift(campaign) do
    case Prompts.stage_heading(campaign, "summary") do
      n when is_binary(n) ->
        if String.trim(n) == "", do: @standard_ueberschrift, else: String.trim(n)

      _ ->
        @standard_ueberschrift
    end
  end

  @doc """
  Die Länge des Resümees aus „Stil setzen“ (`campaign.resuemee_max_woerter`,
  `Worker.Repo.get_campaign/1`), sonst der Standard
  (`Shared.ResuemeeLaenge.standard/0`, 75 Wörter). Ein ungültiger Wert gilt
  als Standard und steht laut im Log — der Fold lässt keinen durch, das hier
  ist die zweite Schranke, falls einer auf anderem Weg ankommt.
  """
  @spec max_woerter(map()) :: pos_integer()
  def max_woerter(campaign) do
    wert = Map.get(campaign, :resuemee_max_woerter)

    case Shared.ResuemeeLaenge.pruefen(wert) do
      {:ok, n} ->
        n

      :leer ->
        Shared.ResuemeeLaenge.standard()

      {:error, :ungueltig} ->
        Logger.warning(
          "Resümee-Jack: ungültige Länge #{inspect(wert)} für Kampagne " <>
            "#{inspect(Map.get(campaign, :id))} — es gilt der Standard " <>
            "(#{Shared.ResuemeeLaenge.standard()} Wörter)"
        )

        Shared.ResuemeeLaenge.standard()
    end
  end

  @doc "Grundton und Resümee-Ton aus „Stil setzen“ (`nil`, wo nichts gesetzt ist); für B2."
  @spec flavor(map()) :: %{base: String.t() | nil, summary: String.t() | nil}
  def flavor(campaign) do
    flavors = campaign[:flavors] || %{}

    %{
      base: Prompts.effective_flavor(flavors, "base"),
      summary: Prompts.effective_flavor(flavors, "summary")
    }
  end

  @doc """
  Die Fakten einer Sitzung, wie Jack sie sieht (`t:Worker.Jack.Resuemee.Stand.fakt/0`).
  `facts` in der gespeicherten Reihenfolge, `nummer` die Sessionnummer,
  `zuordnung` das Ergebnis von `fact_render_assignments/2`, `positionen`
  Block-ID → Blocknummer der Kontextliste (`nil` für eine frühere Sitzung,
  deren Mitschnitt nicht geladen ist). Die kurze ID ist `"S<nummer>-F<pos>"`,
  die Position zählt ab 1.
  """
  @spec fakten([map()], pos_integer(), map(), %{String.t() => non_neg_integer()} | nil) ::
          [map()]
  def fakten(facts, nummer, zuordnung, positionen) do
    facts
    |> Enum.with_index(1)
    |> Enum.map(fn {f, i} ->
      {bloecke, ohne} = bloecke(List.wrap(f["source_refs"]), positionen)

      %{
        id: "S#{nummer}-F#{i}",
        fakt_id: f["id"],
        sitzung: nummer,
        aussage: f["claim"] || "",
        figur: leer_nil(f["character_alias"]),
        typ: f["fact_type"] || "ereignis",
        boegen:
          zuordnung
          |> Map.get(f["id"], [])
          |> Enum.map(&%{titel: &1.titel, art: &1.kind}),
        datum: leer_nil(f["in_game_date"]),
        erzaehlzeit: f["narration_time"] || "present",
        bloecke: bloecke,
        ohne_block: ohne
      }
    end)
  end

  defp bloecke(_refs, nil), do: {[], 0}

  defp bloecke(refs, positionen) do
    nummern =
      refs
      |> Enum.map(&Map.get(positionen, &1))
      |> Enum.filter(&is_integer/1)
      |> Enum.uniq()
      |> Enum.sort()

    {nummern, Enum.count(refs, &(not Map.has_key?(positionen, &1)))}
  end

  defp leer_nil(t) when is_binary(t), do: if(String.trim(t) == "", do: nil, else: t)
  defp leer_nil(_), do: nil

  @doc """
  Die Bögen, die Fakten dieser Sitzung berühren, in der Reihenfolge ihres
  ersten Fakts: `%{titel:, art:, leitfrage:, status:, fakten: [kurze IDs]}`.
  Leitfrage und Status aus dem Strang gleichen Titels (`threads` wie
  `campaign_threads/1`); ohne Strang (ein Sekundär-Label ohne eigenen Strang)
  bleiben beide `nil`. Status ist der des Bogens (`offen`/`geschlossen`),
  sonst der des Strangs (`offen`/`ruhend`/`aufgelöst`).
  """
  @spec boegen([map()], [map()]) :: [map()]
  def boegen(fakten, threads) do
    norm = &Worker.ThreadOverride.normalize/1
    strang = Map.new(threads, &{norm.(&1.canonical), &1})

    fakten
    |> Enum.flat_map(& &1.boegen)
    |> Enum.uniq_by(&norm.(&1.titel))
    |> Enum.map(fn b ->
      t = Map.get(strang, norm.(b.titel))

      %{
        titel: b.titel,
        art: b.art,
        leitfrage: t && leer_nil(Map.get(t, :leitfrage)),
        status: status(t),
        fakten:
          for(f <- fakten, Enum.any?(f.boegen, &(norm.(&1.titel) == norm.(b.titel))), do: f.id)
      }
    end)
  end

  defp status(nil), do: nil

  defp status(t) do
    case Map.get(t, :arc_status) do
      s when is_binary(s) -> s
      _ -> t |> Map.get(:status) |> then(&if(&1, do: to_string(&1)))
    end
  end
end
