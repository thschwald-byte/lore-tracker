# Vox Machina Demo Seed — Prod-Push via worker_prod RPC-Bridge
#
# Liest die JSONL-Seed-Dateien aus apps/hub/priv/seeds/vox-machina/ und
# schickt jeden Event via RPC durch den lokalen worker_prod-BEAM-Node auf den
# Gigalixir-Hub. Voraussetzung: worker_prod läuft und ist mit Prod verbunden.
#
# Usage (vom Repo-Root):
#
#   elixir --sname seeder --cookie "$(cat ~/.erlang.cookie)" --hidden \
#     -r scripts/seed_vox_machina_prod.exs
#
# Mit --reset (löscht vox-machina-demo erst, dann re-seed):
#
#   elixir --sname seeder --cookie "$(cat ~/.erlang.cookie)" --hidden \
#     -r scripts/seed_vox_machina_prod.exs -- --reset
#
# Nur Protocol-Events (ohne LLM-Output: Resümees, Epos, Chronik):
#
#   elixir --sname seeder --cookie "$(cat ~/.erlang.cookie)" --hidden \
#     -r scripts/seed_vox_machina_prod.exs -- --protocol-only

Mix.install([{:jason, "~> 1.4"}])

# ─── Config ────────────────────────────────────────────────────────────────

node = :"worker_prod@cachyos-x8664"
seed_dir = Path.join([File.cwd!(), "apps", "hub", "priv", "seeds", "vox-machina"])
campaign_id = "vox-machina-demo"

args = System.argv()
reset? = "--reset" in args
protocol_only? = "--protocol-only" in args

llm_output_kinds = ~w(SessionSummaryGenerated EposEntryEdited ChronikEntryChanged)

# ─── Helpers ────────────────────────────────────────────────────────────────

defmodule SeedHelper do
  def rpc_publish(node, payload, retries \\ 2) do
    case :rpc.call(node, Worker.Intents, :publish, [payload], 15_000) do
      {:ok, seq} ->
        {:ok, seq}

      {:badrpc, reason} when retries > 0 ->
        IO.write(" [retry]")
        Process.sleep(500)
        rpc_publish(node, payload, retries - 1)

      {:badrpc, reason} ->
        {:error, {:badrpc, reason}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end

# ─── Connectivity check ─────────────────────────────────────────────────────

IO.puts("Checking connectivity to #{node}...")

case :net_adm.ping(node) do
  :pong ->
    IO.puts("  ✓ #{node} reachable")

  :pang ->
    IO.puts("""
      ✗ Cannot reach #{node}

      Make sure worker_prod is running:
        cd apps/worker && LORE_MNESIA_DIR=/home/tom/Projekte/lore_tracker/priv/mnesia/prod-worker \\
          HUB_BASE_URL=https://loretracker.gigalixirapp.com \\
          elixir --sname worker_prod --no-halt -S mix run
    """)
    System.halt(1)
end

# ─── Optional reset ─────────────────────────────────────────────────────────

if reset? do
  IO.write("Sending CampaignDeleted (reset)... ")

  case SeedHelper.rpc_publish(node, %{"kind" => "CampaignDeleted", "campaign_id" => campaign_id, "deleted_by" => "cli:seed_vox_machina_prod.exs"}) do
    {:ok, seq} ->
      IO.puts("✓ seq=#{seq}")
      Process.sleep(200)

    {:error, reason} ->
      IO.puts("✗ #{inspect(reason)} (continuing anyway)")
  end
end

# ─── Seed files ─────────────────────────────────────────────────────────────

files = Path.join(seed_dir, "*.jsonl") |> Path.wildcard() |> Enum.sort()

if files == [] do
  IO.puts("ERROR: no .jsonl files found in #{seed_dir}")
  System.halt(1)
end

IO.puts("Seeding #{length(files)} file(s) from #{seed_dir}")
IO.puts(if protocol_only?, do: "Mode: protocol-only (skipping LLM-output events)", else: "Mode: full")
IO.puts("")

total_events = 0
total_skipped = 0

{total_events, total_skipped} =
  Enum.reduce(files, {0, 0}, fn file, {total, skipped} ->
    basename = Path.basename(file)
    IO.write("  #{basename}  ")

    {file_count, file_skipped} =
      file
      |> File.stream!()
      |> Stream.map(&String.trim/1)
      |> Stream.reject(&(&1 == ""))
      |> Stream.reject(&String.starts_with?(&1, "#"))
      |> Enum.reduce({0, 0}, fn line, {count, sk} ->
        payload = Jason.decode!(line)
        kind = payload["kind"]

        if protocol_only? and kind in llm_output_kinds do
          {count, sk + 1}
        else
          case SeedHelper.rpc_publish(node, payload) do
            {:ok, _seq} ->
              IO.write(".")
              # Small pause to avoid flooding the channel
              Process.sleep(50)
              {count + 1, sk}

            {:error, reason} ->
              IO.puts("\n  ✗ FAILED kind=#{kind}: #{inspect(reason)}")
              {count + 1, sk}
          end
        end
      end)

    IO.puts("  #{file_count} sent#{if file_skipped > 0, do: ", #{file_skipped} skipped", else: ""}")
    {total + file_count, skipped + file_skipped}
  end)

IO.puts("")
IO.puts("Done. Total: #{total_events} events sent#{if total_skipped > 0, do: ", #{total_skipped} skipped", else: ""}.")
IO.puts("Campaign vox-machina-demo should now be visible for discord_id=615614311255244801 on prod.")
