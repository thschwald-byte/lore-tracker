defmodule HubWeb.LocalTimeTest do
  @moduledoc """
  Issue #1014: Zeitstempel werden als UTC gespeichert und server-gerendert, der
  Browser schreibt sie in die Geräte-Zone um (`assets/js/local_time.js`).

  Der Test nagelt den **Server-Anteil** fest — die JS-Seite ist hier nicht
  prüfbar. Besonders wichtig: das `UTC`-Kürzel im Text. Es ist nicht Kosmetik,
  sondern trägt zwei Lasten: ohne JavaScript steht dort eine korrekt
  beschriftete Zeit statt einer stillen Falschaussage, und für das JS ist es
  der Marker für „noch nicht formatiert" (Idempotenz ohne Buchhaltung).
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias HubWeb.UIComponents

  defp tag(assigns), do: render_component(&UIComponents.local_time/1, assigns)

  describe "gültiger Zeitstempel" do
    test "rendert <time> mit maschinenlesbarem UTC im datetime-Attribut" do
      html = tag(%{iso: "2026-08-12T10:21:08Z"})

      assert html =~ ~s(datetime="2026-08-12T10:21:08Z")
      assert html =~ ~s(data-local-time="time")
    end

    test "sichtbarer Text trägt das UTC-Kürzel — der JS-Marker UND die ehrliche Beschriftung" do
      html = tag(%{iso: "2026-08-12T10:21:08Z"})

      assert html =~ "10:21:08 UTC"
    end

    test "title nennt die UTC-Zeit in Worten (bleibt auch nach dem Umschreiben stehen)" do
      html = tag(%{iso: "2026-08-12T10:21:08Z"})

      assert html =~ "UTC: 2026-08-12 10:21:08"
    end

    test "Offset-behaftete Eingabe wird nach UTC normalisiert, nicht roh übernommen" do
      # 12:21:08+02:00 == 10:21:08Z — sonst zeigte der Fallback-Text eine
      # falsche Zeit unter dem Label „UTC".
      html = tag(%{iso: "2026-08-12T12:21:08+02:00"})

      assert html =~ "10:21:08 UTC"
      assert html =~ ~s(datetime="2026-08-12T10:21:08Z")
    end

    test "nimmt auch ein DateTime entgegen" do
      html = tag(%{iso: ~U[2026-08-12 10:21:08Z]})

      assert html =~ "10:21:08 UTC"
    end
  end

  describe "Format-Varianten" do
    test ":time — nur Uhrzeit" do
      assert tag(%{iso: "2026-08-12T10:21:08Z", format: :time}) =~ ">10:21:08 UTC<"
    end

    test ":datetime — Datum + Stunde/Minute" do
      assert tag(%{iso: "2026-08-12T10:21:08Z", format: :datetime}) =~ ">2026-08-12 10:21 UTC<"
    end

    test ":datetime_sec — Datum + Sekunden" do
      assert tag(%{iso: "2026-08-12T10:21:08Z", format: :datetime_sec}) =~
               ">2026-08-12 10:21:08 UTC<"
    end

    test "das Format reist als data-Attribut mit, damit JS es gleich formatiert" do
      assert tag(%{iso: "2026-08-12T10:21:08Z", format: :datetime_sec}) =~
               ~s(data-local-time="datetime_sec")
    end
  end

  describe "Rand- und Fehlerfälle" do
    test "nil → Platzhalter, kein <time> (nichts zu formatieren)" do
      html = tag(%{iso: nil})

      refute html =~ "<time"
      assert html =~ "--:--:--"
    end

    test "leerer String zählt wie nil" do
      assert tag(%{iso: "   "}) =~ "--:--:--"
    end

    test "Platzhalter hängt am Format (Uhrzeit vs. Datum)" do
      assert tag(%{iso: nil, format: :datetime}) =~ "—"
    end

    test "eigener Platzhalter überschreibt den Default" do
      assert tag(%{iso: nil, placeholder: "nie"}) =~ "nie"
    end

    test "unparsebarer Wert wird unverändert durchgereicht (flag-not-drop)" do
      html = tag(%{iso: "irgendwas kaputtes"})

      assert html =~ "irgendwas kaputtes"
      # Kein <time>: ohne gültiges datetime hätte das JS nichts zu tun, und ein
      # leeres datetime-Attribut wäre eine Einladung zu "Invalid Date".
      refute html =~ "<time"
    end

    test "unerwarteter Typ crasht nicht" do
      assert tag(%{iso: %{unerwartet: true}}) =~ "--:--:--"
    end
  end

  test "class wird durchgereicht (Call-Sites bringen ihre Typografie mit)" do
    assert tag(%{iso: "2026-08-12T10:21:08Z", class: "font-mono text-ink-2"}) =~ "font-mono"
    assert tag(%{iso: nil, class: "font-mono"}) =~ "font-mono"
  end
end
