defmodule Worker.Jack.Chronik.Pipeline do
  @moduledoc """
  Der Chronik-Jack in der Pipeline (J7, #1211): er schreibt die Chronik an
  der Stelle des früheren deterministischen Zeitstrahls
  (`Worker.Recording.Pipeline.Zeit.publiziere/3`, Stufe `"timeline"`).

  **Was an die Stelle der drei Filter tritt.** Der alte Pfad liess jeden
  verifizierten Fakt durch drei Filter laufen (`time_signal?`, `datierbar?`,
  `filter_arc_kind`) und machte aus jedem Überlebenden einen Eintrag mit
  gerechnetem Tag. Keiner dieser Filter passt zu einer gebündelten Chronik:
  Jack entscheidet, was ein Eintrag wird, und Elixir rechnet die Reihenfolge.

  **Geleert wird nicht mehr.** Der alte Pfad schrieb
  `ChronikClearedForSession` und danach alle Einträge der Sitzung neu; eine
  Phase gehört aber keiner Sitzung. Die Verfeinerung ergänzt. Das Ereignis
  bleibt lesbar (Bestand, Replay), geschrieben wird es nicht mehr.

  **Best effort.** Scheitert der Chronik-Jack, bleibt die bestehende Chronik
  stehen — bei der Verfeinerung ohnehin, weil nichts geleert wird, und beim
  Aufbau, weil dann schlicht nichts veröffentlicht wird. Die Stufe meldet den
  Fehlschlag in `/admin/errors` wie jede andere.

  **Modell:** dasselbe wie Jack, aber eigens wählbar über `chronik_jack_model`;
  leer heisst Jacks Modell (`model_stage2_local`).
  """

  require Logger

  alias Worker.Jack.Chronik
  alias Worker.Jack.Chronik.{Datierung, Eingabe}

  @doc """
  Der Modellname des Chronik-Jack: `chronik_jack_model`, wenn gesetzt und
  nicht leer, sonst Jacks Modell.
  """
  @spec modell_name() :: String.t() | nil
  def modell_name do
    case Worker.Settings.get(:chronik_jack_model) do
      name when is_binary(name) ->
        if String.trim(name) == "", do: jacks_modell(), else: String.trim(name)

      _ ->
        jacks_modell()
    end
  end

  defp jacks_modell, do: Worker.Settings.model_for(2, :local)

  @doc "Das Modell des Chronik-Jack."
  @spec modell() :: {:ok, {module(), keyword()}} | {:error, term()}
  def modell, do: Worker.Jack.Pipeline.modell(modell_name())

  @doc """
  Schreibt die Chronik der Kampagne, ausgelöst von einer Sitzung. Liefert
  `{:ok, eintraege}` — die veröffentlichten Einträge, für den Kapitelkopf des
  Epos — oder `{:error, grund}`.

  Optionen wie beim Resümee-Jack: `:melde_stufe`, `:modell`,
  `:kontext_fenster`, `:modell_name`, `:max_runden`, `:max_ms`.
  """
  @spec schreiben(map(), map(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def schreiben(session, campaign, opts \\ []) do
    melde = Keyword.get(opts, :melde_stufe, fn _stufe, _ereignis -> :ok end)

    case vorbereiten(session, opts) do
      {:ok, eingabe, modell, fenster} ->
        fahren(session, campaign, eingabe, [modell: modell, kontext_fenster: fenster], opts)

      {:error, _} = fehler ->
        melde.("timeline", :beginn)
        melde.("timeline", {:ende, fehler})
        fehler
    end
  end

  defp vorbereiten(session, opts) do
    with {:ok, modell} <- aus_opts(opts, :modell, &modell/0),
         {:ok, fenster} <-
           aus_opts(opts, :kontext_fenster, &Worker.Jack.Pipeline.kontext_fenster/0),
         {:ok, eingabe} <- Eingabe.aus_repo(session.id) do
      {:ok, eingabe, modell, fenster}
    end
  end

  defp aus_opts(opts, schluessel, sonst) do
    case Keyword.fetch(opts, schluessel) do
      {:ok, wert} -> {:ok, wert}
      :error -> sonst.()
    end
  end

  defp fahren(session, campaign, eingabe, modell_opts, opts) do
    sicht = Process.whereis(Worker.Jack.Sicht)

    lauf_opts =
      (modell_opts ++
         [melde_stufe: opts[:melde_stufe], beobachter: sicht, stand_beobachter: sicht] ++
         Keyword.take(opts, [:max_runden, :max_ms]))
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    with {:ok, r} <- Chronik.laufen(eingabe, lauf_opts) do
      messen(session, campaign, r)
      {:ok, veroeffentlichen(session, campaign, r, Map.get(eingabe, :fakten, []))}
    end
  end

  @doc """
  Die Messzeile des Trichters (#1111). Ohne sie ist „gebündelt" von
  „verschluckt" nicht zu unterscheiden — genau der Zustand, in dem wochenlang
  „16 → 175 Einträge" als belegter Erfolg in der Doku stand, während die
  Wirkung null war.
  """
  @spec messen(map(), map(), map()) :: :ok
  def messen(session, campaign, r) do
    t = r.trichter

    Logger.info(
      "Chronik-Jack[#{r.betriebsart}]: campaign=#{campaign.id} session=#{session.id} " <>
        "fakten=#{t["fakten_gesamt"]} (ereignis=#{t["fakten_ereignis"]} " <>
        "zustand=#{t["fakten_zustand"]}) -> eintraege=#{t["eintraege"]} " <>
        "(phasen=#{t["phasen"]} schluesselszenen=#{t["schluesselszenen"]}) " <>
        "ohne_eintrag=#{t["fakten_ohne_eintrag"]} bestand_vorher=#{t["bestand_vorher"]} " <>
        "zyklen=#{t["zyklen"]} verwaiste_bezuege=#{t["verwaiste_bezuege"]}"
    )

    :ok
  end

  @doc """
  Veröffentlicht die Einträge als `ChronikEntryChanged` — **ohne** vorheriges
  Leeren. Jeder Eintrag bekommt seinen Rang aus der gerechneten Reihenfolge;
  Einträge ohne Rang (ein Kreis in den Bezügen) sortieren nach dem alten
  Schlüssel.

  Ein Lauf, eine `generation`: der Ordnungsschlüssel für LWW bei gleicher ID.
  """
  @spec veroeffentlichen(map(), map(), map(), [map()]) :: [map()]
  def veroeffentlichen(session, campaign, r, fakten \\ []) do
    session
    |> payloads(campaign, r, fakten)
    |> Enum.map(fn payload ->
      {:ok, _} = Worker.Intents.publish(payload)
      fuer_leser(payload)
    end)
  end

  @doc """
  Die Ereignisse, die `veroeffentlichen/4` publiziert — gebaut, aber nicht
  publiziert. Getrennt, damit prüfbar ist, WAS ein Eintrag trägt: genau das
  war am 18.09.2026 der Defekt (leere `source_refs`), und über den
  Publish-Pfad allein wäre er in keinem Test aufgefallen — der braucht einen
  laufenden Materializer.
  """
  @spec payloads(map(), map(), map(), [map()]) :: [map()]
  def payloads(session, campaign, r, fakten \\ []) do
    generation = UUIDv7.generate()
    nach_id = Map.new(fakten, &{&1.fakt_id, &1})
    raenge = Map.new(Enum.with_index(r.rangfolge, 1), fn {id, i} -> {id, i} end)

    # Die Daten, soweit ein Anker sie trägt (#1211). Einträge ohne Anker in
    # Reichweite fehlen in dieser Map und bleiben ohne Tag — das ist der
    # Unterschied zum alten Pfad, der jedem Fakt den Session-Anker gab und
    # damit 543 von 544 Einträgen auf denselben Tag legte (#1092).
    daten =
      Datierung.datieren(
        r.eintraege,
        r.rangfolge,
        Worker.Repo.get_campaign_calendar(campaign.id),
        Worker.Repo.get_session_anchor(session.id)
      )

    Enum.map(r.eintraege, fn e ->
      payload = %{
        "kind" => Shared.Events.chronik_entry_changed(),
        "id" => e.id,
        "campaign_id" => campaign.id,
        "label" => e.titel,
        "summary" => e.text,
        "markdown_body" => e.text,
        # Die Sitzung, die den Lauf ausgelöst hat — nicht die, zu der der
        # Eintrag gehört: eine Phase gehört keiner. Der Reader sortiert seit
        # #1211 über den Rang, nicht über die Sitzung.
        "session_id" => session.id,
        # Die Blöcke, aus denen die Fakten dieses Eintrags stammen — dieselbe
        # Regel wie beim Resümee (`Resuemee.Pipeline.quellen/2`) und beim Epos.
        # Sie standen bis zum 18.09.2026 leer, und damit hing die ganze
        # Oberflächen-Anbindung der Chronik in der Luft: kein 🕳-Lückenmarker,
        # keine Sprungmarke ins Protokoll, kein Eintrag im Scroll-Sync — alle
        # drei lösen über `source_refs` auf (`Worker.Repo.GlattQuellen`).
        "source_refs" => refs_von(e.fakt_ids, nach_id),
        # Welche Sitzungen den Eintrag tragen. Eine Phase gehört keiner
        # einzelnen — `session_id` nennt nur die, die den Lauf ausgelöst hat,
        # und wird bei jeder Verfeinerung überschrieben.
        "sitzungen" => sitzungen_von(e.fakt_ids, nach_id),
        "generation" => generation,
        "wichtigkeit" => e.wichtigkeit,
        "fakt_ids" => e.fakt_ids,
        "zeit_bezug" => e.zeit_bezug,
        "rang" => Map.get(raenge, e.id)
      }

      # Ein Datum kommt nur dazu, wenn eines zu haben ist. Die Felder ganz
      # wegzulassen statt sie auf nil zu setzen, ist Absicht: der Fold
      # unterscheidet nicht, aber der nächste Leser dieses Codes soll sehen,
      # dass hier nichts geraten wird.
      payload =
        case Map.get(daten, e.id) do
          nil ->
            payload

          d ->
            Map.merge(payload, %{
              "in_game_day" => d.in_game_day,
              "in_game_date" => d.in_game_date,
              "precision" => d.precision
            })
        end

      payload
    end)
  end

  # Das Ereignis trägt String-Schlüssel und lässt ein fehlendes Datum ganz weg
  # (s.o.) — für den NÄCHSTEN LESER ist beides falsch. `Render.chapter_header/3`
  # greift mit `&1.in_game_day` zu, und `Epos.Pipeline.kopf/3` bekommt je nach
  # Zweig entweder diese Liste oder die des Repos: derselbe Parameter in zwei
  # Formen. Am 18.09.2026 kostete das das Epos-Kapitel von seattleV5 S2
  # (`KeyError key :in_game_day`) — und es hätte JEDEN Lauf mit nicht-leerer
  # Chronik getroffen; bei S1 blieb es nur verborgen, weil die Liste dort leer
  # war und `Enum.map([])` nichts anfasst.
  #
  # Die Rückgabe hat deshalb die Gestalt des Repo-Lesers: Atom-Schlüssel, und
  # ein fehlendes Datum steht als `nil` statt gar nicht. Im Ereignis bleibt es
  # weggelassen — dort ist das Absicht.
  # Die Belegblöcke der genannten Fakten, ohne Dubletten. Ein Fakt, den die
  # Eingabe nicht kennt (aus einem früheren Lauf, inzwischen neu extrahiert),
  # trägt nichts bei, statt den Eintrag scheitern zu lassen.
  defp refs_von(fakt_ids, nach_id) do
    fakt_ids
    |> Enum.flat_map(&(nach_id |> Map.get(&1, %{}) |> Map.get(:refs, [])))
    |> Enum.uniq()
  end

  defp sitzungen_von(fakt_ids, nach_id) do
    fakt_ids
    |> Enum.map(&(nach_id |> Map.get(&1, %{}) |> Map.get(:sitzung)))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @spec fuer_leser(map()) :: map()
  def fuer_leser(payload) do
    %{
      id: payload["id"],
      campaign_id: payload["campaign_id"],
      session_id: payload["session_id"],
      label: payload["label"],
      summary: payload["summary"],
      markdown_body: payload["markdown_body"],
      wichtigkeit: payload["wichtigkeit"],
      fakt_ids: payload["fakt_ids"],
      zeit_bezug: payload["zeit_bezug"],
      rang: payload["rang"],
      sitzungen: payload["sitzungen"] || [],
      in_game_day: payload["in_game_day"],
      in_game_date: payload["in_game_date"],
      precision: payload["precision"],
      source_refs: payload["source_refs"] || []
    }
  end
end
