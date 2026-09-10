defmodule Worker.Repo.GlattQuellen do
  @moduledoc """
  Issue #1198: Block-IDs → Quell-Utterances und der 🕳-Lücken-Marker, gerechnet
  im Worker statt im Hub.

  Bis #1198 holte der Hub dafür das komplette Skelett aller geglätteten Blöcke
  (`campaign_luecken`; an seattleV4 5.317 Blöcke, 1,25 MB über den Draht, im
  LiveView-Heap 10 → 36 MB) und baute daraus selbst die Block-Karte
  (`HubWeb.CampaignLive.Refs.block_source_map/1`) und die Menge der
  unkuratierten Lücken (`HubWeb.CampaignLive.GapMarker`). Angezeigt wurden davon
  höchstens ~600 Blöcke. Am 10.09.2026 hat genau das den Prod-Hub dreimal in
  drei Minuten umgebracht — mit einem einzigen Tab. Die Regel seither: alle
  Daten liegen im Worker, an den Hub geht nur, was er anzeigt.

  **Verhandelt, nicht vorausgesetzt.** Angereichert wird nur, wenn der Hub
  `"refs" => "aufgeloest"` schickt (`Worker.Repo.snapshot/1`). Ohne das Flag ist
  jede Antwort byte-identisch — ein alter Hub gegen diesen Worker merkt nichts.
  Dasselbe Prinzip wie `"glatt" => "fenster"` in #1152.

  **Kampagnenweit, nie pro Session.** Chronik-Einträge und das Alt-Epos können
  Blöcke mehrerer Sessions zitieren (#650). Eine Auflösung pro Session ließe
  deren Refs still unaufgelöst — kein Fehler, nur ein Popover mit
  „Quelle nicht verfügbar".

  **Der Marker ist immer vollständig.** `luecken_marker` enthält in JEDER
  angereicherten Antwort die Schlüssel aller Derivationen der Kampagne, auch
  wenn die Antwort selbst nur die Chronik trägt. Der Hub kann die Menge dann
  schlicht ersetzen; eine Teilmenge, die er je nach Scope zusammenflicken
  müsste, wäre die Stelle, an der ein Marker still verschwindet.

  **Fehler dürfen die Antwort nicht kosten.** `Worker.HubClient.Rpc.on_snapshot/2`
  fängt nichts ab. Eine Exception hier träfe den Socket-Prozess; der Reconnect
  löste in jeder offenen Ansicht einen Voll-Read aus — genau die Last, gegen
  die #1198 gebaut ist. `sicher/2` liefert im Fehlerfall die unveränderte
  Antwort und sagt es laut.
  """

  require Logger

  alias Worker.Repo.Luecken

  @listen ~w(summaries chronik epos_chapters)

  @typedoc "Block-ID → Quell-Utterances + ob der Block eine unkuratierte Lücke ist."
  @type index :: %{optional(String.t()) => %{quell: [String.t()], offen?: boolean()}}

  @doc """
  Die Block-Karte einer Kampagne: `%{block_id => %{quell: [...], offen?: bool}}`.

  `offen?` heißt „unkuratierte ASR-Lücke" — `hat_luecke` und kein wirksamer
  Kurations-Status. Der Status kommt aus `Luecken.luecken_overrides_effective/2`,
  schließt also den Read-Zeit-Re-Attach nach einem Regelwechsel ein. Dieselbe
  Semantik wie der Kuratieren-Filter der Geglättet-Spalte.
  """
  @spec block_index(String.t()) :: index()
  def block_index(campaign_id) when is_binary(campaign_id) do
    campaign_id
    |> Worker.Repo.list_sessions()
    |> Enum.reduce(%{}, fn session, acc ->
      case Worker.Repo.get_smoothed_blocks(session.id) do
        nil -> acc
        snap -> index_session(acc, session.id, snap.blocks || [])
      end
    end)
  end

  defp index_session(acc, session_id, blocks) do
    %{attached: attached} = Luecken.luecken_overrides_effective(session_id, blocks)

    Enum.reduce(blocks, acc, fn b, inner ->
      id = b["id"]
      status = get_in(attached, [id, "status"])

      Map.put(inner, id, %{
        quell: b["quell_utterance_ids"] || [],
        offen?: b["hat_luecke"] == true and is_nil(status)
      })
    end)
  end

  @doc """
  `source_refs` → Utterance-IDs. Exakt die Semantik, die bis #1198 der Hub hatte
  (`HubWeb.CampaignLive.Refs.resolve_source_refs/2`, #1094):

  - Ein Ref, den die Karte nicht kennt, wird **durchgereicht**. Vor #864 waren
    `source_refs` echte Utterance-IDs; Bestandskampagnen ohne Glättung haben gar
    keine Blöcke. Filtern statt Durchreichen löschte deren Refs.
  - Ein bekannter Block **ohne** Quell-Utterances wird ebenfalls durchgereicht
    — eine unauflösbare Quelle bleibt sichtbar statt lautlos zu verschwinden.
  - Das Ergebnis ist `uniq`: zwei Blöcke desselben Eintrags können dieselbe
    Utterance nennen.
  """
  @spec aufloesen([String.t()] | nil, index()) :: [String.t()]
  def aufloesen(refs, index) do
    refs
    |> List.wrap()
    |> Enum.flat_map(fn ref ->
      case Map.get(index, ref) do
        %{quell: quell} when quell != [] -> quell
        _ -> [ref]
      end
    end)
    |> Enum.uniq()
  end

  @doc """
  Berührt eine Derivation über ihre **rohen** `source_refs` eine unkuratierte
  Lücke? Bewusst auf Block-IDs, nicht auf aufgelösten Utterances: eine Lücke
  hat ein Block, keine Utterance (#1094 — die einzige Refs-Lesestelle, die nach
  #864 schon richtig war).
  """
  @spec offen?([String.t()] | nil, index()) :: boolean()
  def offen?(refs, index), do: Enum.any?(List.wrap(refs), &match?(%{offen?: true}, index[&1]))

  @doc """
  Die Marker-Schlüssel der Kampagne, sortiert: `summary:<session_id>`,
  `chronik:<id>`, `epos_chapter:<id>` — genau die drei Stellen, an denen die
  Oberfläche ein 🕳 zeigt. Das Alt-Epos trägt keinen Marker und bekommt keinen.
  """
  @spec marker(String.t(), index()) :: [String.t()]
  def marker(campaign_id, index) do
    summaries =
      for s <- Worker.Repo.list_session_summaries(campaign_id),
          offen?(s.source_refs, index),
          do: "summary:#{s.session_id}"

    chronik =
      for c <- Worker.Repo.list_chronik_entries(campaign_id),
          offen?(c.source_refs, index),
          do: "chronik:#{c.id}"

    kapitel =
      for k <- Worker.Repo.list_epos_chapters(campaign_id),
          offen?(k.source_refs, index),
          do: "epos_chapter:#{k.id}"

    Enum.sort(summaries ++ chronik ++ kapitel)
  end

  @doc """
  Reichert eine serialisierte Scope-Antwort an: jeder Eintrag in `summaries`,
  `chronik`, `epos_chapters` und das `epos` bekommen `quell_utterance_ids`, die
  Antwort bekommt `luecken_marker`. Ablehnungen (`forbidden`, `not_found`,
  `error`) gehen unverändert durch.
  """
  @spec anreichern(term(), map()) :: term()
  def anreichern(snap, %{"id" => campaign_id}) when is_map(snap) and is_binary(campaign_id) do
    if ablehnung?(snap), do: snap, else: sicher(snap, &mit_quellen(&1, campaign_id))
  end

  def anreichern(snap, _scope), do: snap

  defp ablehnung?(snap),
    do: Map.has_key?(snap, "error") or snap["forbidden"] == true or snap["not_found"] == true

  defp mit_quellen(snap, campaign_id) do
    index = block_index(campaign_id)

    snap
    |> Map.new(fn
      {key, liste} when key in @listen and is_list(liste) ->
        {key, Enum.map(liste, &mit_quell(&1, index))}

      {"epos", %{} = epos} ->
        {"epos", mit_quell(epos, index)}

      other ->
        other
    end)
    |> Map.put("luecken_marker", marker(campaign_id, index))
  end

  defp mit_quell(%{} = eintrag, index),
    do: Map.put(eintrag, "quell_utterance_ids", aufloesen(eintrag["source_refs"], index))

  defp mit_quell(other, _index), do: other

  @doc false
  # Öffentlich nur für den Test: der Fehlerpfad ist sonst nicht auslösbar, ohne
  # Mnesia zu beschädigen.
  @spec sicher(term(), (term() -> term())) :: term()
  def sicher(snap, fun) do
    fun.(snap)
  rescue
    e ->
      Logger.error(
        "GlattQuellen: Anreicherung gescheitert, Antwort geht unverändert raus — " <>
          Exception.format(:error, e, __STACKTRACE__)
      )

      snap
  catch
    :exit, reason ->
      Logger.error(
        "GlattQuellen: Anreicherung abgebrochen (exit #{inspect(reason)}), Antwort geht unverändert raus"
      )

      snap
  end
end
