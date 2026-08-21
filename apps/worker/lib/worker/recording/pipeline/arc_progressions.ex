defmodule Worker.Recording.Pipeline.ArcProgressions do
  @moduledoc """
  Issue #838: Prosa-Progression — EIN Eintrag pro (Bogen × Session), NIE
  überschrieben. Ausgelagert aus `Worker.Recording.Pipeline` (God-Module-
  Grenze #544, Präzedenz #791) — läuft als best-effort-Geschwister im
  Wahrheitsbild-Lauf (`Pipeline.run_wahrheitsbild/4`, nach Verify),
  pro-Bogen-Fehlerisolierung INNERHALB des Schritts (Design J: ein
  fehlschlagender Bogen darf weder andere Bögen noch den Rest der Pipeline
  mitreißen).
  """

  require Logger

  alias Worker.Recording.Pipeline.Fortschritt
  alias Worker.Recording.Pipeline

  @doc """
  `render_fn.(canonical, prior_entry, new_facts, gate_facts)` ist
  injizierbar (deps-Muster, s. `Pipeline.run_wahrheitsbild/4`). Läuft leer
  durch (kein Fehler), wenn keine Fakten dieser Session einem Bogen
  zugeordnet sind (`touched` leer).
  """
  @spec publish(map(), map(), fun()) :: :ok
  def publish(session, campaign, render_fn) do
    touched = Worker.Repo.touched_arcs_for_session(campaign.id, session.number)

    if map_size(touched) > 0 do
      # EIN campaign_threads/1-Scan für alle Canonical-Titel/opened_in_session
      # dieses Laufs statt N Einzel-Lookups (akzeptierter Mehrfach-Scan-
      # Trade-off gegenüber touched_arcs_for_session/arc_fact_claims, s.
      # #838-Plan Risiken — Konsistenz mit dem Rest der Pipeline).
      arc_meta =
        campaign.id
        |> Worker.Repo.campaign_threads()
        |> Enum.filter(& &1.arc_id)
        |> Map.new(
          &{&1.arc_id, %{canonical: &1.canonical, opened_in_session: &1.opened_in_session}}
        )

      # Issue #1122: ein LLM-Aufruf je berührtem Bogen — zählbar, und bei vielen
      # Bögen der Grund, warum diese Stufe nicht „gleich fertig" ist.
      ctx = %{session_id: session.id}
      Fortschritt.gesamt(ctx, "render_arc_progressions", Enum.count(touched))

      touched
      |> Enum.with_index(1)
      |> Enum.each(fn {{arc_id, touched_facts}, idx} ->
        render_one(session, campaign, arc_id, touched_facts, arc_meta, render_fn)
        Fortschritt.fertig(ctx, "render_arc_progressions", idx)
      end)
    end

    :ok
  end

  # Ein Bogen ohne arc_meta-Eintrag (z.B. gerade erst gemerged/verwaist
  # zwischen resolve_threads und hier) wird still übersprungen — kein Fehler,
  # kein Render (der nächste Lauf holt ihn nach, sobald wieder gepaart).
  defp render_one(_session, _campaign, arc_id, _touched_facts, arc_meta, _render_fn)
       when not is_map_key(arc_meta, arc_id) do
    :ok
  end

  defp render_one(session, campaign, arc_id, touched_facts, arc_meta, render_fn) do
    %{canonical: canonical, opened_in_session: opened_in_session} = Map.fetch!(arc_meta, arc_id)

    prior_entry = Worker.Repo.get_prior_arc_entry(campaign.id, arc_id, session.number)

    # Design F: Backfill — ein Bestandsbogen bekommt seinen ersten Eintrag
    # NACH dem Feature-Rollout; ohne diesen Fall würde Fall A nur die
    # Session-Delta-Fakten sehen und die Vorgeschichte fehlte dauerhaft.
    new_facts =
      if prior_entry == nil and opened_in_session < session.number do
        campaign.id |> Worker.Repo.arc_fact_claims(arc_id) |> Enum.map(&%{"claim" => &1})
      else
        Enum.map(touched_facts, &%{"claim" => &1.claim})
      end

    # Design H: Gate-Korpus ist IMMER die volle Arc-Historie, unabhängig
    # vom Prompt-Input.
    gate_facts = campaign.id |> Worker.Repo.arc_fact_claims(arc_id) |> Enum.map(&%{"claim" => &1})

    try do
      case render_fn.(canonical, prior_entry, new_facts, gate_facts) do
        {:ok, rendered} ->
          publish_event(session, campaign, arc_id, rendered)

        {:error, reason} ->
          log_error(campaign.id, session.id, arc_id, reason)
      end
    rescue
      e -> log_error(campaign.id, session.id, arc_id, Exception.message(e))
    end

    :ok
  end

  defp publish_event(session, campaign, arc_id, rendered) do
    if rendered.flagged != [] do
      Logger.warning(
        "Pipeline[wahrheitsbild]: #{length(rendered.flagged)} ungeerdete Progressions-Claims " <>
          "geflaggt (session=#{session.id} arc=#{arc_id}): #{inspect(rendered.flagged)}"
      )
    end

    # Provenance-Stempel, #783-Phase-2-Muster (wie publish_wahrheitsbild_summary).
    render_backend = Worker.Settings.get(:backend_stage4, :local)

    {:ok, _} =
      Worker.Intents.publish(%{
        "kind" => Shared.Events.arc_progression_generated(),
        "campaign_id" => campaign.id,
        "arc_id" => arc_id,
        "session_id" => session.id,
        "session_number" => session.number,
        "content_md" => rendered.md,
        "flagged_claims" => rendered.flagged,
        "render_backend" => Atom.to_string(render_backend),
        "render_model" => Worker.Settings.model_for(4, render_backend)
      })

    :ok
  end

  defp log_error(campaign_id, session_id, arc_id, reason) do
    Logger.warning(
      "Pipeline[wahrheitsbild]: Prosa-Progression fehlgeschlagen " <>
        "(campaign=#{campaign_id} arc=#{arc_id}): #{inspect(reason)}"
    )

    Pipeline.publish_pipeline_error(
      campaign_id,
      "render_arc_progressions",
      session_id,
      {:render_arc_progressions, reason},
      "Bogen #{arc_id}: #{inspect(reason)}"
    )
  end
end
