defmodule Worker.Jack.Epos.Pipeline do
  @moduledoc """
  Der Epos-Jack in der Pipeline (J6, #1210, E4): er schreibt das Epos-Kapitel
  jeder Sitzung, an der Stelle des früheren Render-Kapitels
  (`Worker.Recording.Pipeline.run_wahrheitsbild/4`, nach Resümee und Chronik,
  vor den Bogen-Progressionen). **Kein Rückfall auf den alten Render**
  (`Render.render_epos` ist entfernt).

  **Ablauf** (`schreiben/3`): Eingabe aus dem Repo
  (`Worker.Jack.Epos.Eingabe.aus_repo/1` — samt dem eben abgelegten Stand des
  Resümee-Jack, aus dem der Weg kommt), dann die drei Läufe
  (`Worker.Jack.Epos.laufen/2`: Überblick → Schreiben → Durchsicht), dann der
  Stand als `JackEposStandAbgelegt` (`stand_ablegen/3`). Das Kapitel
  veröffentlicht `kapitel/6` danach über `veroeffentlichen/5`.

  **Best-effort, wie das Epos schon immer:** scheitern Überblick oder
  Schreiben (Klassen `epos_ueberblick_ohne_abschluss`,
  `epos_schreiben_ohne_abschluss`), gibt es für diesen Lauf kein neues
  Kapitel — das bisherige bleibt stehen, der Lauf geht weiter. Scheitert nur
  die Durchsicht (`epos_durchsicht_gescheitert`), gilt das Kapitel aus dem
  Schreiben und wird veröffentlicht. Ein Fehler vor den Läufen — Modell,
  Kontextfenster, Eingabe — erscheint als Fehlschlag von `"render_epos"`, der
  Stufe, unter der das Epos schon immer lief; ebenso ein Raise (`kapitel/6`
  fängt ihn, damit er den Lauf nicht mitreißt).

  **#753 bleibt:** ein Kapitel mit GM-Edit (History-Row mit `source: :manual`)
  wird von der Pipeline nicht überschrieben — `kapitel/6` prüft das VOR dem
  Jack, es läuft dann kein Modell. Neu schreiben trotz Edit ist eine bewusste
  GM-Aktion über die Kapitel-Edit-UI.

  **Kapitelkopf:** deterministisch aus den Einträgen der Chronik
  (`Worker.Recording.Pipeline.Render.chapter_header/3`, #752, mit Datum seit
  #1092); der Epos-Jack schreibt ihn nicht. Er steht vor dem Markdown.

  **Modell** (`modell/0`): Endpunkt, Sampling-Regler und Kontextfenster wie
  Jack, das Modell eigens wählbar über `epos_jack_model`; leer heißt Jacks
  Modell (`model_stage2_local`).

  **Quellen** (`quellen/2`): die Quellen stehen je Absatz (`quellen` im
  Ereignis, `Worker.Jack.Epos.Ergebnis.quellen/1`: Absatz → Szene → Fakten).
  `source_refs` des Kapitels sind die Block-Belege der Fakten **dieser**
  Sitzung aus den Szenen, die ein Absatz erzählt; ein Absatz ohne Szene und
  Fakten früherer Sitzungen tragen nichts bei. Sprungmarken, Sync-Index und
  🕳-Marker (`epos_chapter:<id>`) lösen sie wie bisher über
  `Worker.Repo.GlattQuellen` auf. **Ehrliche Grenze:** die Zuordnung sagt,
  welche Szene ein Absatz erzählt, nicht, dass er ihre Fakten wiedergibt.

  **Von Hand** (Worker-Konsole): `schreiben/3` mit Session und Kampagne aus
  dem Repo, dann `veroeffentlichen/4` mit dem Bestand der Sitzung
  (`Worker.Jack.Pipeline.geprueft/1`) — der Kopf kommt dann aus der
  gespeicherten Chronik dieser Sitzung.
  """

  require Logger

  alias Worker.Jack.Epos
  alias Worker.Jack.Epos.{Eingabe, Ergebnis}
  alias Worker.Jack.Resuemee.Stand
  alias Worker.Recording.Pipeline.Render

  @schreiben "render_epos"

  @doc """
  Der Modellname des Epos-Jack: `epos_jack_model`, wenn gesetzt und nicht
  leer, sonst Jacks Modell (`model_stage2_local`). Kann `nil` sein — dann
  scheitert `modell/0` laut.
  """
  @spec modell_name() :: String.t() | nil
  def modell_name do
    case Worker.Settings.get(:epos_jack_model) do
      name when is_binary(name) ->
        if String.trim(name) == "", do: jacks_modell(), else: String.trim(name)

      _ ->
        jacks_modell()
    end
  end

  defp jacks_modell, do: Worker.Settings.model_for(2, :local)

  @doc """
  Das Modell des Epos-Jack: `Worker.Jack.Pipeline.modell/1` mit
  `modell_name/0` — Endpunkt und Regler wie bei Jack, Fehler ebenso (kein
  Endpunkt, kein Modell).
  """
  @spec modell() :: {:ok, {module(), keyword()}} | {:error, term()}
  def modell, do: Worker.Jack.Pipeline.modell(modell_name())

  @doc """
  Das Kapitel einer Sitzung in der Pipeline: #753-Schutz, dann
  `schreiben_fn.(facts)` (in der Pipeline `schreiben/3`), dann
  `veroeffentlichen/5` mit dem Kapitelkopf aus `eintraege` (die eben
  veröffentlichten Chronik-Einträge der Sitzung). `melde` ist der Rückruf
  fürs Laufband (`Worker.Recording.Pipeline.stufen_melder/3`).

  Best-effort: liefert `{:ok, :chapter_published}`,
  `{:ok, :chapter_skipped_user_edit}` oder `{:error, grund}` — nie ein Raise.
  Fehler meldet der Epos-Jack selbst ans Band; ein Raise (auch beim
  Veröffentlichen) geht hier als Fehlschlag von `"render_epos"` ans Band.
  """
  @spec kapitel(map(), map(), [map()], [map()], ([map()] -> term()), function()) ::
          {:ok, atom()} | {:error, term()}
  def kapitel(session, campaign, facts, eintraege, schreiben_fn, melde) do
    if bearbeitet?(session.id) do
      Logger.info(
        "Pipeline[wahrheitsbild]: Kapitel session=#{session.id} hat GM-Edit — " <>
          "der Epos-Jack schreibt es nicht neu (#753)"
      )

      # Wie früher: die Stufe endet, sie hatte nichts zu tun.
      melde.(@schreiben, :beginn)
      melde.(@schreiben, {:ende, :ok})
      {:ok, :chapter_skipped_user_edit}
    else
      sicher(melde, fn ->
        case schreiben_fn.(facts) do
          {:ok, rendered} ->
            veroeffentlichen(session, campaign, facts, rendered, eintraege)
            {:ok, :chapter_published}

          {:error, _} = fehler ->
            fehler
        end
      end)
    end
  end

  # #753: hat dieses Kapitel (entry_id = session_id) jemals einen manuellen
  # GM-Edit? History-Rows mit source :manual sind der persistente Marker.
  defp bearbeitet?(entry_id),
    do: Worker.Repo.list_epos_history(entry_id) |> Enum.any?(&(&1.source == :manual))

  defp sicher(melde, fun) do
    fun.()
  rescue
    e ->
      grund = {:render_epos, Exception.message(e)}

      Logger.error(
        "Epos-Jack: das Kapitel ist gescheitert, das bisherige bleibt stehen — " <>
          Exception.format(:error, e, __STACKTRACE__)
      )

      melde.(@schreiben, {:ende, {:error, grund}})
      {:error, grund}
  end

  @doc """
  Schreibt das Epos-Kapitel einer Sitzung (Moduledoc) und legt den Stand ab.
  Liefert `{:ok, %{md:, quellen:, zaehlwerte:, notizen:, entwurf:, modell:}}`
  — alles JSON-fähig, `quellen` und `entwurf` mit String-Schlüsseln; `md`
  ist das Kapitel **ohne** Kopf — oder `{:error, grund}`.

  Optionen: `:melde_stufe` (Rückruf fürs Laufband, siehe Moduledoc),
  `:modell` und `:kontext_fenster` (ohne sie `modell/0` bzw.
  `Worker.Jack.Pipeline.kontext_fenster/0`), `:modell_name` (für die
  Herkunft, ohne ihn `modell_name/0`), `:max_runden`, `:max_ms`.
  """
  @spec schreiben(map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def schreiben(session, campaign, opts \\ []) do
    melde = Keyword.get(opts, :melde_stufe, fn _stufe, _ereignis -> :ok end)

    case vorbereiten(session, opts) do
      {:ok, eingabe, modell, fenster} ->
        fahren(session, campaign, eingabe, [modell: modell, kontext_fenster: fenster], opts)

      {:error, _} = fehler ->
        melde.(@schreiben, :beginn)
        melde.(@schreiben, {:ende, fehler})
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
    # Die Laufsicht bekommt Protokoll und Stand, wie beim Resümee-Jack.
    sicht = Process.whereis(Worker.Jack.Sicht)

    lauf_opts =
      (modell_opts ++
         [melde_stufe: opts[:melde_stufe], beobachter: sicht, stand_beobachter: sicht] ++
         Keyword.take(opts, [:max_runden, :max_ms]))
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    with {:ok, r} <- Epos.laufen(eingabe, lauf_opts) do
      ergebnis = ergebnis(r, Keyword.get(opts, :modell_name) || modell_name())
      stand_ablegen(session, campaign, ergebnis)
      {:ok, ergebnis}
    end
  end

  @doc """
  Was aus den drei Läufen herauskommt, JSON-fähig: das Markdown (ohne Kopf),
  die Quellen je Absatz und der Entwurf des letzten gelungenen Laufs
  (Durchsicht, sonst Schreiben), die Zählwerte — bei gescheiterter Durchsicht
  die des Schreibens mit `"durchsicht" => %{"gescheitert" => grund}` —, die
  Notizen des Überblicks (`Worker.Jack.Resuemee.Stand.ablage/1`: FORM,
  SZENEN, ABWEICHUNG, OFFEN) und der Modellname.
  """
  @spec ergebnis(map(), String.t() | nil) :: map()
  def ergebnis(r, modell_name) do
    letzter = letzter_stand(r)

    %{
      md: r.markdown,
      quellen: Enum.map(Ergebnis.quellen(letzter), &mit_texten/1),
      zaehlwerte: zaehlwerte(r),
      notizen: Stand.ablage(r.ueberblick.stand)["notizen"],
      entwurf: Enum.map(letzter.entwurf, &absatz_json/1),
      modell: modell_name
    }
  end

  defp letzter_stand(%{durchsicht: %{stand: s}}), do: s
  defp letzter_stand(%{schreiben: %{stand: s}}), do: s

  defp zaehlwerte(%{durchsicht: %{stand: s}}), do: Ergebnis.zaehlwerte(s)

  defp zaehlwerte(%{schreiben: %{stand: s}, durchsicht: {:error, grund}}),
    do:
      Map.put(Ergebnis.zaehlwerte(s), "durchsicht", %{
        "gescheitert" => inspect(grund, limit: 20)
      })

  defp zaehlwerte(%{schreiben: %{stand: s}}), do: Ergebnis.zaehlwerte(s)

  defp mit_texten(q), do: Map.new(q, fn {k, v} -> {Atom.to_string(k), v} end)

  defp absatz_json(%{titel: t, text: text, szene: szene}),
    do: %{"titel" => t, "text" => text, "szene" => szene}

  # Der Stand als Ereignis: so liest ein Jack späterer Sitzungen die Notizen
  # auf jedem Worker (`vorige_gedanken`). Nur der letzte Stand zählt (LWW im
  # Fold); der Payload reist als Map, kodiert wird im Fold.
  defp stand_ablegen(session, campaign, ergebnis) do
    {:ok, _} =
      Worker.Intents.publish(%{
        "kind" => Shared.Events.jack_epos_stand_abgelegt(),
        "session_id" => session.id,
        "campaign_id" => campaign.id,
        "stand" => %{
          "notizen" => ergebnis.notizen,
          "entwurf" => ergebnis.entwurf,
          "quellen" => ergebnis.quellen,
          "zaehlwerte" => ergebnis.zaehlwerte,
          "modell" => ergebnis.modell,
          "zeitpunkt" => DateTime.to_iso8601(DateTime.utc_now())
        }
      })

    :ok
  end

  @doc """
  Veröffentlicht das Kapitel als `EposEntryEdited` in der bisherigen Form —
  `entry_id` = session_id, `parent_id` = campaign_id (#752) — mit dem
  Kapitelkopf aus `eintraege` vor dem Markdown, `source_refs` (`quellen/2`),
  additiv `quellen` und `zaehlwerte`, `epos_backend: "jack"` und
  `epos_model` als Herkunft. `facts` ist der Bestand der Sitzung (Fakt-Maps
  mit `"id"` und `"source_refs"`); `rendered` das Ergebnis von `schreiben/3`
  — fehlen Quellen, ist `source_refs` leer.

  Ohne `eintraege` (`veroeffentlichen/4`, von Hand) kommt der Kopf aus der
  gespeicherten Chronik dieser Sitzung.
  """
  @spec veroeffentlichen(map(), map(), [map()], map(), [map()] | nil) :: :ok
  def veroeffentlichen(session, campaign, facts, rendered, eintraege \\ nil) do
    quellen = Map.get(rendered, :quellen, [])

    {:ok, _} =
      Worker.Intents.publish(%{
        "kind" => Shared.Events.epos_entry_edited(),
        "entry_id" => session.id,
        "campaign_id" => campaign.id,
        "parent_id" => campaign.id,
        "new_md" => kopf(session, campaign, eintraege) <> "\n\n" <> rendered.md,
        "edited_by" => "llm",
        "source" => "llm",
        "source_refs" => quellen(quellen, facts),
        "quellen" => quellen,
        "zaehlwerte" => Map.get(rendered, :zaehlwerte, %{}),
        "epos_backend" => "jack",
        "epos_model" => Map.get(rendered, :modell)
      })

    :ok
  end

  @doc """
  Der Kapitelkopf (#752): `Render.chapter_header/3` mit dem Kalender der
  Kampagne (#1092, sonst stünde der rohe Tageszähler im Kopf). `nil` statt
  der Einträge heißt: die gespeicherten Chronik-Einträge dieser Sitzung.
  """
  @spec kopf(map(), map(), [map()] | nil) :: String.t()
  def kopf(session, campaign, nil) do
    eintraege =
      campaign.id
      |> Worker.Repo.list_chronik_entries()
      |> Enum.filter(&(&1.session_id == session.id))

    kopf(session, campaign, eintraege)
  end

  def kopf(session, campaign, eintraege),
    do: Render.chapter_header(session, eintraege, Worker.Repo.get_campaign_calendar(campaign.id))

  @doc """
  Die Quellen des Kapitels: die `source_refs` (Block-IDs) aller Fakten aus
  `facts`, deren ID ein Absatz in `quellen` (`"fakt_ids"`) nennt — dieselbe
  Regel wie beim Resümee (`Worker.Jack.Resuemee.Pipeline.quellen/2`), nur je
  Absatz statt je Satz. Fakten früherer Sitzungen stehen nicht in `facts` und
  tragen nichts bei, ein Absatz ohne Szene hat keine `fakt_ids`.
  """
  @spec quellen([map()], [map()]) :: [String.t()]
  defdelegate quellen(quellen, facts), to: Worker.Jack.Resuemee.Pipeline
end
