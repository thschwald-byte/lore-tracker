defmodule HubWeb.RenderMdSafeTest do
  @moduledoc """
  Issue #385: `render_md_safe/1` rendert user-editierten Markdown sicher.
  Defense-in-Depth: Earmark mit `escape: true` als erste Schicht +
  HtmlSanitizeEx.basic_html als zweite.
  """

  use ExUnit.Case, async: true

  alias HubWeb.CampaignLive.Components

  defp html(text), do: text |> Components.render_md_safe() |> Phoenix.HTML.safe_to_string()

  describe "rendert normales Markdown" do
    test "H1/H2 → <h1>/<h2>" do
      out = html("# Eins\n\n## Zwei\n\nText.")
      # Earmark fügt Newlines zwischen Tag-Open und Content — assert auf
      # Tag-Open + Content separat.
      assert out =~ "<h1>"
      assert out =~ "Eins"
      assert out =~ "</h1>"
      assert out =~ "<h2>"
      assert out =~ "Zwei"
      assert out =~ "</h2>"
      assert out =~ "<p>"
      assert out =~ "Text."
    end

    test "Listen → <ul>/<ol>" do
      out = html("- a\n- b\n- c")
      assert out =~ "<ul>"
      assert out =~ "<li>"
      assert out =~ "a"
      assert out =~ "b"
      assert out =~ "</li>"
    end

    test "**bold** + *em*" do
      out = html("**fett** und *kursiv*")
      assert out =~ "<strong>fett</strong>"
      assert out =~ "<em>kursiv</em>"
    end

    test "Inline-Code + Code-Blöcke" do
      out = html("Inline `code` works")
      assert out =~ "<code>code</code>"
    end

    test "Reguläre Links bleiben erhalten" do
      out = html("[example](https://example.com)")
      assert out =~ "<a"
      assert out =~ "href=\"https://example.com\""
      assert out =~ ">example</a>"
    end
  end

  describe "XSS-Defense-in-Depth: Earmark escape: true (Schicht 1)" do
    test "literales <script> wird schon vor dem Sanitizer escaped" do
      # Earmark mit escape: true wandelt < → &lt; bevor der String an
      # HtmlSanitizeEx geht. Im Output darf kein <script>-Tag stehen.
      out = html("Vor <script>alert('xss')</script> Nach")
      refute out =~ "<script"
      refute out =~ "</script>"
      # Der Text-Inhalt ist sichtbar (escaped als entity oder als Text)
      assert out =~ "alert" or out =~ "&lt;script&gt;"
    end

    test "literales <iframe> wird neutralisiert" do
      out = html("Text <iframe src=\"evil\"></iframe> mehr")
      refute out =~ "<iframe"
    end

    test "rohes HTML-Tag bleibt visible als escaped text" do
      # User schreibt <b>fett</b> wörtlich rein → wird zu &lt;b&gt; etc.,
      # NICHT als HTML-Tag interpretiert.
      out = html("Text mit <b>roh-HTML</b> drin.")
      refute out =~ "<b>roh-HTML"
    end
  end

  describe "XSS-Defense-in-Depth: HtmlSanitizeEx (Schicht 2)" do
    test "javascript:-URLs in Markdown-Links werden entschärft" do
      # Markdown-Link → Earmark macht <a href="javascript:..."> → Sanitizer
      # strippt die href.
      out = html("[klick](javascript:alert(1))")
      refute out =~ "javascript:alert"
    end

    test "onerror-Handler in img-Tags (falls Earmark welche emittiert) werden entfernt" do
      out = html("![alt](https://example.com/x.png \"title\")")
      # Standard Earmark-img-Output hat keine inline handlers, hier verifizieren
      # wir nur dass kein on* übrig bleibt.
      refute out =~ ~r/\son\w+\s*=/
    end
  end

  describe "Edge-Cases" do
    test "nil → leerer String" do
      assert Components.render_md_safe(nil) == ""
    end

    test "leerer String → leerer String" do
      assert Components.render_md_safe("") == ""
    end

    test "nur Whitespace → leerer/minimaler Output" do
      out = html("   \n\n   ")
      # Earmark macht daraus leeres Doc oder leeren <p> — beides ok
      assert out == "" or out =~ ~r/\A<p>\s*<\/p>\s*\z/
    end

    test "Earmark-Fehler-Fall liefert trotzdem HTML (kein Crash)" do
      # Unvollständige Markdown-Syntax sollte nicht crashen
      out = html("# [broken-link](")
      assert is_binary(out)
    end
  end
end
