defmodule Worker.Jack.Epos.Zusammenfassung do
  @moduledoc """
  Was nach einer Kompaktierung im Epos-Jack an die Stelle des
  weggeschnittenen Verlaufs tritt (#1210) — ein Arbeitsstand, den die
  Werkzeuge aus ihren Daten schreiben, keine Zusammenfassung durch das Modell
  (Muster `Worker.Jack.Resuemee.Zusammenfassung`, deren Rückruf hier mit
  eigenem Text läuft).

    * **Überblick (E1):** der Auftrag in wenigen Zeilen, der Stil
      (Überschrift, Grundton, Epos-Ton), wo Jack steht, seine Notizen und der
      nächste Schritt.
    * **Schreiben (E2):** der Auftrag, der Stil, der Stand des Kapitels
      (Absätze, Wörter, Wörter je Absatz, Szenen ohne Absatz als Hinweis),
      die Notizen aus dem Überblick — FORM zuerst, dann die Szenen —, das
      Kapitel gekürzt je Absatz und der nächste Schritt.
    * **Durchsicht (E3):** der Auftrag (stilistisch und gegen grobe
      Schnitzer), der Stil samt FORM, der Stand der Durchsicht (Kapitel,
      Durchgang, Zähler, je Absatz Status und Hinweise), die Notizen gekürzt
      (je Eintrag Schlüssel und Zeile), das Kapitel gekürzt und der nächste
      Schritt.
  """

  alias Worker.Jack.Epos.{Durchsicht, Entwurf, Notizen, Weg}
  alias Worker.Jack.Resuemee.Durchsicht, as: Buch
  alias Worker.Jack.Resuemee.Stand
  alias Worker.Jack.Resuemee.Zusammenfassung, as: Gemeinsam

  @kopf "# Stand deiner Arbeit (von deinen Werkzeugen geschrieben, nicht zusammengefasst)"

  @doc "Der Rückruf für `kontext: [zusammenfassen: …]` eines Laufs mit diesem Halter."
  @spec fuer(pid()) :: (map() -> String.t())
  def fuer(halter), do: Gemeinsam.fuer(halter, &text/1)

  @doc "Der Arbeitsstand als Text."
  @spec text(Stand.t()) :: String.t()
  def text(%Stand{lauf: :durchsicht} = s) do
    Enum.join(
      [
        @kopf,
        "",
        "## Auftrag",
        "Du siehst das Epos-Kapitel von Sitzung #{s.sitzung.nummer} für die Spalte",
        "„#{s.ueberschrift}“ durch, Absatz für Absatz. Gut zu lesen hat Vorrang: du bestätigst,",
        "was trägt, und ersetzt, wo der Lesefluss stockt, der Ton nicht zur FORM passt, sich",
        "Wörter oder Bilder wiederholen, ein Übergang fehlt oder ein grober Schnitzer gegen die",
        "Fakten steht — jede Ersetzung mit grund. Ein gelungener Absatz bleibt, wie er ist. Je",
        "Absatz: durchsicht(nummer), dann absatz_bestaetigen, absatz_ersetzen oder",
        "absatz_streichen.",
        "",
        "## Stil",
        "Überschrift der Epos-Spalte: „#{s.ueberschrift}“",
        "",
        Stand.ton(s.flavor, :epos),
        "",
        "FORM: " <> form_zeile(s),
        "",
        "## Wo du stehst",
        Durchsicht.stand_text(s),
        "",
        "## Deine Notizen aus dem Überblick (gekürzt; vollständig mit notizen_lesen())",
        notizen_kurz(s),
        "",
        "## Dein Kapitel (gekürzt; vollständig mit entwurf())",
        Entwurf.entwurf_kurz(s),
        "",
        "## Nächster Schritt",
        Buch.naechster_schritt(s)
      ],
      "\n"
    )
  end

  def text(%Stand{lauf: :schreiben} = s) do
    Enum.join(
      [
        @kopf,
        "",
        "## Auftrag",
        "Du erzählst das Epos-Kapitel von Sitzung #{s.sitzung.nummer} für die Spalte",
        "„#{s.ueberschrift}“ — frei und schön zu lesen, Szene für Szene, Absatz für Absatz mit",
        "absatz(). Gut zu lesen hat Vorrang: das Kapitel folgt dem Stil unten und deiner FORM.",
        "Handlung treu, Erzählweise frei — Figuren, Orte, Ereignisse und Ausgänge kommen aus",
        "den Fakten. In szene nennst du die Szene, die ein Absatz erzählt. Den Kopf des",
        "Kapitels setzt das System davor.",
        "",
        "## Stil",
        "Überschrift der Epos-Spalte: „#{s.ueberschrift}“",
        "",
        Stand.ton(s.flavor, :epos),
        "",
        "## Wo du stehst",
        Entwurf.stand_text(s),
        "",
        "## Deine Notizen aus dem Überblick",
        notizen(s, "(keine Notizen)"),
        "",
        "## Dein Kapitel (gekürzt; vollständig mit entwurf())",
        Entwurf.entwurf_kurz(s),
        "",
        "## Nächster Schritt",
        naechster_schritt(s)
      ],
      "\n"
    )
  end

  def text(%Stand{} = s) do
    Enum.join(
      [
        @kopf,
        "",
        "## Auftrag",
        "Du bereitest das Epos-Kapitel von Sitzung #{s.sitzung.nummer} für die Spalte",
        "„#{s.ueberschrift}“ vor. Gut zu lesen hat Vorrang: das Kapitel folgt dem Stil unten",
        "und erzählt den Weg der Gruppe durch die Sitzung in Szenen. Handlung treu,",
        "Erzählweise frei — Figuren, Orte, Ereignisse und Ausgänge kommen aus den Fakten.",
        "Hier liest du alle Fakten, notierst unter FORM die Form (aus der Überschrift) und",
        "die Erzählhaltung (aus dem Epos-Ton), prüfst den Weg aus dem Resümee (resuemee())",
        "und stellst deine SZENEN auf — so viele, wie die Sitzung braucht. Jede Station des",
        "Wegs steht am Ende in einer Szene oder mit Grund unter ABWEICHUNG. Geschrieben wird",
        "im nächsten Auftrag; dort hast du nur deine Notizen.",
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
        notizen(s, "(noch keine Notizen)"),
        "",
        "## Nächster Schritt",
        naechster_schritt(s)
      ],
      "\n"
    )
  end

  defp notizen(s, leer) do
    case String.trim(Notizen.notizen_text(s)) do
      "" -> leer
      t -> t
    end
  end

  defp form_zeile(s) do
    case Stand.form(s) do
      %{zeile: z} -> z
      nil -> "(aus dem Überblick liegt keine vor)"
    end
  end

  # Die Notizen ohne ihre Fakten- und Bogenlisten: je Eintrag Schlüssel und
  # Zeile. Die Fakten einer Szene zeigt durchsicht() beim Absatz.
  defp notizen_kurz(s) do
    kurz = Enum.map(s.notizen, &%{&1 | fakten: [], boegen: []})

    case String.trim(Worker.Jack.Resuemee.Notizen.text_aus(kurz, "### ", Stand.abschnitte(:epos))) do
      "" -> "(keine Notizen)"
      t -> t
    end
  end

  defp naechster_schritt(%Stand{lauf: :schreiben} = s) do
    cond do
      s.entwurf == [] ->
        "Erzähl die erste Szene mit absatz(), im Stil oben und in deiner FORM."

      Entwurf.ohne_absatz(s) != [] ->
        "Erzähl weiter, Szene für Szene. " <> Entwurf.hinweis_szenen(s)

      true ->
        "Lies dein Kapitel mit entwurf(), überarbeite, was sich besser lesen lässt, und " <>
          "schließ mit fertig() ab."
    end
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
