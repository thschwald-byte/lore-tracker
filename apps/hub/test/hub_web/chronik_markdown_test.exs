defmodule HubWeb.ChronikMarkdownTest do
  @moduledoc """
  Issue #385: Edit-Form ist eine Markdown-Textarea, Inhalt folgt der
  Konvention `# Datum\\n## Titel\\n\\nBody`. H1 + H2 sind syntaktisch
  eindeutig getrennt — kein Delimiter-Konflikt.
  """

  use ExUnit.Case, async: true

  alias HubWeb.CampaignLive.StageEdits

  describe "chronik_entry_to_markdown/1 — Convert für Edit-Draft" do
    test "markdown_body bevorzugt, verbatim zurück" do
      entry = %{
        "in_game_date" => "Tag 2",
        "label" => "Schwur",
        "summary" => "Plaintext-Bestand",
        "markdown_body" => "# Tag 2\n## Schwur am Balkon\n\nRomeo trifft Julia."
      }

      assert StageEdits.chronik_entry_to_markdown(entry) ==
               "# Tag 2\n## Schwur am Balkon\n\nRomeo trifft Julia."
    end

    test "kein markdown_body → aus den 3 alten Feldern zusammengesetzt" do
      entry = %{
        "in_game_date" => "Tag 2",
        "label" => "Schwur am Balkon",
        "summary" => "Romeo trifft Julia.",
        "markdown_body" => nil
      }

      assert StageEdits.chronik_entry_to_markdown(entry) ==
               "# Tag 2\n## Schwur am Balkon\n\nRomeo trifft Julia."
    end

    test "markdown_body leerer String → Fallback auf 3 alte Felder" do
      entry = %{
        "in_game_date" => "Tag 2",
        "label" => "X",
        "summary" => "Y",
        "markdown_body" => ""
      }

      assert StageEdits.chronik_entry_to_markdown(entry) =~ "# Tag 2"
      assert StageEdits.chronik_entry_to_markdown(entry) =~ "## X"
      assert StageEdits.chronik_entry_to_markdown(entry) =~ "Y"
    end

    test "leere Felder werden weggelassen (Datum-only)" do
      entry = %{
        "in_game_date" => "Tag 1",
        "label" => "",
        "summary" => "Body-Text",
        "markdown_body" => nil
      }

      result = StageEdits.chronik_entry_to_markdown(entry)
      assert result =~ "# Tag 1"
      refute result =~ "## "
      assert result =~ "Body-Text"
    end

    test "alles leer → leerer String" do
      entry = %{"in_game_date" => "", "label" => "", "summary" => "", "markdown_body" => nil}
      assert StageEdits.chronik_entry_to_markdown(entry) == ""
    end
  end

  describe "parse_chronik_headings/2 — Save derived Date+Label" do
    test "beide Headings vorhanden → date + label aus H1 + H2" do
      md = "# Tag 2\n## Schwur am Balkon\n\nRomeo trifft Julia."
      existing = %{"in_game_date" => "old-date", "label" => "old-label"}

      assert {"Tag 2", "Schwur am Balkon"} = StageEdits.parse_chronik_headings(md, existing)
    end

    test "nur H1 vorhanden → label bleibt alt" do
      md = "# Tag 2\n\nNur Body."
      existing = %{"in_game_date" => "old", "label" => "alter-titel"}

      assert {"Tag 2", "alter-titel"} = StageEdits.parse_chronik_headings(md, existing)
    end

    test "nur H2 vorhanden → date bleibt alt" do
      md = "## Schwur\n\nNur Body."
      existing = %{"in_game_date" => "altes-datum", "label" => "old"}

      assert {"altes-datum", "Schwur"} = StageEdits.parse_chronik_headings(md, existing)
    end

    test "kein Heading → beide bleiben alt (nicht-destruktiv)" do
      md = "Nur Body ohne Heading."
      existing = %{"in_game_date" => "altes-datum", "label" => "alter-titel"}

      assert {"altes-datum", "alter-titel"} = StageEdits.parse_chronik_headings(md, existing)
    end

    test "leerer Markdown → beide bleiben alt" do
      existing = %{"in_game_date" => "X", "label" => "Y"}
      assert {"X", "Y"} = StageEdits.parse_chronik_headings("", existing)
    end

    test "H1 mit Sonderzeichen / Doppelpunkt im Datum (kein Konflikt mit H2)" do
      md = "# Tag 3, 14:30 Uhr\n## Sitzung Nr. 5\n\nBody."
      existing = %{"in_game_date" => "", "label" => ""}

      # Datum darf Doppelpunkte enthalten — H1 vs H2 sind syntaktisch getrennt,
      # kein Delimiter-Konflikt wie beim `:`-Approach aus Plan-v2-Review.
      assert {"Tag 3, 14:30 Uhr", "Sitzung Nr. 5"} =
               StageEdits.parse_chronik_headings(md, existing)
    end

    test "Roundtrip-Identität: to_markdown → parse → identische Werte" do
      entry = %{
        "in_game_date" => "Tag 5",
        "label" => "Tybalts Tod",
        "summary" => "Body-Text-hier.",
        "markdown_body" => nil
      }

      md = StageEdits.chronik_entry_to_markdown(entry)

      {date, label} =
        StageEdits.parse_chronik_headings(md, %{"in_game_date" => "", "label" => ""})

      assert date == "Tag 5"
      assert label == "Tybalts Tod"
    end

    test "Datum-only-Roundtrip funktioniert (Tom-Review-Bug aus v2 gefixt)" do
      # Bei v2 mit `:` als Delimiter wurde Datum-only-Eintrag beim Save
      # zerstört. Mit H1/H2-Trennung kein Risiko.
      entry = %{
        "in_game_date" => "Tag 3",
        "label" => "",
        "summary" => "Nur Body, kein Titel.",
        "markdown_body" => nil
      }

      md = StageEdits.chronik_entry_to_markdown(entry)

      {date, label} =
        StageEdits.parse_chronik_headings(md, %{"in_game_date" => "old", "label" => "old"})

      assert date == "Tag 3"
      # Label war "" → markdown enthält keinen H2 → existing-label bleibt
      assert label == "old"
    end
  end
end
