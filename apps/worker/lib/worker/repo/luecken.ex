defmodule Worker.Repo.Luecken do
  @moduledoc """
  Issue #865 (Epic #861 D+E): Read-Pfad der Gap-Fill-Welt — Gemma-Füll-
  Vorschläge (`worker_luecken_vorschlaege`) + Kurations-Overlay
  (`worker_luecken_overrides`) inkl. Read-Zeit-Re-Attach (F2). Ausgelagert
  aus `Worker.Repo.Artifacts` (God-Module-Grenze); Call-Sites bleiben
  `Worker.Repo.x()` (Façade-defdelegate).
  """

  alias Worker.Recording.Pipeline.Smoothing
  alias Worker.Schema.Mnesia, as: S

  import Worker.Repo, only: [transaction: 1]

  # ─── Text-Ladefenster (Issue #1152, Epic #1146) ─────────────────
  #
  # Wie viele Blöcke je Session ihre TEXTE mitbekommen. Bewusst =
  # `Components.window_max/0` im Hub (200) — dieselbe Begründung wie beim
  # Utterance-Fenster (#1087, recording.ex:11-16): das Render-Fenster darf bis
  # dorthin wachsen, ohne dass nachgeladen werden muss.
  @glatt_tail 200

  # Ein Fenster PRO SESSION deckelt nichts: eine Kampagne mit 200 Sessions
  # bekäme 40.000 betextete Blöcke. Deshalb ein Gesamtbudget, von der jüngsten
  # Session abwärts vergeben — dort schaut man hin.
  @glatt_budget 600

  # Auch eine leer ausgegangene Session behält einen Rest. Anders als beim
  # Utterance-Fenster verschwindet hier zwar keine Session aus der Ansicht (das
  # Skelett ist vollständig, der Session-Kopf steht also immer) — aber eine
  # Session ganz ohne Text wäre beim Aufklappen leer, bis nachgeladen ist.
  @glatt_floor 10

  # Was NUR im Fenster mitreist, und was IMMER an jedem Block steht. Beide
  # Listen sind über `text_keys/0`/`skelett_keys/0` prüfbar — ein Feld, das
  # versehentlich die Seite wechselt, erzeugt sonst keinen Fehler, sondern
  # eine leere Zeile im Panel oder einen stillen Mehrverbrauch.
  @text_keys ~w(speaker_discord_id text text_smoothed roh_text vorschlag_text vorschlag_modell override)
  @skelett_keys ~w(block_id quell_utterance_ids hat_luecke status)

  @doc false
  def text_keys, do: @text_keys
  @doc false
  def skelett_keys, do: @skelett_keys

  @doc "Gemma-Füll-Vorschläge einer Session, keyed by Block-Content-ID."
  @spec luecken_vorschlaege_for_session(String.t()) :: %{optional(String.t()) => map()}
  def luecken_vorschlaege_for_session(session_id) when is_binary(session_id) do
    transaction(fn -> :mnesia.index_read(S.luecken_vorschlaege(), session_id, :session_id) end)
    |> Map.new(fn {_, block_id, _sid, _cid, original, vorschlag, modell, event_id} ->
      {block_id,
       %{
         "block_id" => block_id,
         "original" => original,
         "vorschlag" => vorschlag,
         "modell" => modell,
         "event_id" => event_id
       }}
    end)
  end

  @doc """
  Effektive Kurations-Overrides einer Session, keyed by AKTUELLER Block-Content-
  ID — inkl. **Read-Zeit-Re-Attach** (F2 Runde 5/6): matcht ein Override nicht
  direkt (Regelwechsel → neue Block-IDs), wird es über die identische,
  sortiert-kanonisch gesnapshottete `quell_utterance_ids`-Menge auf den
  aktuellen Block gepaart — angewandt NUR, wenn sein `bestaetigter_text` einem
  der `candidate_texts` des Blocks noch entspricht (K3-Snapshot als Wahrheit;
  sonst → `verwaist`-Liste für die Review-Queue, nie still weg). Paaren MEHRERE
  Overrides denselben Block, gewinnt LWW-by-event_id (deterministisch über
  Worker — reine Lese-Berechnung, idempotent, multi-worker-safe).

  `blocks` = die aktuellen Snapshot-Blöcke (String-Key-Maps). Returns
  `%{attached: %{block_id => override}, verwaist: [override]}`.
  """
  @spec luecken_overrides_effective(String.t(), [map()]) :: %{
          attached: %{optional(String.t()) => map()},
          verwaist: [map()]
        }
  def luecken_overrides_effective(session_id, blocks) when is_binary(session_id) do
    overrides =
      transaction(fn -> :mnesia.index_read(S.luecken_overrides(), session_id, :session_id) end)
      |> Enum.map(fn {_, _lo_key, _sid, _cid, block_id, status, text, quell, set_by, event_id} ->
        %{
          "block_id" => block_id,
          "status" => status,
          "bestaetigter_text" => text,
          "quell_utterance_ids" => quell || [],
          "set_by" => set_by,
          "event_id" => event_id
        }
      end)

    by_current_id = Map.new(blocks, &{&1["id"], &1})
    by_quell = Map.new(blocks, &{Enum.sort(&1["quell_utterance_ids"] || []), &1["id"]})

    {attached, verwaist} =
      Enum.reduce(overrides, {%{}, []}, fn ov, {att, orph} ->
        case attach_target(ov, by_current_id, by_quell) do
          nil ->
            {att, [ov | orph]}

          block_id ->
            # LWW bei Mehrfach-Paarung (alter + nach dem Bump neu geschriebener
            # Override auf denselben Block) — höhere event_id gewinnt.
            prev = Map.get(att, block_id)

            if prev != nil and prev["event_id"] >= ov["event_id"],
              do: {att, orph},
              else: {Map.put(att, block_id, ov), orph}
        end
      end)

    %{attached: attached, verwaist: Enum.reverse(verwaist)}
  end

  # Roh-Text des Blocks = Original-Texte seiner Quell-Utterances in
  # Zeit-Reihenfolge. nil, wenn keine Quell-Utterance mehr auffindbar ist
  # (z.B. gelöschte Utterances) — das Panel fällt dann auf den Smoothed-Text
  # ohne Diff zurück, statt einen leeren Roh-Text als „alles ergänzt" zu lügen.
  defp roh_text(block, utt_by_id) do
    utts =
      (block["quell_utterance_ids"] || [])
      |> Enum.map(&Map.get(utt_by_id, &1))
      |> Enum.reject(&is_nil/1)

    if utts == [] do
      nil
    else
      utts
      |> Enum.sort_by(& &1.timestamp, {:asc, DateTime})
      |> Enum.map_join(" ", & &1.text)
    end
  end

  @doc """
  Issue #871 (erweitert um die Slice-E-Kuration, Review 2026-07-16): die
  geglättete Block-Ebene fürs Spalten-UI — pro Session mit Smoothing-Snapshot
  die Blöcke mit **aufgelöstem** `effective_text` (Vorschlag/Kuration
  eingerechnet, dieselbe eine Text-Funktion wie die Pipeline) + allem, was
  die INLINE-Kuration braucht: Smoothed-Basis-Text, Roh-Text (Trims-Diff),
  Vorschlags-Text (Diff + Übernehmen), Override (Badge + letzter Schreiber),
  `quell_utterance_ids` (K3-Snapshot fürs Kurations-Event + Protokoll-Sprung).
  `unbrauchbar`-Blöcke bleiben sichtbar (durchgestrichen, F5-Audit),
  OOC-Verworfenes + verwaiste Overrides (Re-Attach-Review) am Session-Kopf.

  Issue #883: liefert ALLE Blöcke — der frühere 200er-Reader-Cap versteckte
  auf Real Free Seattle die ersten ~540 Blöcke unerreichbar. Diese Lektion gilt
  weiter und gilt seit #1152 fürs **Skelett**: ein Deckel ohne Nachladeweg
  macht Blöcke unerreichbar.

  **Issue #1152 (Epic #1146) — die alte Begründung ist widerlegt.** Hier stand
  bis dahin, begrenzt werde allein render-seitig, denn „teuer ist der
  Render-Diff, nicht der Assign-Heap" (#709). Genau dieser Satz ist von #1087
  mit Zahlen widerlegt: der Assign-Heap kostet ~870 Byte je ~270 Byte Daten und
  war der größte Einzelposten im 381,5-MiB-Prod-Hub. An seattleV4 gemessen sind
  diese Blöcke **2436 KB pro Betrachter**, 74 % des Haupt-Snapshots — die
  einzige große Liste, die #1087 nicht gefenstert hat.

  Mit `fenster: true` reist deshalb nur noch das **Skelett** vollständig
  (`block_id`, `quell_utterance_ids`, `hat_luecke`, `status` — gemessen 793 KB),
  die **Texte** nur für die jüngsten `@glatt_tail` Blöcke je Session unter einem
  Gesamtbudget. Ohne die Option ist die Antwort **byte-identisch** zu vorher;
  das ist die Rollback-Sicherheit, an der ein alter Hub gegen einen neuen
  Worker unverändert alles bekommt.

  **Die Invariante ist eine andere als beim Utterance-Fenster.** Dort muss die
  gelieferte Liste ein zusammenhängendes Suffix sein, sonst erschienen
  nicht-benachbarte Zeilen als benachbart. Hier fehlt **kein** Block: die
  Texte sind eine beliebige Teilmenge, ein textloser Block ist sichtbar
  textlos statt unsichtbar. Ein `text_from` gibt es deshalb bewusst nicht — es
  beschriebe ein Suffix, auf das sich niemand verlassen darf.

  Nachgeladen wird über `smoothed_texts_by_ids/2` (die Kuratieren-Ansicht
  filtert über ein **Prädikat**, ihre Blöcke liegen über die ganze Session
  verstreut) und `smoothed_texts_slice/4` (zusammenhängendes Scrollen). Zwei
  Formen aus demselben Grund wie bei `campaign_utterances` (snapshots.ex): die
  Ansicht stellt zwei verschiedene Fragen.
  """
  @spec smoothed_for_campaign(String.t(), keyword()) :: [map()]
  def smoothed_for_campaign(campaign_id, opts \\ []) when is_binary(campaign_id) do
    paare =
      campaign_id
      |> Worker.Repo.list_sessions()
      |> Enum.flat_map(fn session ->
        case Worker.Repo.get_smoothed_blocks(session.id) do
          nil -> []
          snap -> [{session, snap}]
        end
      end)

    plan = if Keyword.get(opts, :fenster, false), do: text_plan(paare), else: %{}

    Enum.map(paare, fn {session, snap} ->
      smoothed_session_view(session, snap, Map.get(plan, session.id, :alle))
    end)
  end

  # Budget-Vergabe wie `campaign_utterance_tail/2` (#1087): jüngste Session
  # zuerst, und ÜBERZOGEN statt geschnitten — das Budget wird vor der Entnahme
  # geprüft, nicht während. Ergebnis je Session: `{:ab, index}`, ab dem die
  # Blöcke ihre Texte tragen.
  defp text_plan(paare) do
    paare
    |> Enum.sort_by(fn {s, _} -> s.number || -1 end, :desc)
    |> Enum.reduce({%{}, @glatt_budget}, fn {s, snap}, {acc, budget} ->
      total = length(snap.blocks || [])
      take = if budget > 0, do: min(total, @glatt_tail), else: min(total, @glatt_floor)
      {Map.put(acc, s.id, {:ab, total - take}), budget - take}
    end)
    |> elem(0)
  end

  defp smoothed_session_view(session, snap, texte) do
    blocks = snap.blocks || []
    vorschlaege = luecken_vorschlaege_for_session(session.id)
    %{attached: attached, verwaist: verwaist} = luecken_overrides_effective(session.id, blocks)

    ab =
      case texte do
        :alle -> 0
        {:ab, i} -> i
      end

    # Der Roh-Text ist der einzige Grund, warum hier die GANZE Session an
    # Utterances geladen wurde. Trägt kein einziger Block in dieser Antwort
    # einen Text, entfällt der Read vollständig. Trägt auch nur einer ihn, muss
    # weiterhin alles geladen werden: einen Leser für einzelne Utterance-IDs
    # gibt es nicht (`utterances_by_ids/2` scannt selbst alle Sessions). Der
    # Gewinn liegt also am leeren Fenster, nicht am kleinen.
    utt_by_id =
      if ab < length(blocks) do
        session.id
        |> Worker.Repo.list_utterances(limit: :all)
        |> Map.new(&{&1.id, &1})
      else
        %{}
      end

    view_blocks =
      blocks
      |> Enum.with_index()
      |> Enum.map(fn {b, idx} ->
        id = b["id"]
        override = Map.get(attached, id)

        # SKELETT — immer, an jedem Block. Ohne `status` könnte der Hub weder
        # den Kuratier-Zähler noch die Ansichts-Filter rechnen, ohne
        # `quell_utterance_ids` bräche die Verweis-Karte still ab (#1094).
        skelett = %{
          "block_id" => id,
          "quell_utterance_ids" => b["quell_utterance_ids"] || [],
          "hat_luecke" => b["hat_luecke"] == true,
          "status" => override && override["status"]
        }

        if idx >= ab,
          do: Map.merge(skelett, block_texte(b, Map.get(vorschlaege, id), override, utt_by_id)),
          else: skelett
      end)

    %{
      "session_id" => session.id,
      "session_number" => session.number,
      "rules_version" => snap.rules_version,
      "merge_gap_seconds" => snap.merge_gap_seconds,
      "ooc_verworfen_count" => length(snap.ooc_verworfen || []),
      "praesenz_ping_verworfen_count" => length(snap.praesenz_ping_verworfen || []),
      "verwaist" => verwaist,
      "blocks" => view_blocks
    }
  end

  # Die Textfelder eines Blocks. EINE Stelle, damit Voll-Antwort und Nachladen
  # nicht auseinanderlaufen können — genau dieser Drift wäre unsichtbar: ein
  # fehlendes Feld erzeugt keinen Fehler, sondern eine leere Zeile im Panel.
  defp block_texte(b, vorschlag, override, utt_by_id) do
    %{
      "speaker_discord_id" => b["speaker_discord_id"],
      "text" => Smoothing.effective_text(b, vorschlag, override),
      "text_smoothed" => b["text"],
      "roh_text" => roh_text(b, utt_by_id),
      "vorschlag_text" => vorschlag && Smoothing.effective_text(b, vorschlag, nil),
      "vorschlag_modell" => vorschlag && vorschlag["modell"],
      "override" => override
    }
  end

  @doc """
  Issue #1152: Texte für **genau diese** Blöcke.

  Die Nachlade-Form für die Kuratieren-Ansicht. Sie wählt ihre Blöcke über ein
  **Prädikat** (`hat_luecke and is_nil(status)`), nicht über einen
  Positionsbereich — an seattleV4 liegen die letzten 150 Treffer einer Session
  auf den Positionen 1230..1795 von 1802. Ein Ausschnitt `[from, count)` kann
  das nicht ausdrücken; deshalb dieselbe Zwei-Formen-Teilung wie bei
  `campaign_utterances`.

  Liefert `%{block_id => texte}`. Unbekannte IDs fallen still weg — eine
  unauflösbare Referenz ist kein Fehler, sondern eine leere Antwort (Regel aus
  `utterances_by_ids/2`). IDs fremder Kampagnen können nicht treffen, weil nur
  die Sessions dieser Kampagne durchsucht werden.
  """
  @spec smoothed_texts_by_ids(String.t(), [String.t()]) :: %{optional(String.t()) => map()}
  def smoothed_texts_by_ids(campaign_id, block_ids)
      when is_binary(campaign_id) and is_list(block_ids) do
    wanted = MapSet.new(block_ids)

    campaign_id
    |> Worker.Repo.list_sessions()
    |> Enum.reduce(%{}, fn session, acc ->
      case Worker.Repo.get_smoothed_blocks(session.id) do
        nil ->
          acc

        snap ->
          case Enum.filter(snap.blocks || [], &MapSet.member?(wanted, &1["id"])) do
            # Kein Treffer → diese Session wird gar nicht erst gelesen. Bei
            # einem Read über drei Sessions spart das zwei volle
            # Utterance-Loads.
            [] -> acc
            treffer -> Map.merge(acc, texte_fuer(session, snap, treffer))
          end
      end
    end)
  end

  @doc """
  Issue #1152: Texte des zusammenhängenden Bereichs `[from, from + count)` einer
  Session — die Nachlade-Form fürs Scrollen in den Ansichten „einfach"/„alles",
  deren Fenster tatsächlich ein Positionsbereich ist.

  Gibt `{%{block_id => texte}, total}` zurück; `total` ist die Blockzahl der
  Session, damit der Hub sein Fenster klemmen kann. `nil`, wenn die Session
  nicht zu `campaign_id` gehört — die Session-ID kommt vom Client, und ein
  Member der Kampagne A darf so nicht in Kampagne B lesen (Regel aus
  `utterance_slice/4`).
  """
  @spec smoothed_texts_slice(String.t(), String.t(), non_neg_integer(), non_neg_integer()) ::
          {%{optional(String.t()) => map()}, non_neg_integer()} | nil
  def smoothed_texts_slice(campaign_id, session_id, from, count)
      when is_binary(campaign_id) and is_binary(session_id) do
    with %{campaign_id: ^campaign_id} = session <- Worker.Repo.get_session(session_id),
         snap when not is_nil(snap) <- Worker.Repo.get_smoothed_blocks(session_id) do
      blocks = snap.blocks || []
      treffer = Enum.slice(blocks, max(from, 0), max(count, 0))
      {texte_fuer(session, snap, treffer), length(blocks)}
    else
      # Session existiert, hat aber (noch) keine Glättung: kein Fehler, nur
      # nichts da. Fremde/unbekannte Session dagegen → nil.
      nil ->
        case Worker.Repo.get_session(session_id) do
          %{campaign_id: ^campaign_id} -> {%{}, 0}
          _ -> nil
        end

      _ ->
        nil
    end
  end

  # Gemeinsamer Rumpf beider Nachlade-Formen. Die Overrides werden gegen ALLE
  # Blöcke der Session aufgelöst, nicht nur gegen die getroffenen: das
  # Re-Attach (F2) paart über die Utterance-Menge und bräuchte sonst einen
  # Block, den es nicht sieht.
  defp texte_fuer(_session, _snap, []), do: %{}

  defp texte_fuer(session, snap, treffer) do
    vorschlaege = luecken_vorschlaege_for_session(session.id)
    %{attached: attached} = luecken_overrides_effective(session.id, snap.blocks || [])

    utt_by_id =
      session.id
      |> Worker.Repo.list_utterances(limit: :all)
      |> Map.new(&{&1.id, &1})

    Map.new(treffer, fn b ->
      id = b["id"]
      {id, block_texte(b, Map.get(vorschlaege, id), Map.get(attached, id), utt_by_id)}
    end)
  end

  @doc """
  Issue #1152: Rumpf des `campaign_luecken`-Scopes. Liegt hier, weil
  `snapshots.ex` dicht an der God-Module-Grenze steht; das member?-Gate bleibt
  am Dispatch sichtbar.
  """
  @spec panel(String.t(), map()) :: map()
  def panel(campaign_id, sc),
    do: %{"smoothed" => smoothed_for_campaign(campaign_id, fenster: sc["glatt"] == "fenster")}

  @doc """
  Issue #1152: Rumpf des `campaign_luecken_slice`-Scopes (das member?-Gate bleibt am Dispatch).

  Liegt hier statt in `snapshots.ex`, weil diese Datei auf ihrem Ratschen-Wert
  steht (602 Code-Zeilen, `.credo.exs`) und nicht wachsen darf — dieselbe
  Entscheidung wie bei `Worker.Repo.PipelineStand` (#1122). Die
  member?-Prüfung bleibt am Dispatch, die Session-Zugehörigkeit prüft
  `smoothed_texts_slice/4` selbst.
  """
  @spec slice(String.t(), map()) :: map()
  def slice(campaign_id, sc) do
    cond do
      is_list(sc["block_ids"]) ->
        %{"mode" => "ids", "texte" => smoothed_texts_by_ids(campaign_id, sc["block_ids"])}

      is_binary(sc["session_id"]) ->
        from = index(sc["from"])
        count = index(sc["count"])

        case smoothed_texts_slice(campaign_id, sc["session_id"], from, count) do
          nil ->
            %{"error" => "unknown_session"}

          {texte, total} ->
            %{
              "mode" => "slice",
              "session_id" => sc["session_id"],
              "from" => from,
              "total" => total,
              "texte" => texte
            }
        end

      true ->
        %{"error" => "bad_request"}
    end
  end

  # Der Hub schickt die Indizes als JSON-Zahlen; alles andere ist ein Bug auf
  # der Aufruferseite und wird auf 0 geklemmt statt zu crashen (Regel aus
  # `snapshots.ex`).
  defp index(n) when is_integer(n) and n >= 0, do: n
  defp index(_), do: 0

  @doc "Issue #1152: Default-Größe des Text-Fensters je Session."
  @spec glatt_tail_size() :: pos_integer()
  def glatt_tail_size, do: @glatt_tail

  @doc "Anzahl Kurations-Overrides auf diesem Worker (merge_gap-Warnung, /settings)."
  @spec override_count() :: non_neg_integer()
  def override_count do
    transaction(fn -> :mnesia.all_keys(S.luecken_overrides()) end) |> length()
  end

  # Direkter ID-Treffer ODER Mengen-Paarung + Text-Match (Re-Attach). Ein
  # unbrauchbar-Override braucht keinen Text-Match (er segnet keinen Text ab —
  # die Menge identifiziert den Block eindeutig).
  defp attach_target(ov, by_current_id, by_quell) do
    direct = Map.has_key?(by_current_id, ov["block_id"]) and ov["block_id"]

    cond do
      direct ->
        ov["block_id"]

      block_id = Map.get(by_quell, Enum.sort(ov["quell_utterance_ids"])) ->
        block = Map.fetch!(by_current_id, block_id)

        if ov["status"] == "unbrauchbar" or text_still_matches?(ov, block),
          do: block_id,
          else: nil

      true ->
        nil
    end
  end

  # K3-Text-Match: der gesnapshottete bestätigte Text muss noch zu einem der
  # möglichen effektiven Texte des Blocks passen (Smoothed-Text reicht als
  # Kandidat — der Override ERSETZT ja den Text; entscheidend ist, dass sich
  # der UMGEBUNGSTEXT nicht unbemerkt geändert hat: bei original_bestaetigt
  # ist der bestätigte Text der Smoothed-Text selbst und muss exakt matchen;
  # bei bestaetigt/manuell_korrigiert akzeptieren wir die Paarung über die
  # Menge — der bestätigte Text bleibt der K3-Snapshot und wird angewandt).
  defp text_still_matches?(%{"status" => "original_bestaetigt"} = ov, block),
    do: ov["bestaetigter_text"] == block["text"]

  defp text_still_matches?(_ov, _block), do: true
end
