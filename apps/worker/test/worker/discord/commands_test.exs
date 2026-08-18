defmodule Worker.Discord.CommandsTest do
  @moduledoc """
  Issue #1033: die Entscheidungen hinter `/lore start|stop|status` — pure, also
  ohne Discord-Verbindung prüfbar.
  """
  use ExUnit.Case, async: true

  alias Worker.Discord.Commands

  describe "declaration/0" do
    test "genau ein Command namens lore mit den drei Subcommands" do
      assert [%{name: "lore", options: options}] = Commands.declaration()

      assert Enum.map(options, & &1.name) == ["start", "stop", "status"]
      # Typ 1 = SUB_COMMAND. Ein falscher Typ wird von Discord mit 400
      # abgelehnt, und der Command taucht nie auf.
      assert Enum.all?(options, &(&1.type == 1))
    end

    test "jeder Subcommand hat die optionale Kampagnen-Option" do
      [%{options: subs}] = Commands.declaration()

      for sub <- subs do
        assert [%{name: "kampagne", type: 3, required: false}] = sub.options
      end
    end

    test "Beschreibungen sind gesetzt und innerhalb des Discord-Limits (100 Zeichen)" do
      [cmd] = Commands.declaration()

      texts =
        [cmd.description] ++
          Enum.flat_map(cmd.options, fn sub ->
            [sub.description | Enum.map(sub.options, & &1.description)]
          end)

      for t <- texts do
        assert String.length(t) > 0
        assert String.length(t) <= 100
      end
    end
  end

  describe "parse/1" do
    test "Subcommand ohne Option" do
      assert {:ok, :start, nil} =
               Commands.parse(%{name: "lore", options: [%{name: "start", options: []}]})
    end

    test "Subcommand mit Kampagnen-Option" do
      data = %{
        name: "lore",
        options: [%{name: "stop", options: [%{name: "kampagne", value: "Skandal"}]}]
      }

      assert {:ok, :stop, "Skandal"} = Commands.parse(data)
    end

    test "leere Option zählt als nicht gesetzt" do
      data = %{
        name: "lore",
        options: [%{name: "status", options: [%{name: "kampagne", value: "   "}]}]
      }

      assert {:ok, :status, nil} = Commands.parse(data)
    end

    test "fremder Command, unbekannter Subcommand und Müll ergeben :error" do
      assert :error = Commands.parse(%{name: "andere", options: []})
      assert :error = Commands.parse(%{name: "lore", options: [%{name: "loeschen"}]})
      assert :error = Commands.parse(%{name: "lore", options: []})
      assert :error = Commands.parse(%{})
      assert :error = Commands.parse(nil)
    end

    test "ein Button-Klick (custom_id statt name) fällt durch" do
      # Consent-Klicks kommen über dieselbe Event-Quelle — sie dürfen hier
      # niemals als Command durchgehen.
      assert :error = Commands.parse(%{custom_id: "consent:grant:v2:sess-1"})
    end
  end

  describe "resolve_campaign/2" do
    defp camp(id, name), do: %{id: id, name: name}

    test "keine Kampagne konfiguriert" do
      assert {:error, :none} = Commands.resolve_campaign([], nil)
      assert {:error, :none} = Commands.resolve_campaign([], "irgendwas")
    end

    test "genau eine Kampagne gewinnt auch gegen eine unpassende Eingabe" do
      only = camp("c1", "Skandal in Böhmen")

      assert {:ok, ^only} = Commands.resolve_campaign([only], nil)
      # Absicht: eine Fehleingabe soll den Spielabend nicht aufhalten, wenn es
      # ohnehin nur eine Wahl gibt.
      assert {:ok, ^only} = Commands.resolve_campaign([only], "tippfehler")
    end

    test "mehrere ohne Angabe sind mehrdeutig — und die Antwort nennt die Namen" do
      a = camp("c1", "Skandal in Böhmen")
      b = camp("c2", "Freies Seattle")

      assert {:error, {:ambiguous, names}} = Commands.resolve_campaign([a, b], nil)
      assert names == ["Skandal in Böhmen", "Freies Seattle"]

      text = Commands.resolve_error_text({:ambiguous, names})
      assert text =~ "Skandal in Böhmen"
      assert text =~ "Freies Seattle"
    end

    test "Auswahl per Namensteil, unabhängig von Groß-/Kleinschreibung" do
      a = camp("c1", "Skandal in Böhmen")
      b = camp("c2", "Freies Seattle")

      assert {:ok, ^b} = Commands.resolve_campaign([a, b], "seattle")
      assert {:ok, ^a} = Commands.resolve_campaign([a, b], "BÖHMEN")
    end

    test "Auswahl per ID-Präfix" do
      a = camp("abc123", "Erste")
      b = camp("xyz789", "Zweite")

      assert {:ok, ^b} = Commands.resolve_campaign([a, b], "xyz")
    end

    test "kein Treffer nennt die Alternativen" do
      a = camp("c1", "Erste")
      b = camp("c2", "Zweite")

      assert {:error, {:no_match, "dritte", names}} = Commands.resolve_campaign([a, b], "dritte")
      assert names == ["Erste", "Zweite"]
      assert Commands.resolve_error_text({:no_match, "dritte", names}) =~ "Erste"
    end

    test "mehrdeutiger Teiltreffer wird nicht geraten" do
      a = camp("c1", "Seattle Nord")
      b = camp("c2", "Seattle Süd")

      assert {:error, {:ambiguous, _}} = Commands.resolve_campaign([a, b], "seattle")
    end
  end

  describe "format_duration/1" do
    test "unter einer Stunde als MM:SS" do
      assert Commands.format_duration(0) == "00:00"
      assert Commands.format_duration(42) == "00:42"
      assert Commands.format_duration(150) == "02:30"
    end

    test "ab einer Stunde als H:MM:SS" do
      assert Commands.format_duration(3600) == "1:00:00"
      assert Commands.format_duration(7325) == "2:02:05"
    end

    test "negative Werte (Uhr-Sprung) werden geklemmt statt unsinnig angezeigt" do
      assert Commands.format_duration(-10) == "00:00"
    end
  end
end
