defmodule Worker.Discord.ConsentGateTest do
  @moduledoc """
  Issue #1002: das Speicher-Gate. Winzige Funktion, aber die einzige Stelle, an
  der entschieden wird, ob eine Tonspur gespeichert werden darf — deshalb
  vollständig gepinnt, inklusive der zwei benannten Grenzen (Widerruf wirkt
  nicht; Sofort-Urteil zählt vor dem persistierten Event).
  """

  use ExUnit.Case, async: true

  alias Worker.Discord.ConsentGate

  alias Worker.Recording.ConsentPhrase

  # Zustimmung zur AKTUELLEN Wortlaut-Version (nicht "v1" hartcodieren — sonst
  # wird dieser Test beim nächsten Version-Bump stillschweigend sinnlos).
  @persisted %{version: ConsentPhrase.version(), accepted_at: ~U[2026-08-11 18:00:00Z]}

  describe "erlaubt" do
    test "frisch gesprochene Zustimmung im Fenster" do
      assert ConsentGate.allow?(:granted, nil)
    end

    test "persistierte Zustimmung (früherer Abend ODER Browser-Pfad), ohne Urteil heute" do
      assert ConsentGate.allow?(nil, @persisted)
    end

    test "beides" do
      assert ConsentGate.allow?(:granted, @persisted)
    end
  end

  describe "verbietet (fail-closed)" do
    test "nichts gesagt und nichts persistiert" do
      refute ConsentGate.allow?(nil, nil)
    end

    test "ausdrückliche Ablehnung im Fenster" do
      refute ConsentGate.allow?(:declined, nil)
    end

    test "unklares Urteil (ASR-Murks, halbe Formulierung)" do
      refute ConsentGate.allow?(:unclear, nil)
    end

    test "unbekannte Werte gelten nie als Zustimmung" do
      refute ConsentGate.allow?(:irgendwas, nil)
      refute ConsentGate.allow?("granted", nil)
      refute ConsentGate.allow?(true, nil)
    end
  end

  describe "Wortlaut-Version wird geprüft, nicht nur die Existenz einer Row" do
    test "Zustimmung zu einer ÄLTEREN Version zählt nicht (es wurde in anderen Text eingewilligt)" do
      # Ohne diese Prüfung wäre die Versionierung Dekoration: geschrieben, aber
      # nie ausgewertet — eine v1-Zustimmung würde eine v2-Einwilligung
      # stillschweigend abdecken.
      refute ConsentGate.allow?(nil, %{version: "v0", accepted_at: ~U[2026-01-01 00:00:00Z]})
    end

    test "Zustimmung zu einer NEUEREN Version deckt die aktuelle mit ab" do
      künftig = "v" <> to_string(Worker.Materializer.version_rank(ConsentPhrase.version()) + 5)
      assert ConsentGate.allow?(nil, %{version: künftig, accepted_at: ~U[2026-12-01 00:00:00Z]})
    end

    test "fehlende oder kaputte Version ⇒ fail-closed" do
      refute ConsentGate.allow?(nil, %{version: nil, accepted_at: ~U[2026-08-11 18:00:00Z]})
      refute ConsentGate.allow?(nil, %{version: "kaputt", accepted_at: ~U[2026-08-11 18:00:00Z]})
      refute ConsentGate.allow?(nil, %{accepted_at: ~U[2026-08-11 18:00:00Z]})
    end

    test "frisch gesprochene Zustimmung ist immer aktuell (wird mit der aktuellen Version geschrieben)" do
      assert ConsentGate.allow?(:granted, %{version: "v0", accepted_at: ~U[2026-01-01 00:00:00Z]})
    end
  end

  describe "benannte Grenze: Widerruf wirkt (noch) nicht" do
    test "declined heute überschreibt eine früher erteilte Zustimmung NICHT" do
      # Ehrlich dokumentiert im Moduledoc + Issue: ein Widerruf bräuchte einen
      # persistierten Ablehnungs-Zustand, den die Tabelle nicht darstellen kann
      # (nur version + accepted_at). Wer früher zugestimmt hat und heute
      # widerspricht, wird weiter aufgezeichnet. Dieser Test hält die Lücke
      # sichtbar, statt sie zu verstecken.
      assert ConsentGate.allow?(:declined, @persisted)
    end
  end
end
