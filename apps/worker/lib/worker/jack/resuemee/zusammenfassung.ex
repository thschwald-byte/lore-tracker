defmodule Worker.Jack.Resuemee.Zusammenfassung do
  @moduledoc """
  Was nach einer Kompaktierung an die Stelle des weggeschnittenen Verlaufs
  tritt — das Muster von `Worker.Jack.Zusammenfassung`: ein Arbeitsstand, den
  die Werkzeuge aus ihren Daten schreiben, keine Zusammenfassung durch das
  Modell. Er trägt die Überschrift der Spalte, den Lesestand, die Notizen
  (FORM, GLIEDERUNG, OFFEN) und den nächsten Schritt. Die Laufzeit ruft
  `fuer/1` bei jedem Schnitt; der Text wird jedes Mal neu gebaut.
  """

  alias Worker.Agent.Kontext
  alias Worker.Jack.Resuemee.{Entwurf, Halter, Notizen, Stand}

  @doc """
  Der Rückruf für `kontext: [zusammenfassen: …]` eines Laufs mit diesem
  Halter. Er baut den Text aus dem aktuellen Stand und schreibt ihn ins
  Journal; scheitert das, fällt er auf `Kontext.standard_zusammenfassung/1`
  zurück — ein Schnitt ohne Text würde den Lauf abbrechen.
  """
  @spec fuer(pid()) :: (map() -> String.t())
  def fuer(halter) do
    fn %{weggefallen: weg} = arg ->
      ergebnis =
        Halter.aufrufen(
          halter,
          fn s, _ ->
            t = text(s)

            eintrag = %{"lauf" => to_string(s.lauf), "weggefallen" => length(weg), "text" => t}
            {Stand.journal(s, "zusammenfassung.txt", eintrag), t}
          end,
          %{}
        )

      if is_binary(ergebnis), do: ergebnis, else: Kontext.standard_zusammenfassung(arg)
    end
  end

  @doc """
  Der Arbeitsstand als Text. Im Schreiben (B2) trägt er den Ton, die Notizen
  aus dem Überblick und den Entwurf — gekürzt je Absatz, mit Nummern, damit
  Jack nach einem Schnitt weiß, was dasteht; vollständig liefert ihn
  `entwurf()`.
  """
  @spec text(Stand.t()) :: String.t()
  def text(%Stand{lauf: :schreiben} = s) do
    notizen = String.trim(Notizen.notizen_text(s))

    Enum.join(
      [
        "# Stand deiner Arbeit (von deinen Werkzeugen geschrieben, nicht zusammengefasst)",
        "",
        "## Auftrag",
        "Du schreibst das Resümee von Sitzung #{s.sitzung.nummer} für die Spalte",
        "„#{s.ueberschrift}“, Absatz für Absatz mit absatz(), in der FORM und nach der",
        "GLIEDERUNG deiner Notizen. Jeder Satz nennt die Fakten, auf die er sich stützt.",
        "",
        "## Ton",
        Stand.ton(s.flavor),
        "",
        "## Wo du stehst",
        Notizen.stand_text(s),
        "",
        "## Deine Notizen aus dem Überblick",
        if(notizen == "", do: "(keine Notizen)", else: notizen),
        "",
        "## Dein Entwurf (gekürzt; vollständig mit entwurf())",
        Entwurf.entwurf_kurz(s),
        "",
        "## Nächster Schritt",
        naechster_schritt(s)
      ],
      "\n"
    )
  end

  def text(%Stand{} = s) do
    notizen = String.trim(Notizen.notizen_text(s))

    Enum.join(
      [
        "# Stand deiner Arbeit (von deinen Werkzeugen geschrieben, nicht zusammengefasst)",
        "",
        "## Auftrag",
        "Du bereitest das Resümee von Sitzung #{s.sitzung.nummer} vor: du liest alle Fakten",
        "der Sitzung, notierst unter FORM, welche Form das Resümee bekommt — abgeleitet aus",
        "der Überschrift der Spalte, „#{s.ueberschrift}“ —, und legst danach die GLIEDERUNG an,",
        "gestützt auf die Fakten und die Bögen aus boegen(). Geschrieben wird im nächsten",
        "Auftrag; dort hast du nur deine Notizen.",
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

  defp naechster_schritt(%Stand{lauf: :schreiben} = s) do
    arc = Stand.arc_ohne_satz(s)

    cond do
      s.entwurf == [] ->
        "Schreib den ersten Absatz nach deiner GLIEDERUNG mit absatz()."

      arc != [] ->
        "Schreib weiter nach deiner GLIEDERUNG. Diese Handlungsbögen haben noch keinen Satz " <>
          "mit einem ihrer Fakten: #{Enum.join(arc, ", ")} — erzähl sie, oder nenn sie beim " <>
          "Abschluss in ausgelassen, mit dem Grund."

      true ->
        "Schreib weiter nach deiner GLIEDERUNG; stehen alle Punkte, lies den Entwurf mit " <>
          "entwurf() und schließ mit fertig() ab."
    end
  end

  defp naechster_schritt(s) do
    cond do
      Stand.ungelesen(s) != [] ->
        [erster | _] = Stand.ungelesen(s)

        "Lies weiter: fakten(von, bis) ab Fakt #{erster |> String.split("-") |> hd()}. " <>
          "Was du schon gelesen hast, steht in deinen Notizen — fang nicht von vorn an."

      Stand.form(s) == nil ->
        "Notier die FORM: welche Form ergibt sich aus der Überschrift „#{s.ueberschrift}“?"

      Stand.abschnitt(s, "GLIEDERUNG") == [] ->
        "Leg die GLIEDERUNG an, Punkt für Punkt, je mit den Fakten und Bögen, die er abdeckt."

      Stand.arc_ohne_gliederung(s) != [] ->
        "Nimm diese Handlungsbögen in die GLIEDERUNG auf: " <>
          Enum.join(Stand.arc_ohne_gliederung(s), ", ") <> "."

      true ->
        "Prüf deine Gliederung mit notizen_lesen() und schließ mit fertig() ab."
    end
  end
end
