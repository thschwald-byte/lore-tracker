defmodule Mix.Tasks.Lore.PrTest.Ports do
  @moduledoc false
  # Port-Allokation für PR-Test-Stacks.
  #
  # Discord-OAuth-Redirect-URIs sind nur für 4001 + 4002 eingetragen (siehe
  # CLAUDE.local.md). Daher Port-Pool fix auf {4001, 4002}.
  #
  # Belegt-Check: liest CLAUDE.local.md-Sektion "Currently running PR-test
  # instances" + macht zusätzlich einen Listen-Probe-Check via :gen_tcp.

  @pr_ports [4001, 4002]
  @claude_local Path.expand("CLAUDE.local.md")

  @doc "Sucht den ersten freien PR-Test-Port. Raised wenn alle belegt."
  @spec allocate!() :: 4001 | 4002
  def allocate! do
    occupied_from_doc = parse_occupied_from_claude_local()

    case Enum.find(@pr_ports, &port_free?(&1, occupied_from_doc)) do
      nil ->
        Mix.raise(
          "Beide PR-Test-Ports (4001, 4002) belegt. Tear-down erst: mix lore.pr_test_down <port>"
        )

      port ->
        port
    end
  end

  @doc "Returns true wenn der Port lokal nicht in Listen-Mode ist UND nicht in CLAUDE.local.md gemarkt ist."
  def port_free?(port, occupied_from_doc) do
    port not in occupied_from_doc and not listen_socket_open?(port)
  end

  defp listen_socket_open?(port) do
    case :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 200) do
      {:ok, sock} ->
        :gen_tcp.close(sock)
        true

      {:error, _} ->
        false
    end
  end

  defp parse_occupied_from_claude_local do
    case File.read(@claude_local) do
      {:ok, content} -> parse_ports_from_section(content)
      {:error, _} -> []
    end
  end

  # Liest die "Currently running PR-test instances"-Sektion und sucht nach
  # active-stack-Marker-Zeilen — Format `- Port <NNNN>: branch ...` (so
  # schreibt der Runner sie rein). Historische Erwähnungen im "_None._"-
  # Kommentar bleiben unbeachtet.
  defp parse_ports_from_section(content) do
    case Regex.run(
           ~r/##\s*Currently running PR-test instances\s*\n(.+?)(?=\n##\s|\z)/s,
           content
         ) do
      [_, section] ->
        Regex.scan(~r/^\s*-\s*Port\s+(\d+)\s*:\s*branch/m, section)
        |> Enum.map(fn [_, p] -> String.to_integer(p) end)
        |> Enum.filter(&(&1 in @pr_ports))
        |> Enum.uniq()

      _ ->
        []
    end
  end
end
