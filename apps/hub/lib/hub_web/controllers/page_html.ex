defmodule HubWeb.PageHTML do
  use HubWeb, :html

  def home(assigns) do
    ~H"""
    <main style="font-family: system-ui; max-width: 40rem; margin: 4rem auto; padding: 0 1rem;">
      <h1>LoreTracker Hub</h1>
      <p>
        Eingeloggt als <strong>{@current_user.display_name}</strong>
        <small>(Discord-ID {@current_user.discord_id})</small>
      </p>
      <p>Dashboard kommt in M4. Bis dahin: keiner deiner Worker liefert Daten.</p>
      <p><a href="/auth/logout">Logout</a></p>
    </main>
    """
  end
end
