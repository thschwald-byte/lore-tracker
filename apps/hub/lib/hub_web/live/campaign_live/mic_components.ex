defmodule HubWeb.CampaignLive.MicComponents do
  @moduledoc """
  Issue #987 (God-Module-Split aus `HubWeb.CampaignLive.Components`, #544-
  Budget): die Recording-Bar + Mikro-Beitritts-UI (`recording_bar/1`,
  `mic_controls/1`, `mic_button_state/3`, `rec_state/1`, `elapsed/1`) — eine
  in sich geschlossene, nur untereinander verwendete Gruppe (Muster
  `DiscordConfigFolds`/`FlagFolds`: Dünn-Extraktion entlang einer
  Verantwortlichkeit, kein Feature-Änderung).

  `import`et in `HubWeb.CampaignLive` neben `Components`, damit
  `campaign_live.html.heex`s `<.recording_bar .../>` unqualifiziert
  auflöst — exakt dasselbe Multi-Import-Muster wie `Editors`/`GapMarker`.
  """
  use HubWeb, :html

  alias HubWeb.CampaignLive.Components

  def recording_bar(assigns) do
    ~H"""
    <div class="flex items-center gap-3 px-6 py-3 bg-bg-1 border-b border-bg-3/60">
      <%= case rec_state(@active_session) do %>
        <% :recording -> %>
          <.ls_icon_btn_compat kind={:rec_pause} size={:md} phx-click="rec_pause" disabled={not @owner?} title="Aufnahme pausieren" />
          <.ls_icon_btn_compat kind={:rec_stop} size={:lg} phx-click="rec_stop" disabled={not @owner?} title="Session beenden" />
          <.ls_icon_btn_compat kind={:marker} size={:md} phx-click="rec_marker" disabled={not @owner?} title="Szenen-Marker setzen" />
          <%!-- Issue #642: „Session läuft" (grün) bleibt IMMER sichtbar, solange die
                Session offen ist — auch während aufgenommen wird. Das rote „Aufnahme
                läuft" kommt ZUSÄTZLICH, sobald ≥1 Mikro tatsächlich streamt. --%>
          <span class="ml-2 text-success text-xs uppercase tracking-widest">● Session läuft</span>
          <span :if={@mic_streamers != []} class="ml-1 text-rec-soft text-xs uppercase tracking-widest">
            ● Aufnahme läuft
          </span>
        <% :paused -> %>
          <.ls_icon_btn_compat kind={:rec_resume} size={:lg} phx-click="rec_resume" disabled={not @owner?} title="Aufnahme fortsetzen" />
          <.ls_icon_btn_compat kind={:rec_stop} size={:lg} phx-click="rec_stop" disabled={not @owner?} title="Aufnahme stoppen" />
          <.ls_icon_btn_compat kind={:marker} size={:md} phx-click="rec_marker" disabled={not @owner?} title="Szenen-Marker setzen" />
          <span class="ml-2 text-ink-2 text-xs uppercase tracking-widest">|| Pause</span>
        <% _ -> %>
          <.ls_icon_btn_compat
            kind={:rec_start}
            size={:lg}
            phx-click="rec_start"
            disabled={not @owner?}
            title="Session starten — danach per Mikro beitreten (einzeln oder Raummikro)"
          />
          <span class="ml-2 text-ink-2 text-xs uppercase tracking-widest">○ Keine aktive Session</span>
      <% end %>
      <div class="flex-1"></div>
      <.mic_controls
        active_session={@active_session}
        mic_on?={@mic_on?}
        recording_here?={@recording_here?}
        mic_streamers={@mic_streamers}
        mic_levels={@mic_levels}
        current_discord_id={@current_discord_id}
        users={@users}
      />
      <span class="text-xs text-ink-2 font-mono">{elapsed(@active_session, @clock_tick)}</span>
      <button
        id="col-sync-toggle-btn"
        type="button"
        title="Referenzen"
        class="inline-flex items-center justify-center w-8 h-8 rounded-md border border-white/10 text-fg bg-transparent hover:bg-surface-2 hover:text-primary transition-colors duration-150 text-xs font-mono font-bold"
      >
        R
      </button>
      <%= if @owner? do %>
        <.ls_icon_btn_compat
          kind={:power}
          size={:sm}
          phx-click="shutdown_worker"
          data-confirm="Worker wirklich herunterfahren?"
          title="Worker herunterfahren"
        />
      <% end %>
    </div>
    """
  end

  # Issue #415: Drei-Wege-Mikro-Button.
  #   :stop     — DIESER Browser nimmt gerade auf (recording_here?).
  #   :takeover — der Account nimmt auf einem ANDEREN Gerät auf (in Streamer-
  #               Liste, aber nicht hier) → „Hier übernehmen".
  #   :join     — niemand auf diesem Account nimmt auf → normal beitreten.
  # recording_here? hat Vorrang: lokales Recording schlägt die Streamer-Liste,
  # damit das aufnehmende Gerät nie fälschlich „übernehmen" zeigt.
  @doc false
  def mic_button_state(recording_here?, current_discord_id, mic_streamers) do
    cond do
      recording_here? -> :stop
      current_discord_id in (mic_streamers || []) -> :takeover
      true -> :join
    end
  end

  def mic_controls(assigns) do
    ~H"""
    <%= if @active_session do %>
      <div class="flex items-center gap-2">
        <span class="text-xs text-ink-2 font-mono">
          🎙 {length(@mic_streamers)} streamen
        </span>
        <%!-- Issue #391: pro Streamer Name + Live-VU-Bar. --%>
        <span
          :for={did <- @mic_streamers}
          class="flex items-center gap-1 text-[10px] text-ink-2 font-mono"
          title={Components.display_for(did, @users)}
        >
          <span class="truncate max-w-[8rem]">{Components.display_for(did, @users)}</span>
          <.vu_bar level={Map.get(@mic_levels, did, 0.0)} class="w-10" />
        </span>
        <%!-- Issue #415: Drei-Wege. recording_here? = DIESER Browser nimmt auf
              (browser-lokal, MicCapture-Hook). Account in Streamer-Liste, aber
              nicht hier → Aufnahme läuft auf einem anderen Gerät → „Hier
              übernehmen" (mic_join; der Supersede-Broadcast stoppt das andere
              Gerät beim Start). --%>
        <%= case mic_button_state(@recording_here?, @current_discord_id, @mic_streamers) do %>
          <% :stop -> %>
            <.ls_icon_btn_compat kind={:mic_off} size={:md} phx-click="mic_leave" title="Mein Mikro stoppen" />
          <% :takeover -> %>
            <.btn phx-click="mic_join" title="Aufnahme von deinem anderen Gerät hierher übernehmen">
              ⇄ Hier übernehmen
            </.btn>
          <% :join -> %>
            <%!-- Issue #987: 3-Wege-Modus-Wahl beim ersten Beitritt der Session —
                  Discord/Single/Multi. Discord XOR Browser-Mikro (single+multi) für
                  die GANZE Session, session-weit für ALLE (nicht nur diesen Client),
                  daher @active_session.capture_mode statt lokalem Assign. --%>
            <%= case @active_session.capture_mode do %>
              <% "discord" -> %>
                <span
                  class="text-xs text-ink-2 font-mono"
                  title="Discord-Bot nimmt für diese Session auf — Browser-Mikro ist deaktiviert"
                >
                  🤖 Discord nimmt auf
                </span>
              <% mode -> %>
                <button
                  :if={mode == nil}
                  type="button"
                  phx-click="mic_choose_discord"
                  title="Discord-Bot für diese Session nutzen (schließt Browser-Mikro für alle aus)"
                  aria-label="Discord-Bot nutzen"
                  class="inline-flex items-center justify-center w-9 h-9 rounded-md border border-white/10 text-fg bg-transparent hover:bg-surface-2 hover:text-primary transition-colors duration-150"
                >
                  🤖
                </button>
                <.ls_icon_btn_compat kind={:mic_on} size={:md} phx-click="mic_join" title="Mit Mikro beitreten" />
                <%!-- Issue #642: Raummikro-Beitritt neben dem Per-Spieler-Mikro. Tooltip
                      per title; beide dürfen gleichzeitig in derselben Session laufen. --%>
                <button
                  type="button"
                  phx-click="mic_join_multi"
                  title="Mikro für mehrere Sprecher (Raummikro — eine Spur, danach automatisch in Sprecher getrennt)"
                  aria-label="Mikro für mehrere Sprecher"
                  class="inline-flex items-center justify-center w-9 h-9 rounded-md border border-white/10 text-fg bg-transparent hover:bg-surface-2 hover:text-primary transition-colors duration-150"
                >
                  🎙👥
                </button>
            <% end %>
        <% end %>
      </div>
    <% end %>
    """
  end

  def rec_state(nil), do: :idle
  def rec_state(%{status: status}), do: status

  # Issue #987: `_tick` wird bewusst NICHT für die Berechnung gebraucht
  # (die läuft rein über `DateTime.utc_now/0`) — sein einziger Zweck ist,
  # dass dieser Ausdruck im Template an `@clock_tick` hängt, damit LiveViews
  # Change-Tracking ihn bei jedem Sekunden-Tick neu auswertet. Ohne diesen
  # zweiten Parameter hängt der Ausdruck NUR an `@active_session`, das sich
  # während einer laufenden Session nicht ändert — die Uhr blieb stehen
  # (echter Live-Test-Fund, s. `Recording.on_elapsed_tick/1`).
  def elapsed(session, _tick \\ nil)

  def elapsed(%{started_at: started}, _tick) when not is_nil(started) do
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

  def elapsed(_, _tick), do: "00:00:00"
end
