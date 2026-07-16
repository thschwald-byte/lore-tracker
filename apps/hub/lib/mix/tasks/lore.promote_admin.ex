defmodule Mix.Tasks.Lore.PromoteAdmin do
  @moduledoc """
  Promoviert einen User zur globalen Rolle `:admin` (Issue #34).

  Bootstrap-Tool für existierende Instances ohne Auto-Admin-Trigger
  (oder wenn der Auto-Admin aus dem Pairing-Flow versagt hat, etwa
  wenn der ursprüngliche Admin sich gelöscht hat).

  Direkt am Hub: schickt das `UserRoleSet`-Event via `Hub.EventBridge`
  an einen online Worker, der es Worker-First-Apply'd + broadcastet
  (Issue #154 / Etappe 4c.3). Wenn kein Worker online ist, fail't der
  Task — startet einen Worker erst.

      mix lore.promote_admin <discord_id>
      mix lore.promote_admin <discord_id> --role spielleiter   # auch downgrades
      mix lore.promote_admin <discord_id> --role spieler

  Discord-ID ist die numerische Snowflake (z.B. `615614311255244801`).
  """

  use Mix.Task

  @shortdoc "Set the global role of a user (admin|spielleiter|spieler)."

  @valid_roles ~w(admin spielleiter spieler)

  @impl Mix.Task
  def run(args) do
    {opts, positional, _} =
      OptionParser.parse(args, switches: [role: :string], aliases: [r: :role])

    discord_id =
      case positional do
        [did] ->
          did

        _ ->
          Mix.raise(
            "usage: mix lore.promote_admin <discord_id> [--role admin|spielleiter|spieler]"
          )
      end

    role = opts[:role] || "admin"

    if role not in @valid_roles do
      Mix.raise("invalid role #{inspect(role)} — must be one of #{inspect(@valid_roles)}")
    end

    Mix.Task.run("app.start")

    case Hub.EventBridge.publish(%{
           "kind" => Shared.Events.user_role_set(),
           "discord_id" => discord_id,
           "role" => role,
           "set_by" => "cli:lore.promote_admin"
         }) do
      :ok ->
        Mix.shell().info("UserRoleSet delegated: #{discord_id} → :#{role}")

      {:error, :no_worker_online} ->
        Mix.raise(
          "Kein Worker online — kann UserRoleSet nicht delegieren. Starte erst einen Worker und versuche es erneut."
        )
    end
  end
end
