defmodule Worker.UpdaterShaVergleichTest do
  @moduledoc """
  Issue #1129: der Self-Update-Endlosschleife.

  Hub und Worker gewinnen ihren SHA beide aus `git rev-parse --short HEAD`, und
  dessen Länge ist adaptiv. Am 21.08. stand real `lokal=383f35a4 hub=383f35a`
  im Log — derselbe Commit, acht Zeichen gegen sieben. Der Gleichheitstest fand
  sie ungleich, und der Worker updatete sich vier Mal in fünf Minuten.
  """
  use ExUnit.Case, async: true

  alias Worker.Updater

  describe "sha_gleich?/2 — der Regressionsfall" do
    test "acht Zeichen gegen sieben, derselbe Commit" do
      assert Updater.sha_gleich?("383f35a4", "383f35a")
      assert Updater.sha_gleich?("383f35a", "383f35a4")
    end

    test "volle Länge gegen Kurzform" do
      assert Updater.sha_gleich?("383f35a4b1c2d3e4f5", "383f35a")
    end

    test "identische Kurzformen (der Normalfall, der schon immer ging)" do
      assert Updater.sha_gleich?("e7f37b0", "e7f37b0")
    end
  end

  describe "sha_gleich?/2 — was NICHT gleich sein darf" do
    test "verschiedene Commits" do
      refute Updater.sha_gleich?("383f35a4", "e7f37b0b")
    end

    test "gemeinsames Präfix, das kürzer als sieben Zeichen ist" do
      # Sonst würde eine zufällige Übereinstimmung der ersten Zeichen ein
      # echtes Update dauerhaft unterdrücken — die schlimmere Fehlerrichtung.
      refute Updater.sha_gleich?("383f3", "383f3")
      refute Updater.sha_gleich?("383f35", "383f35abc")
    end

    test "unknown ist nie gleich — auch nicht mit sich selbst" do
      # `Worker.Version.current().sha` liefert "unknown", wenn kein git da ist.
      # Zwei Unbekannte sind nicht dieselbe SHA, sondern zwei Unbekannte.
      refute Updater.sha_gleich?("unknown", "unknown")
      refute Updater.sha_gleich?("unknown", "383f35a")
    end

    test "nil und Nicht-Strings" do
      refute Updater.sha_gleich?(nil, "383f35a")
      refute Updater.sha_gleich?("383f35a", nil)
      refute Updater.sha_gleich?(nil, nil)
    end
  end

  describe "Verdrahtung" do
    # Die pure Funktion nützt nichts, wenn `maybe_update/1` sie nicht benutzt.
    # Ein Verhaltenstest dafür wäre umgebungsabhängig: er hinge an der echten
    # lokalen SHA und am `dirty?`-Zweig, der im Arbeits-Checkout ohnehin vorher
    # greift — er wäre auch OHNE den Fix grün gewesen. Deshalb der Quelltext-
    # Wächter (Muster: recorder_stop_order_test, voice_session_anchor_test).
    @quelle File.read!("lib/worker/updater.ex")

    test "maybe_update/1 vergleicht die SHAs über sha_gleich?/2, nicht mit ==" do
      assert @quelle =~ "sha_gleich?(state.target_sha, local.sha) -> state"

      refute @quelle =~ "state.target_sha == local.sha",
             "Gleichheitstest zurück im Code — das ist die #1129-Endlosschleife"
    end
  end
end
