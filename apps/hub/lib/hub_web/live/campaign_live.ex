defmodule HubWeb.CampaignLive do
  @moduledoc """
  Mockup-2 campaign view: 4-column layout (Chronik / Resümee / Epos /
  Protokoll) + recording bar + owner controls.

  Recording state lives in `session.status`
  (`:scheduled → :recording → (:paused ↔ :recording) → :completed`).
  UtteranceAppended events stream into the Protokoll column without a
  full snapshot reload.

  Epos column (M7): owner can edit a single per-campaign Markdown entry;
  every save appends `EposEntryEdited`, the materializer keeps current
  + history rows. Diff is a unified line-by-line view via
  `List.myers_difference/2`.
  """

  use HubWeb, :live_view

  alias Hub.{Commands, EventLog, Reader}

  @impl true
  def mount(%{"id" => campaign_id}, %{"current_user" => user}, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Hub.PubSub, EventLog.topic())
    end

    socket =
      socket
      |> assign(:current_user, user)
      |> assign(:campaign_id, campaign_id)
      |> assign(:active_nav, :campaign)
      |> assign(:invite_url, nil)
      |> assign(:epos_mode, :view)
      |> assign(:epos_draft, "")
      |> assign(:epos_diff_seq, nil)
      |> load_snapshot()

    cond do
      socket.assigns[:forbidden?] ->
        {:ok, socket |> put_flash(:error, "Kein Zugriff") |> push_navigate(to: ~p"/")}

      socket.assigns[:not_found?] ->
        {:ok, socket |> put_flash(:error, "Kampagne nicht gefunden") |> push_navigate(to: ~p"/")}

      true ->
        {:ok, socket}
    end
  end

  # ─── Recording-bar events ───────────────────────────────────────

  @impl true
  def handle_event("rec_start", _, socket) do
    if not socket.assigns.owner?, do: {:noreply, socket}, else: do_rec_start(socket)
  end

  def handle_event("rec_pause", _, socket) do
    if socket.assigns.owner? and socket.assigns.active_session do
      append_state(socket, "paused")
    end

    {:noreply, socket}
  end

  def handle_event("rec_resume", _, socket) do
    if socket.assigns.owner? and socket.assigns.active_session do
      append_state(socket, "recording")
    end

    {:noreply, socket}
  end

  def handle_event("rec_stop", _, socket) do
    if socket.assigns.owner? and socket.assigns.active_session do
      {:ok, _seq} =
        EventLog.append(
          %{
            "kind" => Shared.Events.session_ended(),
            "id" => socket.assigns.active_session.id
          },
          nil
        )
    end

    {:noreply, socket}
  end

  def handle_event("rec_marker", _, socket) do
    if socket.assigns.owner? and socket.assigns.active_session do
      {:ok, _seq} =
        EventLog.append(
          %{
            "kind" => Shared.Events.marker_added(),
            "id" => UUIDv7.generate(),
            "session_id" => socket.assigns.active_session.id,
            "at_ts" => DateTime.utc_now() |> DateTime.to_iso8601(),
            "marker_kind" => "plot",
            "label" => "Plot-Moment"
          },
          nil
        )
    end

    {:noreply, socket}
  end

  # ─── Epos events ─────────────────────────────────────────────────

  def handle_event("epos_edit_start", _, socket) do
    if socket.assigns.owner? do
      current = (socket.assigns.epos && socket.assigns.epos["content_md"]) || ""
      {:noreply, assign(socket, epos_mode: :edit, epos_draft: current)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("epos_edit_cancel", _, socket) do
    {:noreply, assign(socket, epos_mode: :view, epos_draft: "")}
  end

  def handle_event("epos_edit_save", %{"content_md" => content_md}, socket) do
    if socket.assigns.owner? do
      {:ok, _seq} =
        EventLog.append(
          %{
            "kind" => Shared.Events.epos_entry_edited(),
            "entry_id" => socket.assigns.campaign_id,
            "campaign_id" => socket.assigns.campaign_id,
            "new_md" => content_md,
            "edited_by" => socket.assigns.current_user.discord_id,
            "source" => "manual"
          },
          nil
        )
    end

    {:noreply, assign(socket, epos_mode: :view, epos_draft: "")}
  end

  def handle_event("epos_diff_open", %{"seq" => seq_str}, socket) do
    seq = String.to_integer(seq_str)
    {:noreply, assign(socket, epos_mode: :diff, epos_diff_seq: seq)}
  end

  def handle_event("epos_diff_close", _, socket) do
    {:noreply, assign(socket, epos_mode: :view, epos_diff_seq: nil)}
  end

  # ─── Invite + shutdown events (unchanged) ───────────────────────

  def handle_event("create_invite", _, socket) do
    if socket.assigns.owner? do
      token = 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

      {:ok, _seq} =
        EventLog.append(
          %{
            "kind" => Shared.Events.invite_created(),
            "token" => token,
            "campaign_id" => socket.assigns.campaign_id,
            "created_by_discord_id" => socket.assigns.current_user.discord_id,
            "expires_at" => nil
          },
          nil
        )

      url = HubWeb.Endpoint.url() <> "/invite/#{token}"
      {:noreply, assign(socket, :invite_url, url)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("clear_invite_url", _, socket), do: {:noreply, assign(socket, :invite_url, nil)}

  def handle_event("revoke_invite", %{"token" => token}, socket) do
    if socket.assigns.owner? do
      {:ok, _seq} =
        EventLog.append(
          %{"kind" => Shared.Events.invite_revoked(), "token" => token},
          nil
        )
    end

    {:noreply, socket}
  end

  def handle_event("shutdown_worker", _, socket) do
    if socket.assigns.owner? do
      n = Commands.shutdown_my_workers(socket.assigns.current_user.discord_id)
      {:noreply, put_flash(socket, :info, "Shutdown an #{n} Worker geschickt.")}
    else
      {:noreply, socket}
    end
  end

  # ─── Event stream ────────────────────────────────────────────────

  @impl true
  def handle_info({:event_appended, %{payload: %{"kind" => "UtteranceAppended"} = payload}}, socket) do
    if socket.assigns.active_session && payload["session_id"] == socket.assigns.active_session.id do
      utterance = %{
        "id" => payload["id"],
        "session_id" => payload["session_id"],
        "discord_id" => payload["discord_id"],
        "timestamp" => payload["timestamp"],
        "text" => payload["text"],
        "confidence" => payload["confidence"],
        "status" => payload["status"] || "confirmed"
      }

      {:noreply, update(socket, :utterances, &(&1 ++ [utterance]))}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:event_appended, %{payload: %{"kind" => "MarkerAdded"} = payload}}, socket) do
    if socket.assigns.active_session && payload["session_id"] == socket.assigns.active_session.id do
      {:noreply, update(socket, :markers, &(&1 ++ [payload]))}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:event_appended, %{payload: %{"kind" => kind}}}, socket)
      when kind in ~w(
        CampaignUpdated SessionScheduled SessionStarted SessionEnded
        RecordingStateChanged InviteCreated InviteRevoked InviteRedeemed
        MemberRemoved EposEntryEdited
      ) do
    Process.send_after(self(), :reload, 150)
    {:noreply, socket}
  end

  def handle_info({:event_appended, _}, socket), do: {:noreply, socket}
  def handle_info(:reload, socket), do: {:noreply, load_snapshot(socket)}

  # ─── Internal helpers ──────────────────────────────────────────

  defp do_rec_start(socket) do
    case socket.assigns.active_session do
      nil ->
        session_id = UUIDv7.generate()
        existing_count = length(socket.assigns.sessions || [])

        {:ok, _} =
          EventLog.append(
            %{
              "kind" => Shared.Events.session_scheduled(),
              "id" => session_id,
              "campaign_id" => socket.assigns.campaign_id,
              "number" => existing_count + 1,
              "name" => "Session #{existing_count + 1}",
              "scheduled_for" => nil
            },
            nil
          )

        {:ok, _} =
          EventLog.append(
            %{"kind" => Shared.Events.session_started(), "id" => session_id},
            nil
          )

        {:noreply, socket}

      _active ->
        append_state(socket, "recording")
        {:noreply, socket}
    end
  end

  defp append_state(socket, state) do
    {:ok, _} =
      EventLog.append(
        %{
          "kind" => Shared.Events.recording_state_changed(),
          "session_id" => socket.assigns.active_session.id,
          "state" => state
        },
        nil
      )
  end

  # ─── Snapshot ──────────────────────────────────────────────────

  defp load_snapshot(socket) do
    scope = %{
      "kind" => "campaign",
      "id" => socket.assigns.campaign_id,
      "viewer_discord_id" => socket.assigns.current_user.discord_id
    }

    case Reader.read(scope) do
      {:ok, %{"forbidden" => true}} ->
        assign(socket, forbidden?: true)

      {:ok, %{"not_found" => true}} ->
        assign(socket, not_found?: true)

      {:ok, snap} ->
        c = snap["campaign"]

        socket
        |> assign(:waiting?, false)
        |> assign(:campaign, c)
        |> assign(:current_campaign, c)
        |> assign(:sessions, snap["sessions"] || [])
        |> assign(:members, snap["members"] || [])
        |> assign(:invites, snap["invites"] || [])
        |> assign(:active_session, deserialize_session(snap["active_session"]))
        |> assign(:utterances, snap["utterances"] || [])
        |> assign(:markers, snap["markers"] || [])
        |> assign(:epos, snap["epos"])
        |> assign(:epos_history, snap["epos_history"] || [])
        |> assign(:owner?, c["owner_discord_id"] == socket.assigns.current_user.discord_id)

      {:error, :no_worker} ->
        assign(socket, %{
          waiting?: true,
          campaign: nil,
          current_campaign: nil,
          sessions: [],
          members: [],
          invites: [],
          active_session: nil,
          utterances: [],
          markers: [],
          epos: nil,
          epos_history: [],
          owner?: false
        })

      {:error, reason} ->
        socket
        |> put_flash(:error, "Snapshot fehlgeschlagen: #{inspect(reason)}")
        |> assign(%{
          waiting?: false,
          campaign: nil,
          current_campaign: nil,
          sessions: [],
          members: [],
          invites: [],
          active_session: nil,
          utterances: [],
          markers: [],
          epos: nil,
          epos_history: [],
          owner?: false
        })
    end
  end

  defp deserialize_session(nil), do: nil

  defp deserialize_session(%{} = m) do
    %{
      id: m["id"],
      campaign_id: m["campaign_id"],
      number: m["number"],
      name: m["name"],
      status: String.to_atom(m["status"] || "scheduled"),
      scheduled_for: m["scheduled_for"],
      started_at: m["started_at"],
      ended_at: m["ended_at"]
    }
  end

  # ─── Render ────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col h-full">
      <.recording_bar owner?={@owner?} active_session={@active_session} />

      <%= if @invite_url do %>
        <div class="px-6 py-3 bg-accent/10 border-b border-accent/40 flex items-center gap-3">
          <span class="hero-link-mini w-4 h-4 text-accent"></span>
          <span class="text-sm text-ink-1">Einladungs-Link:</span>
          <input
            readonly
            value={@invite_url}
            onclick="this.select()"
            class="flex-1 bg-bg-0 border border-bg-3 rounded px-2 py-1 text-sm text-accent font-mono"
          />
          <button phx-click="clear_invite_url" class="btn !py-1 !px-2">×</button>
        </div>
      <% end %>

      <div class="flex-1 grid grid-cols-4 gap-px bg-bg-3/60 overflow-hidden">
        <.column title="Chronik" subtitle="">
          <%= if @waiting? do %>
            <.empty_col text="Warte auf Worker." />
          <% else %>
            <p class="text-ink-2 text-sm">
              Zeitstrahl (Stufe-4-LLM extrahiert In-Game-Daten). Kommt mit M8.
            </p>
            <%= for s <- @sessions do %>
              <div class="mt-3 pl-3 border-l border-accent/40">
                <div class="text-xs text-ink-2 uppercase">#{s["number"]} {s["status"]}</div>
                <div class="text-ink-0 text-sm">{s["name"]}</div>
              </div>
            <% end %>
          <% end %>
        </.column>

        <.column title="Resümee" subtitle="Was letztes Mal geschah">
          <.empty_col text="Stufe-2-LLM verdichtet hier nach jeder Session. (M8)" />
        </.column>

        <.epos_column
          owner?={@owner?}
          waiting?={@waiting?}
          epos={@epos}
          epos_history={@epos_history}
          epos_mode={@epos_mode}
          epos_draft={@epos_draft}
          epos_diff_seq={@epos_diff_seq}
        />

        <.column title="Protokoll" subtitle={protokoll_subtitle(@active_session)}>
          <%= cond do %>
            <% @waiting? -> %>
              <.empty_col text="Warte auf Worker." />
            <% @utterances == [] -> %>
              <.empty_col text={"Noch keine Utterances. Klick REC und feuere `mix lore.fake_session " <> @campaign_id <> "` in einer Shell."} />
            <% true -> %>
              <ol class="space-y-2">
                <%= for u <- @utterances do %>
                  <li class="text-xs">
                    <span class="text-ink-2 font-mono mr-2">{format_ts(u["timestamp"])}</span>
                    <span class="text-accent">{u["discord_id"]}</span>
                    <span class={[
                      "ml-1",
                      u["status"] == "pending" && "text-ink-2 italic"
                    ]}>
                      {u["text"]}
                    </span>
                  </li>
                <% end %>
              </ol>
          <% end %>
        </.column>
      </div>

      <div class="border-t border-bg-3/60 px-4 py-2 text-xs text-ink-2 flex items-center gap-3 bg-bg-1">
        <span class="uppercase tracking-widest">Mitspieler</span>
        <%= for m <- @members do %>
          <span class={["pill", m["role"] == "owner" && "pill-active"]}>
            {m["discord_id"]}
          </span>
        <% end %>

        <%= if @owner? do %>
          <div class="flex-1"></div>
          <button phx-click="create_invite" class="btn !py-1">
            <span class="hero-link-mini w-3 h-3"></span> Einladung
          </button>
        <% end %>
      </div>

      <%= if @owner? and Enum.any?(@invites, & &1["status"] == "active") do %>
        <div class="border-t border-bg-3/60 px-4 py-2 text-xs bg-bg-1">
          <div class="uppercase tracking-widest text-ink-2 mb-1">Offene Einladungen</div>
          <%= for inv <- @invites, inv["status"] == "active" do %>
            <div class="flex items-center gap-2 py-1">
              <span class="text-accent font-mono truncate">{inv["token"]}</span>
              <button
                phx-click="revoke_invite"
                phx-value-token={inv["token"]}
                class="ml-auto text-ink-2 hover:text-rec-soft"
              >
                Widerrufen
              </button>
            </div>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  defp recording_bar(assigns) do
    ~H"""
    <div class="flex items-center gap-3 px-6 py-3 bg-bg-1 border-b border-bg-3/60">
      <%= case rec_state(@active_session) do %>
        <% :recording -> %>
          <button phx-click="rec_pause" class="btn" disabled={not @owner?}>
            <span class="hero-pause w-4 h-4"></span> Pause
          </button>
          <button phx-click="rec_stop" class="btn btn-rec" disabled={not @owner?}>
            <span class="hero-stop-circle-solid w-4 h-4"></span> Stopp
          </button>
          <button phx-click="rec_marker" class="btn" disabled={not @owner?}>
            <span class="hero-bookmark w-4 h-4"></span> Marker
          </button>
          <span class="ml-2 text-rec-soft text-xs uppercase tracking-widest">● Aufnahme läuft</span>
        <% :paused -> %>
          <button phx-click="rec_resume" class="btn btn-rec" disabled={not @owner?}>
            <span class="hero-play w-4 h-4"></span> Resume
          </button>
          <button phx-click="rec_stop" class="btn" disabled={not @owner?}>
            <span class="hero-stop-circle w-4 h-4"></span> Stopp
          </button>
          <button phx-click="rec_marker" class="btn" disabled={not @owner?}>
            <span class="hero-bookmark w-4 h-4"></span> Marker
          </button>
          <span class="ml-2 text-ink-2 text-xs uppercase tracking-widest">|| Pause</span>
        <% _ -> %>
          <button phx-click="rec_start" class="btn btn-rec" disabled={not @owner?}>
            <span class="hero-stop-circle-solid w-4 h-4"></span> REC
          </button>
          <span class="ml-2 text-ink-2 text-xs uppercase tracking-widest">○ Keine aktive Session</span>
      <% end %>
      <div class="flex-1"></div>
      <span class="text-xs text-ink-2 font-mono">{elapsed(@active_session)}</span>
      <%= if @owner? do %>
        <button
          phx-click="shutdown_worker"
          data-confirm="Worker wirklich herunterfahren?"
          class="btn"
          title="Worker herunterfahren"
        >
          <span class="hero-power w-4 h-4"></span>
        </button>
      <% end %>
    </div>
    """
  end

  # ─── Epos column ───────────────────────────────────────────────

  defp epos_column(assigns) do
    ~H"""
    <div class="bg-bg-1 flex flex-col min-h-0">
      <div class="col-header">
        <span>The Epos</span>
        <%= cond do %>
          <% @owner? and @epos_mode == :view -> %>
            <button phx-click="epos_edit_start" class="text-accent text-xs hover:underline">
              Bearbeiten
            </button>
          <% @epos_mode == :edit -> %>
            <span class="text-ink-2 text-[10px] font-sans normal-case tracking-normal">Bearbeitet…</span>
          <% true -> %>
            <span class="text-ink-2 text-[10px] font-sans normal-case tracking-normal">Main Campaign Book</span>
        <% end %>
      </div>

      <div class="flex-1 overflow-y-auto p-4">
        <%= cond do %>
          <% @waiting? -> %>
            <p class="text-ink-2 text-sm italic">Warte auf Worker.</p>
          <% @epos_mode == :diff -> %>
            <.epos_diff history={@epos_history} target_seq={@epos_diff_seq} current={@epos} />
          <% @epos_mode == :edit -> %>
            <form phx-submit="epos_edit_save" class="space-y-2">
              <textarea
                name="content_md"
                class="w-full h-72 bg-bg-0 border border-bg-3 rounded p-2 text-sm font-mono text-ink-0 focus:border-accent focus:ring-0"
                phx-update="ignore"
                id="epos-textarea"
              ><%= @epos_draft %></textarea>
              <div class="flex justify-end gap-2">
                <button type="button" phx-click="epos_edit_cancel" class="btn !py-1">Abbrechen</button>
                <button type="submit" class="btn btn-primary !py-1">Speichern</button>
              </div>
            </form>
          <% @epos == nil or @epos["content_md"] in [nil, ""] -> %>
            <p class="text-ink-2 text-sm italic">
              Noch leer.<%= if @owner?, do: " Klick 'Bearbeiten' oben.", else: "" %>
            </p>
            <.epos_history_section history={@epos_history} />
          <% true -> %>
            <article class="text-ink-0 text-sm whitespace-pre-wrap leading-relaxed">{@epos["content_md"]}</article>
            <.epos_history_section history={@epos_history} />
        <% end %>
      </div>
    </div>
    """
  end

  defp epos_history_section(assigns) do
    ~H"""
    <%= if @history != [] do %>
      <div class="mt-6 pt-3 border-t border-bg-3/60">
        <div class="uppercase tracking-widest text-ink-2 text-[10px] mb-2">Versionen</div>
        <ul class="space-y-1">
          <%= for h <- @history do %>
            <li class="flex items-baseline gap-2 text-xs">
              <span class="font-mono text-ink-2">#{h["seq"]}</span>
              <span class="text-ink-1">{format_ts(h["edited_at"])}</span>
              <span class={["pill", source_pill(h["source"])]}>
                {h["source"] || "?"}
              </span>
              <button
                phx-click="epos_diff_open"
                phx-value-seq={h["seq"]}
                class="ml-auto text-accent hover:underline"
              >
                Diff
              </button>
            </li>
          <% end %>
        </ul>
      </div>
    <% end %>
    """
  end

  defp epos_diff(assigns) do
    current_md = (assigns.current && assigns.current["content_md"]) || ""

    target =
      Enum.find(assigns.history, fn h -> h["seq"] == assigns.target_seq end)

    target_md = (target && target["content_md"]) || ""

    diff =
      List.myers_difference(
        String.split(target_md, "\n"),
        String.split(current_md, "\n")
      )

    assigns = assign(assigns, diff: diff, target: target)

    ~H"""
    <div class="space-y-3">
      <div class="flex items-baseline justify-between">
        <h3 class="font-display text-sm tracking-wide">
          Diff: #{(@target && @target["seq"]) || "?"} → current
        </h3>
        <button phx-click="epos_diff_close" class="text-accent hover:underline text-xs">
          ← zurück zur Ansicht
        </button>
      </div>
      <div class="text-xs font-mono bg-bg-0 border border-bg-3 rounded p-3 overflow-x-auto whitespace-pre">
        <%= for {op, lines} <- @diff, line <- lines do %>
          <div class={diff_line_class(op)}>{diff_prefix(op)}{line}</div>
        <% end %>
      </div>
    </div>
    """
  end

  defp diff_line_class(:eq), do: "text-ink-2"
  defp diff_line_class(:del), do: "text-rec-soft bg-rec/10"
  defp diff_line_class(:ins), do: "text-emerald-300 bg-emerald-500/10"

  defp diff_prefix(:eq), do: "  "
  defp diff_prefix(:del), do: "- "
  defp diff_prefix(:ins), do: "+ "

  defp source_pill("manual"), do: "pill-archived"
  defp source_pill("llm"), do: "pill-new"
  defp source_pill(_), do: ""

  # ─── Helpers ──────────────────────────────────────────────────

  defp rec_state(nil), do: :idle
  defp rec_state(%{status: status}), do: status

  defp elapsed(%{started_at: started}) when not is_nil(started) do
    started_dt =
      case started do
        s when is_binary(s) ->
          case DateTime.from_iso8601(s) do
            {:ok, dt, _} -> dt
            _ -> nil
          end

        %DateTime{} = dt ->
          dt
      end

    case started_dt do
      nil ->
        "00:00:00"

      dt ->
        secs = DateTime.diff(DateTime.utc_now(), dt)
        h = div(secs, 3600)
        m = rem(div(secs, 60), 60)
        s = rem(secs, 60)

        :io_lib.format("~2..0B:~2..0B:~2..0B", [h, m, s])
        |> IO.iodata_to_binary()
    end
  end

  defp elapsed(_), do: "00:00:00"

  defp format_ts(nil), do: "--:--:--"

  defp format_ts(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> Calendar.strftime(dt, "%H:%M:%S")
      _ -> iso
    end
  end

  defp protokoll_subtitle(nil), do: "Live Transkript"
  defp protokoll_subtitle(%{number: n}), do: "Session #{n} · Live Transkript"

  attr :title, :string, required: true
  attr :subtitle, :string, default: ""
  slot :inner_block, required: true

  defp column(assigns) do
    ~H"""
    <div class="bg-bg-1 flex flex-col min-h-0">
      <div class="col-header">
        <span>{@title}</span>
        <%= if @subtitle != "" do %>
          <span class="text-ink-2 text-[10px] font-sans normal-case tracking-normal">
            {@subtitle}
          </span>
        <% end %>
      </div>
      <div class="flex-1 overflow-y-auto p-4">
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  defp empty_col(assigns) do
    ~H"""
    <p class="text-ink-2 text-sm italic">{@text}</p>
    """
  end
end
