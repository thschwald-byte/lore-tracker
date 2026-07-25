defmodule HubWeb.Wire.SharedEventsMacroTest do
  @moduledoc """
  Issue #539: das Compile-Zeit-Makro `Shared.Events.k/1`. Pinnt die drei
  Eigenschaften, die das Makro über die 0-arity-Funktionen hinaus liefert:
  (1) Expansion zum Wire-Literal, (2) Pattern-Head-Tauglichkeit (Consumer-
  Matches — der bei #471 deferte Teil), (3) Compile-Fehler bei unbekanntem/
  ungültigem Kind (Drift strukturell unmöglich statt nur detektiert).

  In der Hub-Suite platziert wie der Drift-Guard (#608): shared bootet nicht
  standalone, die CI fährt die hub-Suite als Merge-Gate.
  """
  use ExUnit.Case, async: true

  alias Shared.Events
  require Events

  # Pattern-Head-Nutzung (Kern von #539: Funktions-Calls sind hier verboten,
  # das Makro expandiert zum Literal und ist deshalb erlaubt).
  defp classify(Events.k(:session_ended)), do: :ended
  defp classify(Events.k(:arc_created)), do: :arc_born
  defp classify(_), do: :other

  test "k/1 expandiert zum Wire-Literal (Alt- und Neu-Kinds)" do
    assert Events.k(:session_ended) == "SessionEnded"
    assert Events.k(:thread_override_set) == "ThreadOverrideSet"
    assert Events.k(:arc_created) == "ArcCreated"
    assert Events.k(:arc_closed) == "ArcClosed"
    assert Events.k(:arc_reopened) == "ArcReopened"
    assert Events.k(:leitfrage_set) == "LeitfrageSet"
  end

  test "k/1 ist Pattern-Head-tauglich (Consumer-Match)" do
    assert classify("SessionEnded") == :ended
    assert classify("ArcCreated") == :arc_born
    assert classify("SessionStarted") == :other
  end

  test "k/1 stimmt mit den 0-arity-Konstanten überein (eine SSoT)" do
    assert Events.k(:utterance_appended) == Events.utterance_appended()
    assert Events.k(:arc_closed) == Events.arc_closed()
  end

  test "unbekannter Kind → Compile-Fehler am Call-Site" do
    assert_raise ArgumentError, ~r/unbekannter Event-Kind :quatsch_kind/, fn ->
      Code.eval_string("require Shared.Events; Shared.Events.k(:quatsch_kind)")
    end
  end

  test ":all ist kein Kind (Selbstreferenz-Schutz)" do
    assert_raise ArgumentError, ~r/unbekannter Event-Kind :all/, fn ->
      Code.eval_string("require Shared.Events; Shared.Events.k(:all)")
    end
  end

  test "Nicht-Atom-Argument → Compile-Fehler (kein Laufzeit-Lookup)" do
    assert_raise ArgumentError, ~r/erwartet ein Atom-Literal/, fn ->
      Code.eval_string("require Shared.Events; x = :foo; Shared.Events.k(x)")
    end
  end

  test "die 4 Arc-Kinds sind in all/0 (Introspektion greift automatisch)" do
    for kind <- ["ArcCreated", "ArcClosed", "ArcReopened", "LeitfrageSet"] do
      assert kind in Events.all()
    end
  end
end
