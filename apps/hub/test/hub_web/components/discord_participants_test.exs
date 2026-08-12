defmodule HubWeb.CampaignLive.DiscordParticipantsTest do
  @moduledoc """
  Issue #988: die Teilnehmer-Leiste des Discord-Voice-Kanals neben dem
  Aufnahme-Button. Die beiden Zustände entsprechen der Realität im Audio-Pfad
  (#1002 verwirft ohne Einwilligung tatsächlich) — der Test nagelt fest, dass
  die Darstellung nicht davon abweicht.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias HubWeb.CampaignLive.MicComponents

  # Issue #1007: die Leiste hängt jetzt zusätzlich an einer laufenden Session.
  # Der Default hier ist deshalb eine laufende Aufnahme — die Alt-Tests prüfen
  # weiter die Darstellung, die Session-Abhängigkeit hat ihren eigenen Block.
  defp render_bar(participants, users \\ %{}, active_session \\ %{status: :recording}) do
    render_component(&MicComponents.discord_participants/1,
      participants: participants,
      users: users,
      active_session: active_session
    )
  end

  defp p(did, consent, speaking),
    do: %{"discord_id" => did, "consent" => consent, "speaking" => speaking}

  test "leere Liste -> gar nichts gerendert (kein leerer Platzhalter)" do
    html = render_bar([])
    refute html =~ "<img"
  end

  test "mit Einwilligung, still: farbig, kein Puls" do
    html = render_bar([p("111", true, false)])

    assert html =~ "<img"
    refute html =~ "grayscale"
    refute html =~ "animate-pulse"
    assert html =~ "wird aufgezeichnet"
  end

  test "mit Einwilligung, spricht: pulsiert" do
    html = render_bar([p("111", true, true)])

    assert html =~ "animate-pulse"
    refute html =~ "grayscale"
    assert html =~ "spricht gerade"
  end

  test "ohne Einwilligung: grau + roter Balken, NIE pulsierend" do
    html = render_bar([p("222", false, false)])

    assert html =~ "grayscale"
    assert html =~ "bg-danger"
    refute html =~ "animate-pulse"
    assert html =~ "wird NICHT aufgezeichnet"
  end

  test "ohne Einwilligung pulsiert auch beim Sprechen nicht (sonst sähe es nach Aufnahme aus)" do
    html = render_bar([p("222", false, true)])

    refute html =~ "animate-pulse"
    assert html =~ "grayscale"
    assert html =~ "bg-danger"
  end

  test "mehrere Teilnehmer nebeneinander, gemischte Zustände" do
    html = render_bar([p("111", true, true), p("222", false, false)])

    assert html |> String.split("<img") |> length() == 3
    assert html =~ "animate-pulse"
    assert html =~ "grayscale"
  end

  test "bekannter Nutzer: Anzeigename + hinterlegter Avatar" do
    users = %{"111" => %{"display_name" => "Anna", "avatar_url" => "https://example.test/a.png"}}
    html = render_bar([p("111", true, false)], users)

    assert html =~ "Anna"
    assert html =~ "https://example.test/a.png"
  end

  test "unbekannter Nutzer (gerade erst per Consent aufgenommen) -> Discord-Default-Avatar statt Crash" do
    html = render_bar([p("999", true, false)])

    assert html =~ "cdn.discordapp.com/embed/avatars/"
  end

  describe "participant_title/2 — die Bedeutung steht in Worten, nicht nur in Farbe (a11y)" do
    test "deckt alle drei Aussagen ab" do
      assert MicComponents.participant_title(p("1", false, false), %{}) =~ "keine Einwilligung"
      assert MicComponents.participant_title(p("1", true, true), %{}) =~ "spricht gerade"
      assert MicComponents.participant_title(p("1", true, false), %{}) =~ "wird aufgezeichnet"
    end

    test "kein Consent gewinnt über spricht (die wichtigere Aussage zuerst)" do
      assert MicComponents.participant_title(p("1", false, true), %{}) =~ "NICHT aufgezeichnet"
    end
  end

  describe "Session-Abhängigkeit (#1007)" do
    test "REGRESSION: ohne aktive Session wird nichts gerendert, auch mit Restbestand" do
      # Der Bug: die Präsenz-Liste ist ephemer und wird nur GESETZT, solange der
      # Worker sendet. Nach dem Stop hört er auf — der letzte Stand blieb im
      # Assign stehen und die Leiste behauptete weiter „diese Leute sitzen im
      # Kanal und werden aufgezeichnet".
      html = render_bar([p("111", true, true)], %{}, nil)

      refute html =~ "<img", "Avatar-Leiste steht nach Session-Ende noch (der #1007-Bug)"
    end

    test "eine beendete Session ist keine aktive — `active_session` ist dann nil" do
      # `Worker.Repo.active_session_for/1` liefert ausschließlich :recording/:paused,
      # und der Stop-Pfad in `Recording.stop/1` setzt das Assign sofort auf nil.
      # Dieser Test pinnt, dass die Anzeige an genau dieser Unterscheidung hängt.
      assert MicComponents.rec_state(nil) == :idle
      refute render_bar([p("111", true, false)], %{}, nil) =~ "<img"
    end

    test "während der Aufnahme sichtbar" do
      assert render_bar([p("111", true, false)], %{}, %{status: :recording}) =~ "<img"
    end

    test "in der PAUSE weiter sichtbar — der Bot bleibt im Kanal" do
      # Pause stoppt die Aufnahme, nicht die Voice-Verbindung. Wer im Kanal
      # sitzt, sitzt weiter dort; die Leiste zu verstecken wäre hier die
      # Falschaussage.
      assert render_bar([p("111", true, false)], %{}, %{status: :paused}) =~ "<img"
    end
  end
end
