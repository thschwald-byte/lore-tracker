defmodule Worker.Jack.Epos.Zusammenfassung do
  @moduledoc """
  Was nach einer Kompaktierung im Überblick des Epos-Jack an die Stelle des
  weggeschnittenen Verlaufs tritt (E1, #1210) — ein Arbeitsstand, den die
  Werkzeuge aus ihren Daten schreiben, keine Zusammenfassung durch das Modell
  (Muster `Worker.Jack.Resuemee.Zusammenfassung`, deren Rückruf hier mit
  eigenem Text läuft). Er trägt den Auftrag in wenigen Zeilen, den Stil
  (Überschrift, Grundton, Epos-Ton), wo Jack steht, seine Notizen und den
  nächsten Schritt.
  """

  alias Worker.Jack.Epos.{Notizen, Weg}
  alias Worker.Jack.Resuemee.Stand
  alias Worker.Jack.Resuemee.Zusammenfassung, as: Gemeinsam

  @doc "Der Rückruf für `kontext: [zusammenfassen: …]` eines Laufs mit diesem Halter."
  @spec fuer(pid()) :: (map() -> String.t())
  def fuer(halter), do: Gemeinsam.fuer(halter, &text/1)

  @doc "Der Arbeitsstand als Text."
  @spec text(Stand.t()) :: String.t()
  def text(%Stand{} = s) do
    notizen = String.trim(Notizen.notizen_text(s))

    Enum.join(
      [
        "# Stand deiner Arbeit (von deinen Werkzeugen geschrieben, nicht zusammengefasst)",
        "",
        "## Auftrag",
        "Du bereitest das Epos-Kapitel von Sitzung #{s.sitzung.nummer} für die Spalte",
        "„#{s.ueberschrift}“ vor. Gut zu lesen hat Vorrang: das Kapitel folgt dem Stil unten",
        "und erzählt den Weg der Gruppe durch die Sitzung in Szenen, mit mindestens",
        "#{Notizen.mindest(s)} Wörtern. Handlung treu, Erzählweise frei — Figuren, Orte,",
        "Ereignisse und Ausgänge kommen aus den Fakten. Hier liest du alle Fakten, notierst",
        "unter FORM die Form (aus der Überschrift) und die Erzählhaltung (aus dem Epos-Ton),",
        "prüfst den Weg aus dem Resümee (resuemee()) und stellst deine SZENEN auf — so viele,",
        "wie die Sitzung braucht. Jede Station des Wegs steht am Ende in einer Szene oder mit",
        "Grund unter ABWEICHUNG. Geschrieben wird im nächsten Auftrag; dort hast du nur deine",
        "Notizen.",
        "",
        "## Stil",
        "Überschrift der Epos-Spalte: „#{s.ueberschrift}“",
        "",
        Stand.ton(s.flavor, :epos),
        "",
        "## Wo du stehst",
        Notizen.stand_text(s),
        "",
        "## Deine Notizen",
        if(notizen == "", do: "(noch keine Notizen)", else: notizen),
        "",
        "## Nächster Schritt",
        naechster_schritt(s)
      ],
      "\n"
    )
  end

  defp naechster_schritt(s) do
    offen = Weg.offen(s)

    cond do
      Stand.ungelesen(s) != [] ->
        [erster | _] = Stand.ungelesen(s)

        "Lies weiter: fakten(von, bis) ab Fakt #{erster |> String.split("-") |> hd()}. " <>
          "Was du schon gelesen hast, steht in deinen Notizen — fang nicht von vorn an."

      Stand.form(s) == nil ->
        "Notier die FORM: welche Form ergibt sich aus der Überschrift „#{s.ueberschrift}“, " <>
          "welche Erzählhaltung aus dem Epos-Ton?"

      Stand.abschnitt(s, "SZENEN") == [] ->
        "Stell deine SZENEN auf: so viele, wie die Sitzung braucht, in der Reihenfolge, in der " <>
          "das Kapitel erzählt, jede mit ihren Fakten dieser Sitzung. Den Weg aus dem Resümee " <>
          "zeigt resuemee()."

      offen != [] ->
        "Diese Stationen aus dem Weg des Resümees stehen noch weder in einer Szene noch unter " <>
          "ABWEICHUNG: #{Weg.text(offen)}. Nimm sie in eine Szene auf oder begründe unter " <>
          "ABWEICHUNG, warum das Kapitel sie anders erzählt oder weglässt."

      true ->
        "Prüf deine Szenen mit notizen_lesen() und schließ mit fertig() ab."
    end
  end
end
