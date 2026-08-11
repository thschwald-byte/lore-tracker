defmodule HubWeb.CampaignLive.Facts do
  @moduledoc """
  Issue #916 (Epic #911, Cut 2): der Publish-/Edit-Pfad der editierbaren Fakten-
  Spalte. Je EIN Feld (claim/character/thread/verified/dismissed) als
  FactCurationSet-Event, verankert an der **Utterance-Menge** des Fakts
  (`quell_utterance_ids`, aus dem campaign_facts-Snapshot) — claim-unabhängig, so
  überlebt der Override einen Regenerate (Read-Zeit-Re-Attach im Worker).

  **Serverseitiges Gate** (`:curate_facts`, Member-Recht) + Feld-Validierung vor
  dem Publish. Inline-Edit-State `@facts_editing = {session_id, fact_id, field}`.
  Der `anchor_hash` wird beim Save deterministisch aus der sortierten Utterance-
  Menge gebildet (einzige Produzentenstelle — der Worker matcht am Read über die
  Menge, nicht über den Hash).

  Kontext-Modul mit Delegations-Pattern; läuft im LiveView-Prozess.
  """

  import Phoenix.Component, only: [assign: 2]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias Hub.InputCaps
  alias HubWeb.CampaignLive.Publisher
  alias HubWeb.Permissions
  alias Shared.Events

  @fields ~w(claim character thread verified dismissed)

  @doc "Dispatch der `fact_*`-Events aus dem CampaignLive-handle_event."
  # Edit-State keyt auf die Fakt-`id` (content-adressiert, eindeutig pro Zeile);
  # der anchor_hash fürs Persistieren wird erst beim Save aus der quell-Menge gebildet.
  def fact_event(socket, "fact_edit_start", %{"fact" => fid, "field" => field} = p) do
    {:noreply, assign(socket, facts_editing: {p["session"], fid, field})}
  end

  def fact_event(socket, "fact_edit_cancel", _params),
    do: {:noreply, assign(socket, facts_editing: nil)}

  # #953: thread-Save als Mehrfachfeld — ein Label pro Zeile (KEIN Komma-Split,
  # Labels dürfen Kommas enthalten) → JSON-Array-String für den Worker-Decode.
  def fact_event(socket, "fact_save", %{"session" => sid, "quell" => q, "field" => "thread"} = p) do
    labels =
      (p["value"] || "")
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    publish_field(socket, sid, q, "thread", Jason.encode!(labels))
  end

  # Textfeld-Save (claim/character) via Form.
  def fact_event(socket, "fact_save", %{"session" => sid, "quell" => q, "field" => field} = p),
    do: publish_field(socket, sid, q, field, p["value"] || "")

  # Ein-Klick-Toggle (verified?/löschen) — value kommt aus phx-value.
  def fact_event(socket, "fact_toggle", %{"session" => sid, "quell" => q, "field" => field} = p),
    do: publish_field(socket, sid, q, field, p["value"] || "")

  def fact_event(socket, _other, _params), do: {:noreply, socket}

  # #916: der öffentliche Anker-Hash (auch fürs Span-Melden verwendbar).
  @doc false
  def anchor_hash(quell) when is_list(quell) do
    :crypto.hash(:sha256, Enum.join(Enum.sort(quell), ","))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  # ─── intern ──────────────────────────────────────────────────────

  defp publish_field(socket, sid, quell_str, field, value)
       when field in @fields and is_binary(sid) do
    user = socket.assigns.perm_user
    campaign = socket.assigns.campaign
    quell = quell_str |> to_string() |> String.split(",", trim: true) |> Enum.sort()
    value = to_string(value)
    cap_key = cap_key(field)

    cond do
      quell == [] ->
        {:noreply, socket}

      not Permissions.can?(user, :curate_facts, campaign) ->
        {:noreply, put_flash(socket, :error, "Keine Berechtigung")}

      # Issue #994: Längen-Cap VOR dem Publish. `:curate_facts` ist ein
      # Member-Recht, und ohne Cap landet ein Multi-MB-Blob im per-Campaign-
      # Event-Store und wird via Gossip-Pull auf JEDEN Member-Worker repliziert
      # (das #636-Threat-Model). Die eine Engstelle für alle fünf Felder —
      # auch die Toggles, deren `value` ebenfalls aus client-kontrollierten
      # phx-value-Attributen stammt.
      match?({:error, _}, InputCaps.check(cap_key, value)) ->
        {:error, {:too_long, limit}} = InputCaps.check(cap_key, value)
        {:noreply, put_flash(socket, :error, InputCaps.error_message(cap_key, limit))}

      true ->
        Publisher.publish(socket, %{
          "kind" => Events.fact_curation_set(),
          "session_id" => sid,
          "campaign_id" => socket.assigns.campaign_id,
          "anchor_hash" => anchor_hash(quell),
          "quell_utterance_ids" => quell,
          "field" => field,
          "value" => value,
          "set_by" => user.discord_id
        })

        {:noreply, assign(socket, facts_editing: nil)}
    end
  end

  defp publish_field(socket, _sid, _quell, _field, _value), do: {:noreply, socket}

  # Issue #994: Feld → InputCaps-Schlüssel. Die Toggles teilen sich einen engen
  # Cap (ihre legitimen Werte sind "true"/"" o.ä.).
  defp cap_key("claim"), do: :fact_claim
  defp cap_key("character"), do: :fact_character
  defp cap_key("thread"), do: :fact_thread
  defp cap_key(field) when field in ~w(verified dismissed), do: :fact_flag
end
