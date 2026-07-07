defmodule HubWeb.RenderRecapWithFlagsTest do
  @moduledoc """
  Issue #715: `render_recap_with_flags/2` markiert vom Render-Gate geflaggte
  Claims dezent im Recap. Erbt XSS-Defense von `render_md_safe/1`; nicht-
  gematchte Claims wandern in einen Fußnoten-Block.
  """

  use ExUnit.Case, async: true

  alias HubWeb.CampaignLive.Components

  defp html(text, flagged),
    do: text |> Components.render_recap_with_flags(flagged) |> Phoenix.HTML.safe_to_string()

  describe "Passthrough auf render_md_safe/1 wenn nichts zu flaggen ist" do
    test "flagged=nil rendert wie render_md_safe" do
      out = html("# Titel\n\nText.", nil)
      assert out =~ "<h1>"
      assert out =~ "Titel"
    end

    test "flagged=[] rendert wie render_md_safe" do
      out = html("Kurzer Text.", [])
      assert out =~ "Kurzer Text."
      refute out =~ "lt-unverified"
    end

    test "nil-Text → leerer String" do
      assert Components.render_recap_with_flags(nil, ["egal"]) == ""
    end

    test "leerer Text → leerer String" do
      assert Components.render_recap_with_flags("", ["egal"]) == ""
    end
  end

  describe "In-Text-Markierung" do
    test "ein geflaggter Satz wird mit span.lt-unverified gewrappt" do
      out =
        html(
          "Skrapnik nimmt den Auftrag an. Der Johnson zahlt in Nuyen.",
          ["Skrapnik nimmt den Auftrag an."]
        )

      assert out =~ "<span class=\"lt-unverified\""
      assert out =~ "Skrapnik nimmt den Auftrag an."
      assert out =~ "</span>"
      # Der zweite (nicht geflaggte) Satz steht im Recap, aber NICHT in einem span.
      assert String.contains?(out, "Der Johnson zahlt in Nuyen.")
    end

    test "mehrere geflaggte Claims werden alle gewrappt" do
      out =
        html(
          "Satz A. Satz B. Satz C.",
          ["Satz A.", "Satz C."]
        )

      # Jede Marker-Öffnung produziert eine Vorkommen der Klasse — zählen.
      opens = out |> String.split("<span class=\"lt-unverified\"") |> length()
      # length nach split = anzahl vorkommen + 1
      assert opens - 1 >= 2
    end

    test "Tooltip-Text ist gesetzt" do
      out = html("Behauptung Eins.", ["Behauptung Eins."])
      assert out =~ "title=\"Nicht auf gesicherte Fakten zurückführbar"
    end
  end

  describe "Fußnoten-Fallback für nicht-matchbare Claims" do
    test "Claim der nicht im Recap steht → Fußnote unter dem Text" do
      out =
        html(
          "Der Recap-Text ist völlig anders.",
          ["Dieser Satz existiert im Recap gar nicht."]
        )

      refute out =~ "lt-unverified\""
      assert out =~ "lt-unverified-footnote"
      assert out =~ "Unsichere Stellen"
      assert out =~ "Dieser Satz existiert im Recap gar nicht."
    end

    test "gemischt matched + unmatched: einer wird gewrappt, der andere in Fußnote" do
      out =
        html(
          "Satz X ist da.",
          ["Satz X ist da.", "Satz Y fehlt im Text."]
        )

      # Wrapping für den, der da ist
      assert out =~ ~s(<span class="lt-unverified")
      # Fußnote für den, der fehlt
      assert out =~ "lt-unverified-footnote"
      assert out =~ "Satz Y fehlt im Text."
    end
  end

  describe "XSS-Defense im geflaggten Claim" do
    test "geflaggter Claim mit <script> wird escaped, kein Script-Tag im Output" do
      # Der Recap-Text enthält den Claim wörtlich; nach Earmark+Sanitizer ist
      # `<script>` als `&lt;script&gt;` da. Der Marker ersetzt genau diesen
      # escaped Text (kein Rohtext-Match) → auch das span-Inner ist safe.
      recap = "Vor <script>alert('xss')</script> Nach."
      out = html(recap, ["<script>alert('xss')</script>"])

      refute out =~ "<script"
      refute out =~ "onerror="
      assert out =~ "lt-unverified"
    end

    test "Fußnoten-Fallback escapet unsafe Claim-Text" do
      out =
        html(
          "Recap-Text ohne den Claim.",
          ["<img src=x onerror=alert(1)>"]
        )

      # Das entscheidende: `<` ist escaped → kein Tag-Kontext → onerror wird nie
      # als Handler ausgeführt, sondern als Klartext in der Fußnote gerendert.
      refute out =~ "<img"
      assert out =~ "&lt;img"
      # `onerror=` als reiner Text-Substring innerhalb `&lt;img …&gt;` ist safe.
    end
  end

  describe "Grundvertrag von render_md_safe bleibt erhalten" do
    test "literales <script> im Recap wird auch mit flagged neutralisiert" do
      out = html("Vor <script>evil()</script> Nach.", ["irgendein Claim"])
      refute out =~ "<script"
    end
  end
end
