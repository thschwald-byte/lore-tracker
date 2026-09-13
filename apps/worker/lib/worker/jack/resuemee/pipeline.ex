defmodule Worker.Jack.Resuemee.Pipeline do
  @moduledoc """
  Der Resümee-Jack in der Pipeline (J5, #1209, B4): er schreibt das Resümee
  jeder Sitzung, an der Stelle des früheren Render-Resümees
  (`Worker.Recording.Pipeline.run_wahrheitsbild/4`, Stufe `"render"`). Chronik
  und Bogen-Progressionen bleiben, wie sie sind; das Epos-Kapitel schreibt seit
  J6 (#1210, E4) der Epos-Jack (`Worker.Jack.Epos.Pipeline`), der aus dem hier
  abgelegten Stand den Weg der Gruppe übernimmt.

  **Ablauf** (`schreiben/3`): Eingabe aus dem Repo
  (`Worker.Jack.Resuemee.Eingabe.aus_repo/1`), dann die drei Läufe
  (`Worker.Jack.Resuemee.laufen/2`: Überblick → Schreiben → Durchsicht), dann
  der Stand als `JackResuemeeStandAbgelegt` (`stand_ablegen/3`). Das
  Resümee selbst veröffentlicht die Pipeline danach über `veroeffentlichen/4`.
  **Kein Rückfall auf den alten Render:** scheitern Überblick oder Schreiben,
  gibt es für diesen Lauf kein neues Resümee, und die Stufe meldet es in
  `/admin/errors`. Scheitert nur die Durchsicht, gilt der Entwurf aus dem
  Schreiben (`Worker.Jack.Resuemee.laufen/2`); ihr Fehlschlag steht trotzdem
  in `/admin/errors` (Klasse `resuemee_durchsicht_gescheitert`).

  **Laufband:** die drei Läufe sind drei Stufen (`Shared.PipelineStufen`:
  `resuemee_ueberblick`, `render`, `resuemee_durchsicht`), gemeldet über den
  Rückruf `:melde_stufe` wie beim Fakten-Jack. Ein Fehler vor den Läufen —
  Modell, Kontextfenster, Eingabe — erscheint als Fehlschlag von `"render"`,
  der Stufe, unter der das Resümee schon immer lief.

  **Modell** (`modell/0`): dasselbe wie Jack — Endpunkt, Sampling-Regler und
  Kontextfenster aus Jacks Einstellungen —, aber eigens wählbar über
  `resuemee_jack_model`; leer heißt Jacks Modell (`model_stage2_local`).

  **Quellen genau statt pauschal** (`quellen/2`): `source_refs` des Resümees
  ist die Vereinigung der Block-Belege der Fakten dieser Sitzung, die ein Satz
  zitiert — nicht mehr die aller Fakten. Der Worker löst die Block-IDs für
  Sprungmarken, Sync-Index und 🕳-Marker auf wie bisher
  (`Worker.Repo.GlattQuellen`); ein Rückblick-Satz, der nur Fakten früherer
  Sitzungen nennt, trägt nichts bei — er zeigt nicht auf den Mitschnitt
  dieser Sitzung.
  """

  alias Worker.Jack.Resuemee
  alias Worker.Jack.Resuemee.{Eingabe, Ergebnis, Stand}

  @schreiben "render"

  @doc """
  Der Modellname des Resümee-Jack: `resuemee_jack_model`, wenn gesetzt und
  nicht leer, sonst Jacks Modell (`model_stage2_local`). Kann `nil` sein —
  dann scheitert `modell/0` laut.
  """
  @spec modell_name() :: String.t() | nil
  def modell_name do
    case Worker.Settings.get(:resuemee_jack_model) do
      name when is_binary(name) ->
        if String.trim(name) == "", do: jacks_modell(), else: String.trim(name)

      _ ->
        jacks_modell()
    end
  end

  defp jacks_modell, do: Worker.Settings.model_for(2, :local)

  @doc """
  Das Modell des Resümee-Jack: `Worker.Jack.Pipeline.modell/1` mit
  `modell_name/0` — Endpunkt und Regler wie bei Jack, Fehler ebenso (kein
  Endpunkt, kein Modell).
  """
  @spec modell() :: {:ok, {module(), keyword()}} | {:error, term()}
  def modell, do: Worker.Jack.Pipeline.modell(modell_name())

  @doc """
  Schreibt das Resümee einer Sitzung (Moduledoc) und legt den Stand ab.
  Liefert `{:ok, %{md:, satzquellen:, zaehlwerte:, notizen:, entwurf:,
  modell:}}` — alles JSON-fähig, `satzquellen` und `entwurf` mit
  String-Schlüsseln — oder `{:error, grund}`.

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
    # Die Laufsicht bekommt Protokoll und Stand, wie beim Fakten-Jack.
    sicht = Process.whereis(Worker.Jack.Sicht)

    lauf_opts =
      modell_opts ++
        [melde_stufe: opts[:melde_stufe], beobachter: sicht, stand_beobachter: sicht] ++
        Keyword.take(opts, [:max_runden, :max_ms])

    lauf_opts = Enum.reject(lauf_opts, fn {_k, v} -> is_nil(v) end)

    with {:ok, r} <- Resuemee.laufen(eingabe, lauf_opts) do
      ergebnis = ergebnis(r, Keyword.get(opts, :modell_name) || modell_name())
      stand_ablegen(session, campaign, ergebnis)
      {:ok, ergebnis}
    end
  end

  @doc """
  Was aus den drei Läufen herauskommt, JSON-fähig: das Markdown, die
  Satzquellen und der Entwurf des letzten gelungenen Laufs (Durchsicht, sonst
  Schreiben), die Zählwerte — bei gescheiterter Durchsicht die des Schreibens
  mit `"durchsicht" => %{"gescheitert" => grund}` —, die Notizen des
  Überblicks (`Worker.Jack.Resuemee.Stand.ablage/1`) und der Modellname.
  """
  @spec ergebnis(map(), String.t() | nil) :: map()
  def ergebnis(r, modell_name) do
    letzter = letzter_stand(r)

    %{
      md: r.markdown,
      satzquellen: Enum.map(Ergebnis.satzquellen(letzter), &mit_texten/1),
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

  defp absatz_json(%{titel: t, saetze: saetze}),
    do: %{
      "titel" => t,
      "saetze" =>
        Enum.map(saetze, fn s ->
          %{
            "text" => s.text,
            "fakten" => s.fakten,
            "uebergang" => s.uebergang,
            "rueckblick" => s.rueckblick
          }
        end)
    }

  # Der Stand als Ereignis: so liest der Resümee-Jack späterer Sitzungen die
  # Notizen auf jedem Worker (`Eingabe.vorige_gedanken`). Nur der letzte Stand
  # zählt (LWW im Fold); der Payload reist als Map, kodiert wird im Fold.
  defp stand_ablegen(session, campaign, ergebnis) do
    {:ok, _} =
      Worker.Intents.publish(%{
        "kind" => Shared.Events.jack_resuemee_stand_abgelegt(),
        "session_id" => session.id,
        "campaign_id" => campaign.id,
        "stand" => %{
          "notizen" => ergebnis.notizen,
          "entwurf" => ergebnis.entwurf,
          "satzquellen" => ergebnis.satzquellen,
          "zaehlwerte" => ergebnis.zaehlwerte,
          "modell" => ergebnis.modell,
          "zeitpunkt" => DateTime.to_iso8601(DateTime.utc_now())
        }
      })

    :ok
  end

  @doc """
  Veröffentlicht das Resümee als `SessionSummaryGenerated`: `content_md`,
  `source_refs` (`quellen/2`), additiv `satzquellen` und `zaehlwerte`,
  `render_backend: "jack"` und `render_model` als Herkunft. `facts` ist der
  Bestand der Sitzung (Fakt-Maps mit `"id"` und `"source_refs"`); `rendered`
  das Ergebnis von `schreiben/3` — fehlen Satzquellen, ist `source_refs` leer.
  """
  @spec veroeffentlichen(map(), map(), [map()], map()) :: :ok
  def veroeffentlichen(session, campaign, facts, rendered) do
    satzquellen = Map.get(rendered, :satzquellen, [])

    {:ok, _} =
      Worker.Intents.publish(%{
        "kind" => Shared.Events.session_summary_generated(),
        "session_id" => session.id,
        "campaign_id" => campaign.id,
        "content_md" => rendered.md,
        "source" => "llm",
        "source_refs" => quellen(satzquellen, facts),
        "satzquellen" => satzquellen,
        "zaehlwerte" => Map.get(rendered, :zaehlwerte, %{}),
        "render_backend" => "jack",
        "render_model" => Map.get(rendered, :modell)
      })

    :ok
  end

  @doc """
  Die Quellen des Resümees: die `source_refs` (Block-IDs) aller Fakten aus
  `facts`, deren ID ein Satz in `satzquellen` (`"fakt_ids"`) nennt, in der
  Reihenfolge der Fakten, ohne Doppelte. Fakten früherer Sitzungen stehen
  nicht in `facts` und tragen deshalb nichts bei.
  """
  @spec quellen([map()], [map()]) :: [String.t()]
  def quellen(satzquellen, facts) do
    zitiert = for q <- satzquellen, id <- List.wrap(q["fakt_ids"]), into: MapSet.new(), do: id

    facts
    |> Enum.filter(&MapSet.member?(zitiert, &1["id"]))
    |> Enum.flat_map(&List.wrap(&1["source_refs"]))
    |> Enum.uniq()
  end
end
