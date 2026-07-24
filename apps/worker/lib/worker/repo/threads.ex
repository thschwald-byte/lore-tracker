defmodule Worker.Repo.Threads do
  @moduledoc """
  Issues #832/#833/#885/#901 (Epics #829/#900): Read-Pfad der Handlungsbogen-
  Welt — Cluster-Map + Kind-Klassifikation (`worker_thread_registry`) und der
  deterministische Strang-Reader `campaign_threads/1` inkl. Member-Kurations-
  Overlay (#836). Ausgelagert aus `Worker.Repo.Artifacts` (God-Module-Grenze,
  beim #901-Schnitt); Call-Sites bleiben `Worker.Repo.x()` (Façade-defdelegate).
  """

  alias Worker.Schema.Mnesia, as: S

  import Worker.Repo, only: [transaction: 1, list_sessions: 1, list_campaign_facts: 1]

  # Issue #832 (Epic #829 Slice C): die Handlungsbogen-Cluster-Map der Campaign
  # (eigene Tabelle @thread_registry). Fehlende Row ODER kaputtes JSON → leere
  # Map (Boundary-Defense, nie crashen) → der Reader fällt auf die Roh-Labels
  # zurück (kein Clustering ist besser als ein Crash). Map = `%{normalisiertes_
  # roh_label => kanonisches Anzeige-Label}`.
  #
  # #885: der Blob ist seit dem Arc/Context-Umbau ein Envelope
  # `%{"map" => cluster_map, "kinds" => kinds}`; Alt-Rows (vor #885) sind die
  # plain Cluster-Map. `decode_registry_blob/1` erkennt beide Formen.
  @doc "Handlungsbogen-Cluster-Map der Campaign; leere Map bei Miss/kaputtem JSON."
  @spec get_thread_registry(String.t()) :: %{optional(String.t()) => String.t()}
  def get_thread_registry(campaign_id) when is_binary(campaign_id) do
    campaign_id |> registry_blob() |> decode_registry_blob() |> elem(0)
  end

  @doc """
  Issues #885/#901: Kind-Klassifikation der Kanon-Stränge
  (`%{normalisiertes_canonical => "arc" | "context" | "rauschen"}`). Leere Map
  bei Miss/Alt-Row/kaputtem JSON — jeder nicht klassifizierte Strang gilt am
  Reader als `"arc"` (fail-safe: bleibt im Fäden-Panel sichtbar).
  """
  @spec get_thread_kinds(String.t()) :: %{optional(String.t()) => String.t()}
  def get_thread_kinds(campaign_id) when is_binary(campaign_id) do
    campaign_id |> registry_blob() |> decode_registry_blob() |> elem(1)
  end

  defp registry_blob(campaign_id) do
    case transaction(fn -> :mnesia.read(S.thread_registry(), campaign_id) end) do
      [{_tbl, _cid, json, _updated_at}] when is_binary(json) -> json
      _ -> nil
    end
  end

  defp decode_registry_blob(nil), do: {%{}, %{}}

  defp decode_registry_blob(json) do
    case Jason.decode(json) do
      {:ok, %{"map" => map} = envelope} when is_map(map) ->
        kinds = if is_map(envelope["kinds"]), do: envelope["kinds"], else: %{}
        {map, kinds}

      # Alt-Row (vor #885): plain Cluster-Map, keine Klassifikation.
      {:ok, map} when is_map(map) ->
        {map, %{}}

      _ ->
        {%{}, %{}}
    end
  end

  # Issue #833 (Epic #829 Slice D1): deterministischer Handlungsbogen-Reader.
  # Gruppiert die VERIFIZIERTEN Fakten einer Kampagne über die ThreadRegistry-
  # Cluster-Map (#832) zu kanonischen Strängen, leitet pro Strang Status +
  # Metadaten ab. REIN LESEND (kein LLM, kein Event) — der #687-Recall-Kern.
  #
  # Status: `:offen` (Default) | `:ruhend` (seit ≥ `thread_dormant_after_sessions`
  # nachfolgenden Sessions kein neuer Fakt). Ein `fact_type == "auflösung"`-Fakt
  # setzt NUR das `resolution_suggested?`-Flag (möglicher Abschluss) — NIE einen
  # Auto-Übergang auf „aufgelöst"; das entscheidet der GM (Slice D2-Override).
  #
  # Konsumiert nur `verified? == true` + nicht-dauerhaft-ausgeblendete Fakten mit
  # nicht-leerem `thread`-Label. Ohne ThreadRegistry (noch nicht geclustert)
  # fällt jedes Roh-Label auf sich selbst zurück (fragmentiert-aber-korrekt).
  # Issue #836 (Slice D2): das Member-Kurations-Overlay wird HIER am Read
  # eingemischt — `merge` beim Gruppieren (Fakten in den Ziel-Strang umleiten),
  # `rename`/`resolve`/`dismiss` beim Bauen. Die Fakten selbst bleiben unangetastet.
  @doc "Handlungsstränge der Kampagne, gruppiert + Status-abgeleitet + kuratiert (rein lesend)."
  @spec campaign_threads(String.t()) :: [map()]
  def campaign_threads(campaign_id) when is_binary(campaign_id) do
    facts =
      campaign_id
      |> list_campaign_facts()
      |> Enum.filter(fn f ->
        Map.get(f, "verified?") == true and Map.get(f, "review_dismissed") != true and
          thread_label(f) != ""
      end)

    {cluster_map, kinds} = campaign_id |> registry_blob() |> decode_registry_blob()
    {identity_ov, lifecycle_ov, kind_ov} = thread_overrides_for(campaign_id)
    sessions = list_sessions(campaign_id)
    session_number = Map.new(sessions, fn s -> {s.id, s.number} end)
    dormant_after = Worker.Settings.get(:thread_dormant_after_sessions, 3)

    facts
    |> Enum.group_by(fn f -> merged_canonical(canonical_thread(f, cluster_map), identity_ov) end)
    |> Enum.map(fn {canonical, group} ->
      build_thread(
        canonical,
        group,
        sessions,
        session_number,
        dormant_after,
        identity_ov,
        lifecycle_ov,
        kinds,
        kind_ov
      )
    end)
    |> Enum.sort_by(fn t ->
      # #885/#901: Arcs vor Contexten vor Rauschen — das Panel listet Fäden
      # zuerst, Themen darunter, Rauschen ganz unten (zugeklapptes Register).
      {kind_rank(t.kind), if(t.dismissed?, do: 1, else: 0), status_rank(t.status),
       -t.last_touched_session, -t.fact_count}
    end)
  end

  # `merge`-Override: ein Strang wird beim Gruppieren in einen Ziel-Strang
  # umgeleitet (heilt 7b-Fragmentierung). Ein-Level (keine Merge-Ketten).
  defp merged_canonical(base, identity_ov) do
    case Map.get(identity_ov, Worker.ThreadOverride.normalize(base)) do
      %{action: "merge", merge_into: target} when is_binary(target) and target != "" -> target
      _ -> base
    end
  end

  # Liest das Kurations-Overlay einer Kampagne in drei Maps (nach Dimension:
  # identity / lifecycle / kind, #885), je
  # `%{normalisiertes_canonical => %{action, new_name, merge_into}}`.
  defp thread_overrides_for(campaign_id) do
    rows =
      transaction(fn -> :mnesia.index_read(S.thread_overrides(), campaign_id, :campaign_id) end)

    Enum.reduce(rows, {%{}, %{}, %{}}, fn
      {_tbl, _key, _cid, canonical, dimension, action, new_name, merge_into, _event_id},
      {id_acc, life_acc, kind_acc} ->
        entry = %{action: action, new_name: new_name, merge_into: merge_into}
        norm = Worker.ThreadOverride.normalize(canonical)

        case dimension do
          "identity" -> {Map.put(id_acc, norm, entry), life_acc, kind_acc}
          "lifecycle" -> {id_acc, Map.put(life_acc, norm, entry), kind_acc}
          "kind" -> {id_acc, life_acc, Map.put(kind_acc, norm, entry)}
          _ -> {id_acc, life_acc, kind_acc}
        end
    end)
  end

  defp build_thread(
         canonical,
         group,
         sessions,
         session_number,
         dormant_after,
         identity_ov,
         lifecycle_ov,
         kinds,
         kind_ov
       ) do
    numbers =
      group
      |> Enum.map(fn f -> Map.get(session_number, f["session_id"]) end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.sort()

    last_touched = List.last(numbers) || 0
    # „Ruhend" an der Zahl NACHFOLGENDER Sessions festmachen (robust gegen
    # gelöschte/nicht-fortlaufende Session-Nummern), nicht am reinen Nummern-Delta.
    later_sessions = Enum.count(sessions, fn s -> s.number > last_touched end)
    base_status = if later_sessions >= dormant_after, do: :ruhend, else: :offen

    norm = Worker.ThreadOverride.normalize(canonical)
    id_ov = Map.get(identity_ov, norm)
    life_ov = Map.get(lifecycle_ov, norm)
    k_ov = Map.get(kind_ov, norm)

    # Neutrale Undo-Aktionen (clear_identity/reactivate/clear_kind) zählen als
    # „kein Override".
    identity_action = if id_ov && id_ov.action in ["rename", "merge"], do: id_ov.action
    lifecycle_action = if life_ov && life_ov.action in ["resolve", "dismiss"], do: life_ov.action

    kind_action =
      if k_ov && k_ov.action in ["mark_arc", "mark_context", "mark_rauschen"], do: k_ov.action

    # #885/#901: Member-Override > LLM-Klassifikation > "arc" (fail-safe
    # Default — ein unklassifizierter ODER unbekannt-klassifizierter Strang
    # bleibt im Fäden-Panel sichtbar, statt still zu verschwinden; die
    # kinds-Map aus dem Snapshot wird deshalb hier nochmal gewhitelistet).
    kind =
      case kind_action do
        "mark_arc" ->
          "arc"

        "mark_context" ->
          "context"

        "mark_rauschen" ->
          "rauschen"

        nil ->
          case Map.get(kinds, norm) do
            k when k in ["context", "rauschen"] -> k
            _ -> "arc"
          end
      end

    display =
      if identity_action == "rename" and is_binary(id_ov.new_name) and id_ov.new_name != "",
        do: id_ov.new_name,
        else: canonical

    status =
      cond do
        lifecycle_action == "resolve" -> :aufgelöst
        true -> base_status
      end

    %{
      # Anzeige-Label (umbenannt, falls rename-Override).
      canonical: display,
      # Original-Label — DAS schickt der Panel-Button zurück (Overrides sind darauf
      # geschlüsselt, nicht auf dem umbenannten Anzeige-Label).
      key_canonical: canonical,
      # #885/#901: "arc" (Handlungsbogen) | "context" (zeitloses Weltwissen)
      # | "rauschen" (Meta-/Tisch-Gerede — fällt aus den inhaltlichen Sichten).
      kind: kind,
      status: status,
      dismissed?: lifecycle_action == "dismiss",
      curated?: identity_action != nil or lifecycle_action != nil or kind_action != nil,
      identity_action: identity_action,
      lifecycle_action: lifecycle_action,
      kind_action: kind_action,
      resolution_suggested?: Enum.any?(group, fn f -> fact_type(f) == "auflösung" end),
      fact_count: length(group),
      opened_in_session: List.first(numbers) || 0,
      last_touched_session: last_touched,
      sessions_touched: numbers,
      entities:
        group
        |> Enum.map(fn f ->
          f |> Map.get("character_alias", "") |> to_string() |> String.trim()
        end)
        |> Enum.reject(&(&1 == ""))
        |> Enum.uniq(),
      facts: group
    }
  end

  defp thread_label(f), do: f |> Map.get("thread", "") |> to_string() |> String.trim()

  defp fact_type(f),
    do: f |> Map.get("fact_type", "") |> to_string() |> String.trim() |> String.downcase()

  # Roh-Label über die Cluster-Map auf den Kanon ziehen; nicht gemappt → Roh-Label
  # (Fallback vor/ohne Clustering). Normalisierung konsistent mit ThreadRegistry.
  defp canonical_thread(f, cluster_map) do
    raw = thread_label(f)
    key = raw |> String.downcase() |> String.replace(~r/\s+/u, " ") |> String.trim()
    Map.get(cluster_map, key, raw)
  end

  # „offen" vor „ruhend" vor „aufgelöst" in der Sortierung (aktive Fäden zuerst).
  defp status_rank(:offen), do: 0
  defp status_rank(:ruhend), do: 1
  defp status_rank(:aufgelöst), do: 2

  # #901: Panel-Reihenfolge der kinds (build_thread whitelistet auf genau
  # diese drei Werte; der Catch-all hält den Sort robust).
  defp kind_rank("arc"), do: 0
  defp kind_rank("context"), do: 1
  defp kind_rank("rauschen"), do: 2
  defp kind_rank(_), do: 0
end
