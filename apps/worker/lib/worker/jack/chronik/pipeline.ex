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
      {:ok, veroeffentlichen(session, campaign, r)}
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
  @spec veroeffentlichen(map(), map(), map()) :: [map()]
  def veroeffentlichen(session, campaign, r) do
    generation = UUIDv7.generate()
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
        "source_refs" => [],
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

      {:ok, _} = Worker.Intents.publish(payload)
      payload
    end)
  end
end
