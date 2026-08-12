defmodule Worker.Discord.ConsentGateTest do
  @moduledoc """
  Issue #1002/#1005: das Speicher-Gate. Winzige Funktion, aber die einzige
  Stelle, an der entschieden wird, ob eine Tonspur gespeichert werden darf —
  deshalb vollständig gepinnt.

  Seit #1005 kann der persistierte Status auch ein **Widerruf** sein
  (`{:revoked, version}`); die frühere Grenze „Widerruf wirkt nicht" ist damit
  behoben und wird hier in ihrer neuen Form festgenagelt.
  """

  use ExUnit.Case, async: true

  alias Worker.Discord.ConsentGate

  alias Worker.Recording.ConsentPhrase

  # Zustimmung zur AKTUELLEN Wortlaut-Version (nicht "v1" hartcodieren — sonst
  # wird dieser Test beim nächsten Version-Bump stillschweigend sinnlos).
  @persisted {:granted, ConsentPhrase.version()}
  @revoked {:revoked, ConsentPhrase.version()}

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
      refute ConsentGate.allow?(nil, {:granted, "v0"})
    end

    test "Zustimmung zu einer NEUEREN Version deckt die aktuelle mit ab" do
      künftig = "v" <> to_string(Worker.Materializer.version_rank(ConsentPhrase.version()) + 5)
      assert ConsentGate.allow?(nil, {:granted, künftig})
    end

    test "fehlende oder kaputte Version ⇒ fail-closed" do
      refute ConsentGate.allow?(nil, {:granted, nil})
      refute ConsentGate.allow?(nil, {:granted, "kaputt"})
    end

    test "frisch gesprochene Zustimmung ist immer aktuell (wird mit der aktuellen Version geschrieben)" do
      assert ConsentGate.allow?(:granted, {:granted, "v0"})
    end
  end

  describe "Widerruf (#1005) — die frühere Grenze ist behoben" do
    test "persistierter Widerruf verbietet, auch ohne Urteil heute" do
      refute ConsentGate.allow?(nil, @revoked)
    end

    test "persistierter Widerruf schlägt sogar ein frisches Sprach-:granted" do
      # Absicht: ein Widerruf lässt sich nur durch einen NEUEN, persistierten
      # Zustimmungs-Akt aufheben (der im Fold per LWW gewinnt) — nicht durch
      # eine Spracherkennung im laufenden Betrieb. Sonst könnte Cross-Talk einen
      # Widerruf aushebeln.
      refute ConsentGate.allow?(:granted, @revoked)
    end

    test "Widerruf einer ALTEN Version verbietet trotzdem (kein Versions-Schlupfloch)" do
      refute ConsentGate.allow?(nil, {:revoked, "v0"})
      refute ConsentGate.allow?(:granted, {:revoked, "v0"})
    end

    test "allow?/3 baut das Paar selbst zusammen" do
      assert ConsentGate.allow?(nil, :granted, ConsentPhrase.version())
      refute ConsentGate.allow?(nil, :revoked, ConsentPhrase.version())
      refute ConsentGate.allow?(nil, nil, nil)
    end
  end

  describe "Sprach-Ablehnung vs. persistierte Zustimmung" do
    test "ein gesprochenes :declined hebt eine persistierte Zustimmung NICHT auf" do
      # Bewusst so: Akustik ist nicht identitätsgebunden (Cross-Talk/Echo), also
      # darf ein Spracherkennungs-Ergebnis keine erteilte Einwilligung
      # zurücknehmen. Der Weg dafür ist der Widerruf-Klick (identitätsgebunden),
      # der persistiert wird — s. Widerruf-Tests oben.
      assert ConsentGate.allow?(:declined, @persisted)
    end
  end
end
