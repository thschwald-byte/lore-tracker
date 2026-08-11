defmodule Worker.Discord.ConsentGateTest do
  @moduledoc """
  Issue #1002: das Speicher-Gate. Winzige Funktion, aber die einzige Stelle, an
  der entschieden wird, ob eine Tonspur gespeichert werden darf — deshalb
  vollständig gepinnt, inklusive der zwei benannten Grenzen (Widerruf wirkt
  nicht; Sofort-Urteil zählt vor dem persistierten Event).
  """

  use ExUnit.Case, async: true

  alias Worker.Discord.ConsentGate

  @persisted %{version: "v1", accepted_at: ~U[2026-08-11 18:00:00Z]}

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
