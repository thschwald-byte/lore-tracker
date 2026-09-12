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
  alias Worker.Jack.Resuemee.{Halter, Notizen, Stand}

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

  @doc "Der Arbeitsstand als Text."
  @spec text(Stand.t()) :: String.t()
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
