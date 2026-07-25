defmodule Worker.Repo.Nachlese do
  @moduledoc """
  Issue #907 (Epic #900 S4): der Nachlese-Reader — die erste REINE Ableitung
  der Wahrheitsbasis für den #687-Gründungs-Use-Case: ein Spieler liest nach,
  ohne dass der SL arbeitet. Rein lesend, deterministisch, kein LLM.

  Vier Blöcke, alle Wire-flach (Strings/Ints/nil/bool + String-Listen):

    * `recap`  — das Resümee der LETZTEN Session mit Resümee (Summaries sind
      number-sortiert) + Session-Label; nil = ehrlicher Empty-State.
    * `boegen` — %{offen, geschlossen}: arc-kind-Stränge (Reuse
      `campaign_threads/1` — Merge-Redirect/Overrides/Leitfragen gratis),
      offen aktiv-zuerst sortiert (:offen vor :ruhend, dann jüngste zuerst).
    * `themen` — context-Stränge (Codex, sekundär). rauschen erscheint NIE.
    * `who`    — Figuren-Karteikarten, deterministisch aus den verifizierten
      Fakten aggregiert (entity_id-Gruppierung, Fallback normalisierter
      Alias). `pc?` = Anzeige-Alias entspricht einem Member-Figurennamen
      (benannte Heuristik — es gibt KEIN NPC-Feld in den Daten).
  """

  import Worker.Repo,
    only: [
      list_campaign_facts: 1,
      list_sessions: 1,
      list_session_summaries: 1,
      character_names_for: 1,
      campaign_threads: 1,
      get_thread_registry: 1
    ]

  @doc "Alle Nachlese-Blöcke einer Kampagne (rein lesend, deterministisch)."
  @spec campaign_nachlese(String.t()) :: map()
  def campaign_nachlese(campaign_id) when is_binary(campaign_id) do
    sessions = list_sessions(campaign_id)
    session_number = Map.new(sessions, &{&1.id, &1.number})
    threads = campaign_threads(campaign_id)

    %{
      recap: recap(campaign_id, sessions),
      boegen: boegen(threads),
      themen: themen(threads),
      who: who(campaign_id, session_number)
    }
  end

  # ─── Recap ───────────────────────────────────────────────────────

  # Summaries kommen number-sortiert (list_session_summaries) → List.last
  # ist die jüngste Session MIT Resümee (nicht zwingend die jüngste Session).
  defp recap(campaign_id, sessions) do
    case campaign_id |> list_session_summaries() |> List.last() do
      nil ->
        nil

      s ->
        session = Enum.find(sessions, &(&1.id == s.session_id))

        %{
          content_md: s.content_md,
          flagged_claims: s.flagged_claims,
          session_id: s.session_id,
          session_number: session && session.number,
          session_name: session && session.name
        }
    end
  end

  # ─── Bögen + Themen ──────────────────────────────────────────────

  defp boegen(threads) do
    arcs = Enum.filter(threads, &(&1.kind == "arc" and not &1.dismissed?))

    {geschlossen, offen} = Enum.split_with(arcs, &bogen_geschlossen?/1)

    %{
      offen:
        offen |> Enum.sort_by(&{aktiv_rank(&1), -&1.last_touched_session}) |> Enum.map(&bogen/1),
      geschlossen: Enum.map(geschlossen, &bogen/1)
    }
  end

  # Geschlossen = Arc-Akt sagt geschlossen; arc-lose Stränge (Geburt noch
  # nicht gelaufen) zählen über den Legacy-Status (:aufgelöst).
  defp bogen_geschlossen?(t), do: t.arc_status == "geschlossen" or t.status == :aufgelöst

  defp aktiv_rank(%{status: :offen}), do: 0
  defp aktiv_rank(_ruhend_oder_sonst), do: 1

  defp bogen(t) do
    %{
      titel: t.leitfrage || t.canonical,
      leitfrage_kuratiert?: t.leitfrage_kuratiert?,
      canonical: t.canonical,
      arc_id: t.arc_id,
      arc_grund: t.arc_grund,
      ruht?: t.status == :ruhend,
      fact_count: t.fact_count,
      opened_in_session: t.opened_in_session,
      last_touched_session: t.last_touched_session,
      entities: t.entities
    }
  end

  defp themen(threads) do
    threads
    |> Enum.filter(&(&1.kind == "context" and not &1.dismissed?))
    |> Enum.map(fn t ->
      %{
        titel: t.canonical,
        fact_count: t.fact_count,
        last_touched_session: t.last_touched_session
      }
    end)
  end

  # ─── Who's-who ───────────────────────────────────────────────────

  defp who(campaign_id, session_number) do
    cluster_map = get_thread_registry(campaign_id)

    pc_aliase =
      campaign_id
      |> character_names_for()
      |> Map.values()
      |> Enum.map(&Worker.ThreadOverride.normalize/1)
      |> MapSet.new()

    campaign_id
    |> list_campaign_facts()
    |> Enum.filter(fn f ->
      Map.get(f, "verified?") == true and Map.get(f, "review_dismissed") != true
    end)
    |> Enum.group_by(&who_key/1)
    |> Enum.reject(fn {key, _} -> key == "" end)
    |> Enum.map(fn {_key, group} ->
      anzeige =
        group
        |> Enum.map(&Map.get(&1, "character_alias", ""))
        |> Enum.find("", &(is_binary(&1) and &1 != ""))

      %{
        alias: anzeige,
        pc?: MapSet.member?(pc_aliase, Worker.ThreadOverride.normalize(anzeige)),
        fact_count: length(group),
        threads: who_threads(group, cluster_map),
        last_session:
          group
          |> Enum.map(&Map.get(session_number, &1["session_id"]))
          |> Enum.filter(&is_integer/1)
          |> Enum.max(fn -> 0 end)
      }
    end)
    |> Enum.reject(&(&1.alias == ""))
    |> Enum.sort_by(&{if(&1.pc?, do: 0, else: 1), -&1.fact_count, &1.alias})
  end

  # Kanonische Identität: entity_id (Registry-Merge) vor rohem Alias.
  defp who_key(f) do
    case Map.get(f, "entity_id", "") do
      eid when is_binary(eid) and eid != "" -> eid
      _ -> f |> Map.get("character_alias", "") |> Worker.ThreadOverride.normalize()
    end
  end

  # Strang-Labels der Figur, über die Cluster-Map kanonisiert (dieselbe
  # Normalisierung wie der Thread-Reader — single-sourced).
  defp who_threads(group, cluster_map) do
    group
    |> Enum.map(fn f -> f |> Map.get("thread", "") |> to_string() |> String.trim() end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(fn raw ->
      Map.get(cluster_map, Worker.ThreadOverride.normalize(raw), raw)
    end)
    |> Enum.uniq()
  end
end
