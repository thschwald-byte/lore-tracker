defmodule Worker.Discord.Consumer do
  @moduledoc """
  Issue #985 Slice 1 (Discord-Bot-Voice-Capture-Epic), Stage C: minimaler
  Nostrum-Consumer (main-API: `@behaviour Nostrum.Consumer` + `handle_event/1`,
  verifiziert am #941-Spike). Aktuell nur Boot-Sichtbarkeit — der eigentliche
  Guild-Join + Voice-Frame-Dispatch (an `Worker.Discord.BotSupervisor`) kommt
  mit Stage D. Bewusst additiv: das Fehlen einer Dispatch-Klausel darf nie
  crashen (Default-Klausel unten Pflicht, sonst FunctionClauseError bei jedem
  unmatched Gateway-Event).
  """

  @behaviour Nostrum.Consumer

  require Logger

  @impl true
  def handle_event({:READY, _data, _ws}) do
    Logger.info("Worker.Discord.Consumer: READY — Bot online.")
    :ok
  end

  # #941-Spike-Erkenntnis: erst wenn die Guild geladen ist, kennt Nostrum das
  # Guild→Shard-Mapping (join_channel schlägt auf :READY noch fehl). Bot-Start
  # liefert :GUILD_AVAILABLE, neu beigetretene Guilds :GUILD_CREATE — beide
  # nur geloggt, bis Stage D den echten Join verdrahtet.
  def handle_event({:GUILD_AVAILABLE, %{id: id}, _ws}) do
    Logger.debug("Worker.Discord.Consumer: GUILD_AVAILABLE guild_id=#{id}")
    :ok
  end

  def handle_event({:GUILD_CREATE, %{id: id}, _ws}) do
    Logger.debug("Worker.Discord.Consumer: GUILD_CREATE guild_id=#{id}")
    :ok
  end

  # Default-Klausel (Nostrum-main verlangt sie) — jedes unbehandelte Event
  # (inkl. :VOICE_INCOMING_PACKET vor Stage D) ist ein bewusster No-op.
  def handle_event(_event), do: :ok
end
