defmodule Worker.Jack.Zeit.Pipeline do
  @moduledoc """
  #1247 (Z4): der Zeit-Jack in der Pipeline — er läuft **nach** dem Bestand
  und **vor** dem Resümee.

  Die Stelle ist begründet: Die Linie ist Wahrheitsbasis, keine Prosa, und
  der Chronik-Jack muss sie lesen können. Sie hinter die Prosa zu hängen
  hiesse, dass jede Ableitung eine Sitzung hinterherhinkt.

  **Best effort, und zwar in beide Richtungen.** Scheitert der Zeit-Jack,
  läuft der Rest weiter — eine Linie ist eine Verbesserung, keine
  Vorbedingung; und was ein abgebrochener Lauf gesetzt hat, bleibt gesetzt,
  weil jeder Anker einzeln geprüft ist.

  **Modell:** dasselbe wie Jack, aber eigens wählbar über `zeit_jack_model`;
  leer heisst Jacks Modell (`model_stage2_local`).
  """

  require Logger

  alias Worker.Jack.Zeit
  alias Worker.Jack.Zeit.{Eingabe, Stand}

  @doc """
  Der Modellname des Zeit-Jack: `zeit_jack_model`, wenn gesetzt und nicht
  leer, sonst Jacks Modell.
  """
  @spec modell_name() :: String.t() | nil
  def modell_name do
    case Worker.Settings.get(:zeit_jack_model) do
      name when is_binary(name) ->
        if String.trim(name) == "", do: jacks_modell(), else: String.trim(name)

      _ ->
        jacks_modell()
    end
  end

  defp jacks_modell, do: Worker.Settings.model_for(2, :local)

  @doc "Das Modell des Zeit-Jack."
  @spec modell() :: {:ok, {module(), keyword()}} | {:error, term()}
  def modell, do: Worker.Jack.Pipeline.modell(modell_name())

  @doc """
  Ordnet die Äußerungen einer Sitzung ein und veröffentlicht die Anker.

  Liefert `{:ok, %{anker: n, geprueft?: bool}}` oder `{:error, grund}`.
  """
  @spec einordnen(map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def einordnen(session, campaign, opts \\ []) do
    melde = Keyword.get(opts, :melde_stufe, fn _stufe, _ereignis -> :ok end)

    case vorbereiten(session, opts) do
      {:ok, eingabe, modell, fenster} ->
        fahren(session, campaign, eingabe, [modell: modell, kontext_fenster: fenster], opts)

      {:error, _} = fehler ->
        # Ein Fehler VOR den Läufen (Modell, Fenster, fehlende Glättung)
        # gehört trotzdem ins Laufband und nach /admin/errors — sonst
        # verschwindet die Stufe lautlos, und von aussen sieht ein Lauf ohne
        # Linie aus wie einer, in dem es nichts einzuordnen gab.
        melde.("zeit", :beginn)
        melde.("zeit", {:ende, fehler})
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
    sicht = Process.whereis(Worker.Jack.Zeit.Sicht) || Process.whereis(Worker.Jack.Sicht)

    lauf_opts =
      (modell_opts ++
         [melde_stufe: opts[:melde_stufe], beobachter: sicht, stand_beobachter: sicht] ++
         Keyword.take(opts, [:max_runden, :max_ms, :pruefen]))
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    with {:ok, r} <- Zeit.laufen(eingabe, lauf_opts) do
      anker = veroeffentlichen(session, campaign, r.stand)
      stand_ablegen(session, campaign, r)
      messen(session, campaign, r, anker)
      {:ok, %{anker: length(anker), geprueft?: r.geprueft?}}
    end
  end

  @doc """
  Veröffentlicht die Anker des Laufs als `ZeitAnkerSet` — einen je Anker.

  **Die bestehenden werden mitgeschickt, wenn Jack sie geändert hat, und
  sonst nicht.** Ein Anker, den er nur gelesen hat, trägt dieselben Daten wie
  die Row, aus der er kam; ihn erneut zu publizieren erzeugte Ereignisse ohne
  Wirkung und schöbe bei jedem Lauf die `event_id` vor — der LWW-Vergleich
  in `Worker.Materializer.ZeitAnkerFolds` verlöre damit seine Aussage.
  """
  @spec veroeffentlichen(map(), map(), Stand.t()) :: [map()]
  def veroeffentlichen(session, campaign, %Stand{} = stand) do
    stand
    |> eigene_anker()
    |> Enum.map(fn anker ->
      {:ok, _} = Worker.Intents.publish(payload(anker, session, campaign))
      anker
    end)
  end

  @doc "Das Ereignis eines Ankers — gebaut, nicht publiziert (prüfbar ohne Materializer)."
  @spec payload(map(), map(), map()) :: map()
  def payload(anker, session, campaign) do
    %{
      "kind" => Shared.Events.zeit_anker_set(),
      "anker_id" => anker.anker_id,
      "campaign_id" => campaign.id,
      "session_id" => session.id,
      "daten" => daten(anker)
    }
  end

  # Nur die Felder, die der Anker trägt — die gerechneten (`minute`,
  # `tagesminute`, `halbtag_minute`, `minuten`) NICHT: Sie sind eine
  # Ableitung aus `wert` und dem Kalender, und gespeichert würden sie beim
  # nächsten Kalenderwechsel zur stillen Altlast. `Worker.Repo.Zeit` rechnet
  # sie beim Lesen neu.
  defp daten(anker) do
    anker
    |> Map.take([
      :utterance_ids,
      :art,
      :wert,
      :welt,
      :halbtag,
      :zweifel,
      :beleg,
      :quelle,
      :abgesegnet_von,
      :abgesegnet_am,
      :ziel,
      :richtung
    ])
    |> Map.new(fn {k, v} -> {to_string(k), wert(v)} end)
  end

  defp wert(v) when is_atom(v) and not is_nil(v) and not is_boolean(v), do: to_string(v)
  defp wert(v), do: v

  # Jacks eigene Anker: die, die dieser Lauf gesetzt hat. Die menschlich
  # gesetzten reisen als Eingabe mit und tragen `quelle: "mensch"`; sie
  # zurückzuschreiben hiesse, eine Kuration als Modellausgabe zu speichern.
  defp eigene_anker(%Stand{anker: anker}) do
    anker
    |> Map.values()
    |> Enum.filter(&(to_string(Map.get(&1, :quelle) || "") == "jack"))
  end

  defp stand_ablegen(session, campaign, r) do
    {:ok, _} =
      Worker.Intents.publish(%{
        "kind" => Shared.Events.jack_zeit_stand_abgelegt(),
        "session_id" => session.id,
        "campaign_id" => campaign.id,
        "stand" => %{
          "jack" => "zeit",
          "abbild" => Stand.abbild(r.stand),
          "notizen" => r.stand.notizen,
          "konflikte" => r.stand.konflikte,
          "geprueft" => r.geprueft?,
          "modell" => modell_name(),
          "abgelegt_am" => DateTime.to_iso8601(DateTime.utc_now())
        }
      })

    :ok
  end

  @doc """
  Die Messzeile des Trichters. Ohne sie ist „nichts zu finden" von „nichts
  gefunden" nicht zu unterscheiden — dieselbe Lehre wie beim Chronik-Jack
  (#1111), und hier wiegt sie schwerer: Eine Sitzung ohne eine einzige
  Uhrzeit ist ein realer Fall (eine der vier durchgesehenen hat in 1591
  Blöcken keine).
  """
  @spec messen(map(), map(), map(), [map()]) :: :ok
  def messen(session, campaign, r, anker) do
    z = Stand.zahlen(r.stand)

    Logger.info(
      "Zeit-Jack: campaign=#{campaign.id} session=#{session.id} " <>
        "zeilen=#{z.utterances} gelesen=#{z.gelesen} -> anker=#{length(anker)} " <>
        "(zeitpunkte=#{z.zeitpunkte} spannen=#{z.spannen} verschiebungen=#{z.verschiebungen}) " <>
        "geloest=#{z.geloest} konflikte=#{z.konflikte} geprueft=#{r.geprueft?} " <>
        "runden=#{r.runden} ms=#{r.ms}"
    )

    :ok
  end
end
