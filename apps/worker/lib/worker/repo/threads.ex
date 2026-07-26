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

  # #909 (Epic #900 S5): die EINE kind-Präzedenz-Ableitung — Member-Override >
  # LLM-Klassifikation (Whitelist `context`/`rauschen`) > `"arc"` (fail-safe:
  # unklassifiziert/unbekannt bleibt sichtbarer Handlungsbogen). Geteilt
  # zwischen dem Fäden-Panel (`build_thread`) und der Render-Gruppierung
  # (`fact_render_assignments`), damit Recap/Epos exakt dieselbe
  # Klassifikation sehen wie das Panel. Rückgabe `{kind, kind_action}` — der
  # Panel-Reader braucht auch die rohe Action (`curated?`); neutrale
  # Undo-Aktionen (`clear_kind`) zählen als kein Override.
  @doc "kind-Präzedenz: Override > kinds-Whitelist > \"arc\"; liefert {kind, kind_action}."
  @spec effective_kind(String.t(), map(), map()) :: {String.t(), String.t() | nil}
  def effective_kind(norm, kinds, kind_ov)
      when is_binary(norm) and is_map(kinds) and is_map(kind_ov) do
    k_ov = Map.get(kind_ov, norm)

    kind_action =
      if k_ov && k_ov.action in ["mark_arc", "mark_context", "mark_rauschen"], do: k_ov.action

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

    {kind, kind_action}
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
  def campaign_threads(campaign_id) when is_binary(campaign_id),
    do: campaign_threads_with_review(campaign_id).threads

  @doc """
  #905 (Epic #900 S3): Threads + Arc-Review in EINEM Fakten-Durchlauf.
  `arc_review` = %{verwaiste: […], gemergte: […]} — verwaiste = sichtbare
  (un-gemergte) Arcs ohne paarenden Thread (inkl. Merge-Vorschlag über
  Seed-Überlapp = Duplikat-Hinweis); gemergte = ROHE merged_into-Persistenz
  (auch wirkungslose Zyklen/Ketten — sonst gesetzt-aber-unsichtbar).
  Ehrliche Grenze: die Listen „atmen" im Verify-Fenster (der Reader
  konsumiert nur verified? — dieselbe Klasse wie das ganze Panel; die
  Aktionen sind LWW-Events, transiente Orphan-Merges bleiben valide).
  """
  @spec campaign_threads_with_review(String.t()) :: %{threads: [map()], arc_review: map()}
  def campaign_threads_with_review(campaign_id) when is_binary(campaign_id) do
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

    built =
      facts
      |> Enum.group_by(fn f ->
        merged_canonical(canonical_thread(f, cluster_map), identity_ov)
      end)
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

    {enriched, arc_review} = attach_arcs(built, campaign_id, session_number)

    threads =
      enriched
      |> Enum.map(&Map.delete(&1, :base_status))
      |> Enum.sort_by(fn t ->
        # #885/#901: Arcs vor Contexten vor Rauschen — das Panel listet Fäden
        # zuerst, Themen darunter, Rauschen ganz unten (zugeklapptes Register).
        {kind_rank(t.kind), if(t.dismissed?, do: 1, else: 0), status_rank(t.status),
         -t.last_touched_session, -t.fact_count}
      end)

    %{threads: threads, arc_review: arc_review}
  end

  # #909 (Epic #900 S5): die Render-Zuordnung Fakt → Bogen für den
  # Arc-strukturierten Recap/Epos-Prompt. Liefert `%{fact_id => %{titel, kind}}`
  # — Fakten ohne Eintrag sind strang-los („Weiteres" im Prompt).
  #
  # KEINE eigene Präzedenz: die Label-Kette (cluster_map → identity-merge →
  # rename-Display → effective_kind) ist in `campaign_threads/1` schon
  # gelaufen; die Fakt-Ebene (FactArcSet-Override > Label-Kette, inkl.
  # Merge-Redirect) reitet in deren `fact_list.effective_arc_id`. Arc →
  # Anzeige nutzt dieselbe Dedup-Konvention wie das Panel-`arc_options`
  # (erster Thread in Panel-Sortierung repräsentiert den Arc). Benannte
  # Kanten: Override auf einen Arc ohne paarenden Thread (Orphan) fällt auf
  # die Label-Gruppe zurück (Leitfrage ist NIE Maschinen-Input, also keine
  # Titel-Quelle); Fakten in rauschen-Strängen haben keine fact_list →
  # Zuordnung kommt aus der Label-Gruppe (kind "rauschen" → Render filtert).
  @doc "Render-Zuordnung Fakt → Bogen (%{fact_id => %{titel, kind}}); ohne Eintrag = strang-los."
  @spec fact_render_assignments(String.t(), [map()]) :: %{optional(String.t()) => map()}
  def fact_render_assignments(campaign_id, facts)
      when is_binary(campaign_id) and is_list(facts) do
    threads = campaign_threads(campaign_id)
    {cluster_map, _kinds} = campaign_id |> registry_blob() |> decode_registry_blob()
    {identity_ov, _lifecycle_ov, _kind_ov} = thread_overrides_for(campaign_id)

    by_key = Map.new(threads, &{&1.key_canonical, &1})

    arc_display =
      threads
      |> Enum.filter(& &1.arc_id)
      |> Enum.uniq_by(& &1.arc_id)
      |> Map.new(&{&1.arc_id, %{titel: &1.canonical, kind: &1.kind}})

    fact_eff =
      for t <- threads, fl <- t.fact_list, into: %{} do
        {fl.id, fl}
      end

    Enum.reduce(facts, %{}, fn f, acc ->
      fid = f["id"]

      base =
        case thread_label(f) do
          "" ->
            nil

          _ ->
            key = merged_canonical(canonical_thread(f, cluster_map), identity_ov)

            case Map.get(by_key, key) do
              nil -> nil
              t -> %{titel: t.canonical, kind: t.kind}
            end
        end

      assigned =
        with %{overridden?: true, effective_arc_id: eff} when is_binary(eff) <-
               Map.get(fact_eff, fid),
             %{} = disp <- Map.get(arc_display, eff) do
          disp
        else
          _ -> base
        end

      if assigned, do: Map.put(acc, fid, assigned), else: acc
    end)
  end

  # ─── Arc-Anreicherung + Status-Ableitung (Epic #900 S2, Issue #903) ──
  #
  # Der Arc-STATUS ist eine PURE Ableitung (nie persistiert): letzter
  # menschlicher Akt (LWW im :arc_act-Fold) + max_fakt_session (Lesezeit-Max
  # über die last_touched_session ALLER auf den Arc gepaarten Threads — pro
  # ARC aggregiert, sonst zeigte derselbe Arc an zwei Threads verschiedene
  # Status). versandet-Gate: offen gdw max_fakt_session > wasserlinie
  # (nil/kaputt → 0, fail-open Richtung sichtbar). geloest reopent NIE
  # automatisch (Folge-Fakten = Nachwirkung).
  #
  # Pairing (S2-minimal): normalisierte Roh-Label-Menge des Threads schneidet
  # die Seed-Labels (Tie-Break: größte Schnittmenge, dann kleinste arc_id —
  # deterministisch). Orphan-Arcs (kein paarender Thread) werden still
  # ignoriert (S3-verwaist-Fläche). Alle angereicherten Felder sind FLACH
  # (Strings/nil/bool) — serialize/1 kennt keine Tupel (#900-Fund A5).
  # #905: Redirect (Ein-Level) + Fakt-Ebene + Review in einem Pass. Pairing
  # läuft über die ROHEN Arcs (die Seeds einer gemergten Quelle beschreiben
  # den Strang weiterhin), danach wird auf den effektiven Arc umgeleitet.
  # max_fakt_session ist seit #905 FAKT-genau: pro Arc das Max über die
  # Sessions seiner EFFEKTIVEN Fakten (Override raus/rein kippt das
  # versandet-Gate präzise).
  defp attach_arcs(threads, campaign_id, session_number) do
    arcs =
      transaction(fn -> :mnesia.index_read(S.arcs(), campaign_id, :campaign_id) end)
      |> Enum.map(fn {_t, id, _cid, seeds, draft, ak, ag, aw, lk, mi} ->
        %{
          id: id,
          seeds: seeds |> List.wrap() |> MapSet.new(),
          draft: draft,
          act: ak,
          grund: ag,
          wl: aw,
          kuratiert: lk,
          merged_into: mi
        }
      end)

    by_id = Map.new(arcs, &{&1.id, &1})

    # Fakt→Arc-Overrides ("" = Undo → zählt als kein Override).
    overrides =
      transaction(fn ->
        :mnesia.index_read(S.fact_arc_overrides(), campaign_id, :campaign_id)
      end)
      |> Enum.reduce(%{}, fn {_t, _k, _cid, fact_id, arc_id, _eid}, acc ->
        if is_binary(arc_id) and arc_id != "", do: Map.put(acc, fact_id, arc_id), else: acc
      end)

    pairs =
      Enum.map(threads, fn t ->
        labels = thread_label_set(t)

        best =
          arcs
          |> Enum.map(fn a -> {a, MapSet.size(MapSet.intersection(a.seeds, labels))} end)
          |> Enum.filter(fn {_a, n} -> n > 0 end)
          |> Enum.sort_by(fn {a, n} -> {-n, a.id} end)
          |> List.first()

        {t, best && effective_arc(elem(best, 0), by_id)}
      end)

    # Effektive Fakt-Zuordnung: Override (Ziel existiert → Redirect angewandt)
    # sonst der effektive Arc des Threads.
    fact_assignments =
      for {t, thread_arc} <- pairs, fact <- t.facts do
        eff =
          case Map.get(overrides, fact["id"]) do
            nil ->
              thread_arc

            ov_target ->
              case Map.get(by_id, ov_target) do
                nil -> thread_arc
                a -> effective_arc(a, by_id)
              end
          end

        {fact, eff, Map.get(session_number, fact["session_id"])}
      end

    max_fakt_session_by_arc =
      fact_assignments
      |> Enum.filter(fn {_f, eff, sn} -> eff != nil and is_integer(sn) end)
      |> Enum.group_by(fn {_f, eff, _sn} -> eff.id end, fn {_f, _e, sn} -> sn end)
      |> Map.new(fn {arc_id, sns} -> {arc_id, Enum.max(sns)} end)

    fact_eff_by_id =
      Map.new(fact_assignments, fn {f, eff, sn} -> {f["id"], {eff && eff.id, sn}} end)

    enriched =
      Enum.map(pairs, fn {t, eff} ->
        t = Map.put(t, :fact_list, fact_list(t, fact_eff_by_id, overrides))

        case eff do
          nil ->
            Map.merge(t, %{
              arc_id: nil,
              arc_status: nil,
              arc_grund: nil,
              leitfrage: nil,
              leitfrage_kuratiert?: false
            })

          a ->
            {arc_status, arc_grund} =
              derive_arc_status(a, Map.get(max_fakt_session_by_arc, a.id, 0))

            kuratiert? = is_binary(a.kuratiert) and a.kuratiert != ""

            t
            |> Map.merge(%{
              arc_id: a.id,
              arc_status: arc_status,
              arc_grund: arc_grund,
              leitfrage: if(kuratiert?, do: a.kuratiert, else: a.draft),
              leitfrage_kuratiert?: kuratiert?
            })
            |> apply_act_precedence(a, arc_status)
        end
      end)

    {enriched, arc_review(arcs, by_id, pairs, max_fakt_session_by_arc)}
  end

  # #905: Wire-Fakt-Liste pro Thread (id+claim-Projektion — die volle
  # Fakt-Gruppe bleibt gestrippt). rauschen-Stränge sparen die Bytes.
  defp fact_list(%{kind: "rauschen"}, _eff, _ov), do: []

  defp fact_list(t, fact_eff_by_id, overrides) do
    Enum.map(t.facts, fn f ->
      {eff_id, sn} = Map.get(fact_eff_by_id, f["id"], {nil, nil})

      %{
        id: f["id"],
        claim: f["claim"],
        session_number: sn,
        effective_arc_id: eff_id,
        overridden?: Map.has_key?(overrides, f["id"])
      }
    end)
  end

  # #905: Review-Ableitung — reine Filter über die schon berechneten Pairs.
  defp arc_review(arcs, by_id, pairs, max_by_arc) do
    visible = Enum.filter(arcs, &(&1.merged_into in [nil, ""]))

    paired_ids =
      pairs
      |> Enum.map(fn {_t, eff} -> eff && eff.id end)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    verwaiste =
      visible
      |> Enum.reject(&MapSet.member?(paired_ids, &1.id))
      |> Enum.sort_by(& &1.id)
      |> Enum.map(fn a ->
        {st, gr} = derive_arc_status(a, Map.get(max_by_arc, a.id, 0))
        kuratiert? = is_binary(a.kuratiert) and a.kuratiert != ""

        vorschlag =
          visible
          |> Enum.reject(&(&1.id == a.id))
          |> Enum.map(fn o -> {o, MapSet.size(MapSet.intersection(o.seeds, a.seeds))} end)
          |> Enum.filter(fn {_o, n} -> n > 0 end)
          |> Enum.sort_by(fn {o, n} -> {-n, o.id} end)
          |> List.first()

        %{
          arc_id: a.id,
          leitfrage: if(kuratiert?, do: a.kuratiert, else: a.draft),
          arc_status: st,
          arc_grund: gr,
          seeds: a.seeds |> MapSet.to_list() |> Enum.sort(),
          vorschlag_arc_id: vorschlag && elem(vorschlag, 0).id
        }
      end)

    gemergte =
      arcs
      |> Enum.filter(&(&1.merged_into not in [nil, ""]))
      |> Enum.sort_by(& &1.id)
      |> Enum.map(fn a ->
        kuratiert? = is_binary(a.kuratiert) and a.kuratiert != ""

        %{
          arc_id: a.id,
          leitfrage: if(kuratiert?, do: a.kuratiert, else: a.draft),
          merge_into: a.merged_into,
          wirksam?: effective_arc(a, by_id).id != a.id
        }
      end)

    %{verwaiste: verwaiste, gemergte: gemergte}
  end

  # #905 Redirect-Invariante: wirksam gdw. Ziel-Row EXISTIERT und Ziel selbst
  # un-gemerged (Ein-Level — Zyklen/Ketten degradieren zu wirkungslos-aber-
  # sichtbar, nie zu verstecktem Zustand). Undo von B→C macht ein wartendes
  # A→B nachträglich wirksam (reine Lesezeit, konvergent — benannte Kante).
  defp effective_arc(%{merged_into: mi} = a, by_id) when is_binary(mi) and mi != "" do
    case Map.get(by_id, mi) do
      %{merged_into: t} = ziel when t in [nil, ""] -> ziel
      _ -> a
    end
  end

  defp effective_arc(a, _by_id), do: a

  # kein Akt → offen (datengetriebener Default) · Reopened → offen ·
  # Closed(geloest) → geschlossen (nie Auto-Reopen) · Closed(versandet, wl)
  # → offen gdw max_fakt_session > wl.
  defp derive_arc_status(%{act: nil}, _max), do: {"offen", nil}
  defp derive_arc_status(%{act: "reopened"}, _max), do: {"offen", nil}
  defp derive_arc_status(%{act: "closed", grund: "geloest"}, _max), do: {"geschlossen", "geloest"}

  defp derive_arc_status(%{act: "closed", grund: "versandet", wl: wl}, max_fakt_session) do
    wl = if is_integer(wl), do: wl, else: 0
    if max_fakt_session > wl, do: {"offen", nil}, else: {"geschlossen", "versandet"}
  end

  defp derive_arc_status(_defekt, _max), do: {"offen", nil}

  # Read-both-PRÄZEDENZ (#900-Fund A7): existiert IRGENDEIN Arc-Akt, gilt die
  # Arc-Wahrheit exklusiv für den Thread-Status — ein prä-S2-Legacy-resolve
  # darf einen ArcReopened nicht wirkungslos machen. Nur bei Akt-Abwesenheit
  # zählt der Legacy-lifecycle-Override (Status wie gebaut).
  defp apply_act_precedence(t, %{act: nil}, _arc_status), do: t
  defp apply_act_precedence(t, _arc, "geschlossen"), do: %{t | status: :aufgelöst}
  defp apply_act_precedence(t, _arc, _offen), do: %{t | status: t.base_status}

  # Normalisierte Roh-Label-Menge des Threads — dieselbe Normalisierung wie
  # Geburt/Overrides (single-sourced gegen Pairing-Drift).
  defp thread_label_set(t) do
    t.facts
    |> Enum.map(fn f -> f |> Map.get("thread", "") |> Worker.ThreadOverride.normalize() end)
    |> Enum.reject(&(&1 == ""))
    |> MapSet.new()
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

    # Neutrale Undo-Aktionen (clear_identity/reactivate) zählen als
    # „kein Override".
    identity_action = if id_ov && id_ov.action in ["rename", "merge"], do: id_ov.action
    lifecycle_action = if life_ov && life_ov.action in ["resolve", "dismiss"], do: life_ov.action

    # #885/#901/#909: die geteilte kind-Präzedenz (`effective_kind/3`).
    {kind, kind_action} = effective_kind(norm, kinds, kind_ov)

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
      # Intern für die Akt-Präzedenz (#903) — wird vor dem Return gedroppt.
      base_status: base_status,
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
