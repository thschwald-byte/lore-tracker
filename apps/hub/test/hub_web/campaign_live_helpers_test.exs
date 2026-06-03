defmodule HubWeb.CampaignLiveHelpersTest do
  @moduledoc """
  Issue #379: Public Helper-Funktionen aus `HubWeb.CampaignLive.Components` für
  Utterance-Status + ASR-Confidence-Flag.
  """

  use ExUnit.Case, async: true

  alias HubWeb.CampaignLive.Components

  describe "asr_uncertain?/1 — Fallback (alte Utts ohne low_token_fraction)" do
    test "true bei niedrigem min_p + confirmed-Status + echter ASR-Variation" do
      u = %{
        "status" => "confirmed",
        "confidence" => %{"mean_p" => 0.72, "min_p" => 0.42}
      }

      assert Components.asr_uncertain?(u)
    end

    test "true bei live-Status (Live-Transkription)" do
      u = %{"status" => "live", "confidence" => %{"mean_p" => 0.6, "min_p" => 0.3}}
      assert Components.asr_uncertain?(u)
    end

    test "false bei hohem min_p" do
      u = %{"status" => "confirmed", "confidence" => %{"mean_p" => 0.95, "min_p" => 0.85}}
      refute Components.asr_uncertain?(u)
    end

    test "false bei edited-Status (menschliche Korrektur, kein ASR-Flag)" do
      u = %{"status" => "edited", "confidence" => %{"mean_p" => 0.5, "min_p" => 0.2}}
      refute Components.asr_uncertain?(u)
    end

    test "false bei Platzhalter-Confidence (mean == min — typisch für to_confidence_map-Float-Upgrade)" do
      # Materializer-Bug: manual fällt auf :confirmed zurück.
      # Defense-in-depth: zusätzlicher mean==min-Check fängt das ab.
      u = %{"status" => "confirmed", "confidence" => %{"mean_p" => 0.3, "min_p" => 0.3}}
      refute Components.asr_uncertain?(u)
    end

    test "false bei nil-Confidence (keine Messung)" do
      u = %{"status" => "confirmed", "confidence" => nil}
      refute Components.asr_uncertain?(u)
    end

    test "false bei fehlendem Confidence-Key" do
      u = %{"status" => "confirmed"}
      refute Components.asr_uncertain?(u)
    end

    test "false bei Float-Altwert (kein Map-Pattern-Match)" do
      u = %{"status" => "confirmed", "confidence" => 0.42}
      refute Components.asr_uncertain?(u)
    end

    test "Threshold-Boundary: exakt 0.5 ist NICHT geflaggt (Schwelle ist strict <)" do
      u = %{"status" => "confirmed", "confidence" => %{"mean_p" => 0.7, "min_p" => 0.5}}
      refute Components.asr_uncertain?(u)
    end

    test "Threshold-Boundary: 0.499 IST geflaggt" do
      u = %{"status" => "confirmed", "confidence" => %{"mean_p" => 0.7, "min_p" => 0.499}}
      assert Components.asr_uncertain?(u)
    end
  end

  describe "asr_uncertain?/1 — Issue #381 Primary (low_token_fraction)" do
    # Vier-Fälle-Matrix komplett — siehe @doc am Gate.

    test "neu-real (Fall 1): high low_token_fraction + n>0 + confirmed → flag" do
      u = %{
        "status" => "confirmed",
        "confidence" => %{
          "mean_p" => 0.7,
          "min_p" => 0.3,
          "low_token_fraction" => 0.3,
          "token_count" => 12
        }
      }

      assert Components.asr_uncertain?(u)
    end

    test "neu-real bei live-Status" do
      u = %{
        "status" => "live",
        "confidence" => %{"low_token_fraction" => 0.5, "token_count" => 10}
      }

      assert Components.asr_uncertain?(u)
    end

    test "neu-real, Fraction unter Schwelle → kein flag" do
      u = %{
        "status" => "confirmed",
        "confidence" => %{"low_token_fraction" => 0.15, "token_count" => 12}
      }

      refute Components.asr_uncertain?(u)
    end

    test "neu-real bei edited-Status → kein flag (menschliche Korrektur)" do
      u = %{
        "status" => "edited",
        "confidence" => %{"low_token_fraction" => 0.5, "token_count" => 12}
      }

      refute Components.asr_uncertain?(u)
    end

    test "neu-Platzhalter (Fall 2): token_count=0 → kein flag (n > 0 Guard)" do
      # to_confidence_map/1 (#376/#381) setzt für Platzhalter token_count: 0.
      u = %{
        "status" => "confirmed",
        "confidence" => %{
          "mean_p" => 0.3,
          "min_p" => 0.3,
          "low_token_fraction" => 0.5,
          "token_count" => 0
        }
      }

      refute Components.asr_uncertain?(u)
    end

    test "Threshold-Boundary: 0.2 exakt → kein flag (strict >)" do
      u = %{
        "status" => "confirmed",
        "confidence" => %{"low_token_fraction" => 0.2, "token_count" => 10}
      }

      refute Components.asr_uncertain?(u)
    end

    test "Threshold-Boundary: 0.201 → flag" do
      u = %{
        "status" => "confirmed",
        "confidence" => %{"low_token_fraction" => 0.201, "token_count" => 10}
      }

      assert Components.asr_uncertain?(u)
    end

    test "Vorher-Nachher-Beweisfall: hoher token_count + niedriger min_p ABER niedrige Fraction → KEIN flag" do
      # Genau der Fall, der unter #379-Logik geflaggt hätte (min_p < 0.5,
      # p != m) und unter #381 NICHT mehr flaggt — Fraction-Pfad gewinnt.
      u = %{
        "status" => "confirmed",
        "confidence" => %{
          "mean_p" => 0.83,
          "min_p" => 0.31,
          "low_token_fraction" => 0.07,
          "token_count" => 30
        }
      }

      refute Components.asr_uncertain?(u)
    end

    test "alt-Platzhalter (Fall 4, explizit): mean==min ohne neues Feld → kein flag" do
      # Defense-in-depth: wenn jemals ein altes Platzhalter-Event ohne
      # low_token_fraction reinkommt, fängt p != m im Fallback es ab.
      u = %{
        "status" => "confirmed",
        "confidence" => %{"mean_p" => 0.3, "min_p" => 0.3}
      }

      refute Components.asr_uncertain?(u)
    end
  end

  describe "uncertainty_tooltip/1 — Fallback (alte Utts ohne low_token_fraction)" do
    test "min_p + mean_p auf 2 Dezimalen, mit Längen-Bias-Hinweis" do
      u = %{"confidence" => %{"min_p" => 0.4234, "mean_p" => 0.7567}}
      tooltip = Components.uncertainty_tooltip(u)

      assert tooltip =~ "0.42"
      assert tooltip =~ "0.76"
      assert tooltip =~ "ASR-Unsicherheit"
      assert tooltip =~ "alte Aggregation"
      assert tooltip =~ "lange Utts"
    end

    test "Fallback bei fehlender Confidence" do
      assert Components.uncertainty_tooltip(%{}) == "ASR-Unsicherheit"
      assert Components.uncertainty_tooltip(%{"confidence" => nil}) == "ASR-Unsicherheit"
    end
  end

  describe "uncertainty_tooltip/1 — Issue #381 (Fraction-basiert)" do
    test "zeigt Prozent + Tokenzahl" do
      u = %{"confidence" => %{"low_token_fraction" => 0.27, "token_count" => 15}}
      tooltip = Components.uncertainty_tooltip(u)

      assert tooltip =~ "27%"
      assert tooltip =~ "15 Tokens"
      assert tooltip =~ "kein Fehler-Marker"
    end

    test "Kurz-Ende-Caveat ab n<8 sichtbar" do
      u = %{"confidence" => %{"low_token_fraction" => 0.5, "token_count" => 4}}
      assert Components.uncertainty_tooltip(u) =~ "kurze Utterances"
    end

    test "Kurz-Ende-Caveat ab n>=8 NICHT sichtbar" do
      u = %{"confidence" => %{"low_token_fraction" => 0.3, "token_count" => 8}}
      refute Components.uncertainty_tooltip(u) =~ "kurze Utterances"
    end

    test "neuer Pfad gewinnt über alten (Fraction-Tooltip trotz vorhandenem min_p)" do
      u = %{
        "confidence" => %{
          "low_token_fraction" => 0.3,
          "token_count" => 12,
          "mean_p" => 0.7,
          "min_p" => 0.3
        }
      }

      tooltip = Components.uncertainty_tooltip(u)
      assert tooltip =~ "12 Tokens"
      refute tooltip =~ "alte Aggregation"
    end
  end

  describe "status_label/1" do
    test "alle vier bekannten Status" do
      assert Components.status_label("confirmed") == "bestätigt"
      assert Components.status_label("live") == "live (Transkription läuft)"
      assert Components.status_label("edited") == "editiert"
      assert Components.status_label("manual") == "manuell hinzugefügt"
    end

    test "nil → confirmed-Default (Seed-Events ohne explicit status)" do
      assert Components.status_label(nil) == "bestätigt"
    end

    test "unbekannter Status → sichtbar mit Wert (kein stilles Verschwinden)" do
      label = Components.status_label("refined")
      assert label =~ "unbekannter Status"
      assert label =~ "refined"
    end
  end

  describe "status_dot_class/1" do
    test "mappt jeden bekannten Status auf eine Theme-Token-Klasse" do
      assert Components.status_dot_class("confirmed") == "bg-success"
      assert Components.status_dot_class("live") =~ "bg-accent"
      assert Components.status_dot_class("live") =~ "animate-pulse"
      assert Components.status_dot_class("edited") == "bg-warning"
      assert Components.status_dot_class("manual") == "bg-accent-soft"
    end

    test "deleted → nil (Tombstone, kein Render)" do
      assert Components.status_dot_class("deleted") == nil
    end

    test "unbekannter Status → bg-ink-2 (sichtbar grau statt stilles Weglassen)" do
      assert Components.status_dot_class("refined") == "bg-ink-2"
      assert Components.status_dot_class("garbage") == "bg-ink-2"
    end

    test "nil → confirmed-Default" do
      assert Components.status_dot_class(nil) == "bg-success"
    end
  end
end
