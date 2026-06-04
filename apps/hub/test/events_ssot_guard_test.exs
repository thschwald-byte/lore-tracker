defmodule Hub.EventsSsotGuardTest do
  @moduledoc """
  Issue #471: Drift-Guard für die Event-Kind-SSoT.

  Jeder im Umbrella-Code (`"kind" => "..."`) und in den Seed-Fixtures (JSONL
  `"kind": "..."`) vorkommende Event-Kind-String muss in `Shared.Events.all/0`
  sein. Damit bricht ein Kind-Rename in `apps/shared/lib/shared/events.ex`, der
  Producer/Consumer/Seeds NICHT mitzieht, **laut** (Test rot) statt still
  (Wire-Drift zwischen Hub und Worker). Ergänzt den Materializer-Consumer-Guard
  + `all/0` + Catch-all aus PR #491 um die Producer-/Seed-Seite.

  Liegt in `apps/hub/test`, weil die CI nur die Hub-Suite fährt
  (`mix cmd --app hub mix test`) — der Test scannt aber das ganze Umbrella.
  """
  use ExUnit.Case, async: true

  # apps/hub/test → apps/hub → apps → <umbrella-root>
  @root Path.expand("../../..", __DIR__)

  test "jedes \"kind\"-Literal in Code + Seeds ist ein gültiger Shared.Events-Kind" do
    valid = MapSet.new(Shared.Events.all())

    # Nur PascalCase-Werte = Event-Kinds (so filtert auch Shared.Events.all/0).
    # `"kind" => "campaign"`/`"settings"`/… sind andere, lowercase `kind`-Felder
    # (Nav/Settings/Job-Kind) und keine Event-Kinds.
    code_hits =
      Path.wildcard(Path.join(@root, "apps/*/lib/**/*.{ex,exs}"))
      |> Enum.flat_map(&scan(&1, ~r/"kind"\s*=>\s*"([A-Z][A-Za-z0-9]+)"/))

    seed_hits =
      Path.wildcard(Path.join(@root, "apps/hub/priv/seeds/**/*.jsonl"))
      |> Enum.flat_map(&scan(&1, ~r/"kind"\s*:\s*"([A-Z][A-Za-z0-9]+)"/))

    violations =
      (code_hits ++ seed_hits)
      |> Enum.reject(fn {_f, _l, kind} -> MapSet.member?(valid, kind) end)
      |> Enum.uniq()

    assert violations == [],
           "Event-Kind-Literale, die NICHT in Shared.Events.all() sind " <>
             "(Rename-Drift?):\n" <>
             Enum.map_join(violations, "\n", fn {f, l, k} ->
               "  #{Path.relative_to(f, @root)}:#{l}  #{inspect(k)}"
             end)
  end

  defp scan(file, regex) do
    file
    |> File.stream!()
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, lineno} ->
      regex
      |> Regex.scan(line)
      |> Enum.map(fn [_full, kind] -> {file, lineno, kind} end)
    end)
  end
end
