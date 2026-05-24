defmodule Mix.Tasks.Lore.PrTest.Ports do
  @moduledoc false
  # Port-Allokation für PR-Test-Stacks.
  #
  # Discord-OAuth-Redirect-URIs sind für 4000-4007 eingetragen (siehe
  # CLAUDE.local.md). 4000 ist master-dev-hub, 4007 ist Reserve/ad-hoc,
  # 4001-4006 sind in Slot-Paare pro Worktree-cwd aufgeteilt (Issue #186).
  #
  # Slot-Tabelle lebt in CLAUDE.local.md (gitignored, per-Maschine). Format:
  #
  #     ## PR-Test-Port-Slots pro Worktree
  #     - /home/tom/Projekte/lore_tracker         → 4001, 4002
  #     - /home/tom/Projekte/lore_tracker2        → 4003, 4004
  #     - /home/tom/Projekte/lore_tracker_issues  → 4005, 4006
  #
  # `allocate!/0` matched den aktuellen `File.cwd!()` gegen die Tabelle und
  # liefert den ersten freien Port aus dem zugehörigen Slot.

  @doc "Sucht den ersten freien PR-Test-Port aus dem cwd-Slot. Raised wenn kein Slot konfiguriert oder beide Slot-Ports belegt."
  @spec allocate!() :: pos_integer()
  def allocate! do
    cwd = worktree_root!()
    slot_ports = slot_for_cwd!(cwd)
    occupied_from_doc = parse_occupied_from_claude_local(cwd)

    case Enum.find(slot_ports, &port_free?(&1, occupied_from_doc)) do
      nil ->
        Mix.raise("""
        Beide Slot-Ports #{inspect(slot_ports)} für Worktree #{cwd} belegt.

        Tear-down erst eine bestehende Instanz:

            mix lore.pr_test_down <port>
        """)

      port ->
        port
    end
  end

  @doc "Returns true wenn der Port lokal nicht in Listen-Mode ist UND nicht in CLAUDE.local.md gemarkt ist."
  def port_free?(port, occupied_from_doc) do
    port not in occupied_from_doc and not listen_socket_open?(port)
  end

  @doc """
  Liest aus CLAUDE.local.md den Port-Slot für den gegebenen cwd-Pfad.
  Raised mit klarer Anleitung wenn kein Slot definiert ist.
  """
  @spec slot_for_cwd!(String.t()) :: [pos_integer()]
  def slot_for_cwd!(cwd) do
    case slot_for_cwd(cwd) do
      [] ->
        Mix.raise("""
        Kein PR-Test-Port-Slot für Worktree #{cwd} in CLAUDE.local.md.

        Trag eine Zeile in der Sektion "PR-Test-Port-Slots pro Worktree" ein:

            - #{cwd} → <port1>, <port2>

        Verfügbare Ports laut Discord-OAuth-Redirect-Konfiguration: 4001-4006
        (4000 = master-dev-hub, 4007 = Reserve).
        """)

      ports ->
        ports
    end
  end

  defp slot_for_cwd(cwd) do
    case File.read(claude_local_path(cwd)) do
      {:ok, content} -> parse_slot_for_cwd(content, cwd)
      {:error, _} -> []
    end
  end

  defp claude_local_path(cwd), do: Path.join(cwd, "CLAUDE.local.md")

  # Parsed die "PR-Test-Port-Slots pro Worktree"-Sektion. Format:
  #
  #     - /pfad/zum/worktree → 4001, 4002
  #
  # Akzeptiert auch `->` statt `→` und beliebigen Whitespace.
  defp parse_slot_for_cwd(content, cwd) do
    case Regex.run(
           ~r/##\s*PR-Test-Port-Slots pro Worktree\s*\n(.+?)(?=\n##\s|\z)/s,
           content
         ) do
      [_, section] ->
        section
        |> String.split("\n")
        |> Enum.find_value([], fn line ->
          case Regex.run(~r/^\s*-\s*(\S+)\s*(?:→|->)\s*([\d,\s]+)$/, line) do
            [_, ^cwd, ports_str] -> parse_port_list(ports_str)
            _ -> nil
          end
        end)

      _ ->
        []
    end
  end

  defp parse_port_list(str) do
    str
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&String.to_integer/1)
  end

  # Worktree-Root via `git rev-parse --show-toplevel`. Notwendig weil
  # `File.cwd!()` z.B. `apps/hub` liefert wenn Mix aus dem App-Verzeichnis
  # aufgerufen wird, der Slot aber pro Worktree-Root in CLAUDE.local.md steht.
  defp worktree_root! do
    case System.cmd("git", ["rev-parse", "--show-toplevel"], stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      {_, _} -> File.cwd!()
    end
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

  defp parse_occupied_from_claude_local(cwd) do
    case File.read(claude_local_path(cwd)) do
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
        |> Enum.uniq()

      _ ->
        []
    end
  end
end
