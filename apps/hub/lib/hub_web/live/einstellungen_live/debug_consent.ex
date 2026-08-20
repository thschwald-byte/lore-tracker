defmodule HubWeb.EinstellungenLive.DebugConsent do
  @moduledoc """
  Issue #144: der Debug-Zugriffs-Block am Ende von `/settings`.

  Aus `HubWeb.EinstellungenLive` herausgelöst (#1062/#1097). Der Schnitt ist
  kohäsiv und nicht bloss Zeilen-Verschieben: dieser Block hat mit Settings
  nichts zu tun — er gehört zur Admin-Debug-Einwilligung und teilt mit dem
  LiveView nur das `consent`-Assign. Die beiden Ereignisse (`debug_grant` /
  `debug_revoke`) bleiben dort, wo der Socket lebt.

  Anlass war der #1097-Ratschen-Check: die Datei durfte ihren Stand halten,
  aber nicht wachsen, und der Wartezeiten-Block brauchte eine Zeile. Statt die
  Zeile zu verstecken oder die Grenze anzuheben, wandert hier ein Teil heraus,
  der ohnehin nie dazugehörte.
  """

  use HubWeb, :html

  # Issue #144: Block zum Aktivieren von Admin-Debug-Zugriff. Der User
  # entscheidet selbst (5/15/60min), ein Admin darf solange seinen
  # Snapshot + Permission-Matrix via /admin/debug/campaign/:id einsehen.
  def block(assigns) do
    ~H"""
    <div class="mt-8 border-t border-bg-3/60 pt-6">
      <h2 class="text-sm font-semibold text-ink-0 uppercase tracking-wider mb-2">
        Debug-Zugriff
      </h2>
      <p class="text-xs text-ink-2 mb-3">
        Erlaubt einem Admin, deinen LV-State + deine Permissions in einer Kampagne
        zur Fehlerdiagnose einzusehen (Issue #144). Läuft automatisch ab.
      </p>

      <%= if @consent do %>
        <div class="flex items-center gap-3 text-xs">
          <span class="text-accent">⚡ aktiv</span>
          <span class="text-ink-2 font-mono">
            noch {verbleibend(@consent)}
          </span>
          <.btn variant="ghost" phx-click="debug_revoke">widerrufen</.btn>
        </div>
      <% else %>
        <div class="flex items-center gap-2">
          <.btn variant="ghost" phx-click="debug_grant" phx-value-duration="300">
            5 min
          </.btn>
          <.btn variant="ghost" phx-click="debug_grant" phx-value-duration="900">
            15 min
          </.btn>
          <.btn variant="ghost" phx-click="debug_grant" phx-value-duration="3600">
            1 h
          </.btn>
        </div>
      <% end %>
    </div>
    """
  end

  defp verbleibend(%{expires_at: %DateTime{} = at}) do
    diff = DateTime.diff(at, DateTime.utc_now(), :second)

    cond do
      diff <= 0 -> "—"
      diff < 60 -> "#{diff}s"
      diff < 3600 -> "#{div(diff, 60)}m #{rem(diff, 60)}s"
      true -> "#{div(diff, 3600)}h #{div(rem(diff, 3600), 60)}m"
    end
  end

  defp verbleibend(_), do: "—"
end
