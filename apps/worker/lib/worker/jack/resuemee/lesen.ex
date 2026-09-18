defmodule Worker.Jack.Resuemee.Lesen do
  @moduledoc """
  Die lesenden Werkzeuge des Resümee-Jack (J5, #1209): die Fakten (`fakten`,
  `fakt`), die Bögen (`boegen`), die Vorgeschichte (`vorige_resuemees`,
  `vorige_gedanken`) und der Mitschnitt (`bloecke`, `block`, `cast`,
  `straenge`). Pur wie `Worker.Jack.Lesen`: Stand und Argumente hinein, neuer
  Stand und Ergebnis heraus. Dazu hängt es die gemeinsame Lesebasis ein (E0,
  #1210): `boegen_kampagne` und `vorige_kapitel`
  (`Worker.Jack.Resuemee.Bisher`), `suche_sitzung` und `suche_bisher`
  (`Worker.Jack.Resuemee.Suche`, an Stelle des `suche` des Fakten-Jack) und
  den Mitschnitt früherer Sitzungen (`Worker.Jack.Resuemee.Mitschnitte`).

  **Der Mitschnitt kommt aus `Worker.Jack.Lesen`**: dieselben Funktionen auf
  dem `Worker.Jack.Stand` im Feld `mitschnitt`, dieselbe Nummerierung wie beim
  Fakten-Jack; `bloecke` und `block` bekommen einen Satz dazu, wofür der
  Mitschnitt hier da ist — zum Verstehen der Fakten; der Stoff des Resümees
  sind die Fakten —, und das optionale Feld `sitzung` für den Mitschnitt
  einer früheren Sitzung. `cast` und `straenge` tragen eigene
  Beschreibungen, weil die des Fakten-Jack auf Felder seiner Aussagen zeigen
  (`cast_match`, `threads`), die es hier nicht gibt.

  **`fakt(id)` zeigt auch bei einem früheren Fakt die Belegblöcke** — aus dem
  Mitschnitt jener Sitzung, geladen beim ersten Zugriff; ohne Lader oder ohne
  Glättung sagt die Antwort, warum sie fehlen.

  **Als gelesen zählen nur Fakten dieser Sitzung**, über `fakten` oder
  `fakt`. Daran prüft `fertig`, ob Jack alle vor sich hatte. Die Fakten
  früherer Sitzungen sind Vorgeschichte.

  **Ohne frühere Sitzungen** antworten `fakten(sitzung: …)`,
  `vorige_resuemees` und `vorige_gedanken` mit dem neutralen Hinweis
  `Worker.Jack.Resuemee.Stand.keine_frueheren/0` — als gewöhnliche Antwort:
  es fehlt nichts, es gibt nur noch nichts.

  Die Texte stehen mit Umlauten; sie sind neu und nicht Teil einer Messung
  wie die portierten Texte des Fakten-Jack.
  """

  alias Worker.Jack.Lesen, as: Mitschnitt
  alias Worker.Jack.Resuemee.{Bisher, Mitschnitte, Notizen, Stand, Suche}

  @erzaehlzeit %{
    "flashback" => "Rückblende",
    "future" => "Vorausschau",
    "unknown" => "Erzählzeit unklar"
  }
  @kopfzeile "ID\tFigur\tTyp\tBögen (Art)\tZeit\tBlöcke\tAussage"

  @type ergebnis :: {Stand.t(), Worker.Agent.Werkzeug.ergebnis()}

  @doc "Die Werkzeuge dieses Moduls für einen Stand, siehe `Worker.Jack.Lesen.werkzeuge/1`."
  @spec werkzeuge(Stand.t()) :: [map()]
  def werkzeuge(%Stand{} = s) do
    [
      %{
        name: "fakten",
        beschreibung:
          "Liest Fakten, portionsweise. Ohne sitzung die Fakten dieser Sitzung " <>
            "(#{s.sitzung.nummer}), durchnummeriert 1 bis #{length(s.fakten)}; von und bis " <>
            "sind diese Nummern, der Bereich ist einschließlich. Spalten: ID, Figur, Typ, " <>
            "Bögen (Art), Zeit, Blöcke, Aussage. Mit sitzung liest du die Fakten einer " <>
            "früheren Sitzung als Vorgeschichte. Wie groß du den Bereich wählst, entscheidest du.",
        parameter:
          objekt(%{
            "sitzung" => zahl("Nummer einer früheren Sitzung; ohne Angabe diese Sitzung"),
            "von" => zahl("erste Nummer"),
            "bis" => zahl("letzte Nummer")
          }),
        optional: ["sitzung"],
        ausfuehren: &fakten/2
      },
      %{
        name: "fakt",
        beschreibung:
          "Ein einzelner Fakt über seine ID (erste Spalte von fakten()), samt dem Text " <>
            "seiner Belegblöcke im Mitschnitt. Damit siehst du, was hinter einer Aussage steht.",
        parameter:
          objekt(%{
            "id" => %{"type" => "string", "description" => "die ID des Fakts, z. B. \"S3-F12\""}
          }),
        ausfuehren: &fakt/2
      },
      %{
        name: "boegen",
        beschreibung:
          "Die Bögen, die Fakten dieser Sitzung berühren: Titel, Art, Status, Leitfrage " <>
            "und die IDs der Fakten dazu. " <> boegen_zweck(s),
        parameter: objekt(%{}),
        wiederholung: :frei,
        ausfuehren: &boegen/2
      },
      %{
        name: "vorige_resuemees",
        beschreibung:
          "Die Resümees früherer Sitzungen — Hintergrund für Anschluss und Bezeichnungen. " <>
            "von und bis sind Sitzungsnummern; ohne Angabe alle früheren.",
        parameter:
          objekt(%{
            "von" => zahl("erste Sitzungsnummer"),
            "bis" => zahl("letzte Sitzungsnummer")
          }),
        optional: ["von", "bis"],
        ausfuehren: &vorige_resuemees/2
      },
      %{
        name: "vorige_gedanken",
        beschreibung:
          "Was zu einer früheren Sitzung notiert wurde: das Gedächtnis beim Lesen ihres " <>
            "Mitschnitts (Figuren, Ablauf, Auftrag, Themen, Offenes), die Notizen zu " <>
            "ihrem Resümee und die zu ihrem Epos-Kapitel (Form, Szenen). Hintergrund für " <>
            "Anschluss und Bezeichnungen.",
        parameter: objekt(%{"sitzung" => zahl("Nummer der früheren Sitzung")}),
        ausfuehren: &vorige_gedanken/2
      }
    ] ++ Bisher.werkzeuge(s) ++ mitschnitt(s)
  end

  # Wofür die Bögen da sind, je Lauf; im Überblick der Text von B1. Beim
  # Epos-Jack (#1210) die Szenen statt der Gliederung; in seiner Durchsicht
  # (E3) dasselbe Nachschlagen wie beim Resümee.
  defp boegen_zweck(%Stand{art: :epos, lauf: :durchsicht}),
    do: "Zum Nachschlagen, zu welchem Bogen ein Fakt gehört."

  defp boegen_zweck(%Stand{art: :epos}), do: "Sie sind die Grundlage deiner Szenen."

  # Der Chronik-Jack (#1211) hat kein fertig(ausgelassen) und schreibt kein
  # Resümee — ohne eigene Klausel bekäme er hier eine Regel des Resümee-Jack
  # genannt (Fund des Reviews vom 18.09.2026).
  defp boegen_zweck(%Stand{art: :chronik}),
    do:
      "Ein Bogen kann mehrere Phasen der Chronik umfassen; er ist ein Ausgangspunkt, keine Phase."

  defp boegen_zweck(%Stand{lauf: :schreiben}),
    do:
      "Jeder Bogen der Art arc kommt im Resümee vor oder steht begründet in fertig(ausgelassen)."

  defp boegen_zweck(%Stand{lauf: :durchsicht}),
    do: "Zum Nachschlagen, zu welchem Bogen ein Fakt gehört."

  defp boegen_zweck(%Stand{}), do: "Sie sind die Grundlage deiner Gliederung."

  defp objekt(props), do: %{"type" => "object", "properties" => props}

  defp zahl(beschreibung),
    do: %{"type" => "integer", "minimum" => 1, "description" => beschreibung}

  # ─── fakten, fakt ─────────────────────────────────────────────────────

  @doc "Einen Bereich von Fakten lesen (Werkzeug `fakten`)."
  @spec fakten(Stand.t(), map()) :: ergebnis()
  def fakten(%Stand{} = s, %{"von" => von, "bis" => bis} = p) do
    case sitzung_fakten(s, p["sitzung"]) do
      {:hinweis, text} -> {s, {:ok, text}}
      {:error, text} -> {s, {:error, text}}
      {:ok, nr, liste} -> portion(s, nr, liste, von, bis)
    end
  end

  defp sitzung_fakten(s, nil), do: {:ok, s.sitzung.nummer, s.fakten}
  defp sitzung_fakten(%Stand{sitzung: %{nummer: n}} = s, n), do: {:ok, n, s.fakten}
  defp sitzung_fakten(%Stand{fruehere: []}, _nr), do: {:hinweis, Stand.keine_frueheren()}

  defp sitzung_fakten(s, nr) do
    case Enum.find(s.fruehere, &(&1.nummer == nr)) do
      nil -> {:error, nicht_frueher(s, nr)}
      f -> {:ok, nr, f.fakten}
    end
  end

  defp nicht_frueher(s, nr) do
    "Sitzung #{nr} gehört nicht zu den früheren Sitzungen. Früher sind: " <>
      "#{Enum.join(Stand.fruehere_nummern(s), ", ")}. Ohne sitzung liest du diese " <>
      "Sitzung (#{s.sitzung.nummer})."
  end

  defp portion(s, nr, liste, von, bis) do
    n = length(liste)

    cond do
      n == 0 ->
        {s, {:ok, "Sitzung #{nr} hat keine Fakten."}}

      von > bis ->
        {s,
         {:error,
          "von (#{von}) ist größer als bis (#{bis}). Der Bereich ist einschließlich: " <>
            "fakten(von, bis) mit von <= bis."}}

      von > n ->
        {s,
         {:error,
          "Der Bereich #{von}-#{bis} liegt hinter den Fakten. " <>
            "Sitzung #{nr} hat die Fakten 1 bis #{n}."}}

      true ->
        b = min(bis, n)
        teil = Enum.slice(liste, (von - 1)..(b - 1)//1)
        diese = nr == s.sitzung.nummer
        kopf = "Sitzung #{nr}, Fakten #{von} bis #{b} von #{n}.\n" <> @kopfzeile

        {Stand.gelesen_merken(s, teil),
         {:ok, Enum.join([kopf | Enum.map(teil, &zeile(&1, diese))], "\n")}}
    end
  end

  @doc "Einen Fakt samt Belegblöcken lesen (Werkzeug `fakt`)."
  @spec fakt(Stand.t(), map()) :: ergebnis()
  def fakt(%Stand{} = s, %{"id" => id}) do
    case Stand.fakt(s, id) do
      nil ->
        {s,
         {:error,
          "Einen Fakt #{Jason.encode!(id)} gibt es nicht. Die IDs stehen in der ersten " <>
            "Spalte von fakten()."}}

      f ->
        if Stand.diese_sitzung?(s, f) do
          {Stand.gelesen_merken(s, [f]),
           {:ok, Enum.join([@kopfzeile, zeile(f, true), "", belege(s, f)], "\n")}}
        else
          # E0 (#1210): die Belege aus dem Mitschnitt jener Sitzung, geladen
          # beim ersten Zugriff. Ein früherer Fakt zählt nicht als gelesen.
          {s, belege} = Mitschnitte.belege(s, f)
          {s, {:ok, Enum.join([@kopfzeile, zeile(f, false), "", belege], "\n")}}
        end
    end
  end

  defp belege(s, f) do
    zeilen =
      for n <- f.bloecke,
          {_, {:ok, z}} <- [Mitschnitt.block(s.mitschnitt, %{"nummer" => n})],
          do: z

    kopf =
      if zeilen == [],
        do: "Belegblöcke: keine im Mitschnitt dieser Sitzung.",
        else: "Belegblöcke:"

    rest =
      if f.ohne_block > 0,
        do: [
          "#{f.ohne_block} Beleg(e) liegen außerhalb des Mitschnitts dieser Sitzung " <>
            "(neu geglättet oder als unbrauchbar markiert)."
        ],
        else: []

    Enum.join([kopf | zeilen] ++ rest, "\n")
  end

  @doc "Eine Faktzeile; `diese?` sagt, ob der Fakt zu dieser Sitzung gehört."
  @spec zeile(Stand.fakt(), boolean()) :: String.t()
  def zeile(f, diese?) do
    Enum.join(
      [
        f.id,
        f.figur || "—",
        f.typ,
        boegen_text(f.boegen),
        zeit_text(f),
        bloecke_text(f, diese?),
        f.aussage
      ],
      "\t"
    )
  end

  defp boegen_text([]), do: "—"
  defp boegen_text(bs), do: Enum.map_join(bs, "; ", &"#{&1.titel} (#{&1.art})")

  defp zeit_text(f) do
    case Enum.reject([f.datum, @erzaehlzeit[f.erzaehlzeit]], &is_nil/1) do
      [] -> "—"
      teile -> Enum.join(teile, " · ")
    end
  end

  defp bloecke_text(f, false), do: "(Sitzung #{f.sitzung})"

  defp bloecke_text(f, true) do
    basis = if f.bloecke == [], do: "—", else: Enum.join(f.bloecke, ", ")
    if f.ohne_block > 0, do: basis <> " (+#{f.ohne_block} außerhalb)", else: basis
  end

  # ─── boegen ───────────────────────────────────────────────────────────

  @doc "Die Bögen dieser Sitzung (Werkzeug `boegen`)."
  @spec boegen(Stand.t(), map()) :: ergebnis()
  def boegen(%Stand{boegen: []} = s, _args) do
    weiter =
      case {s.art, s.lauf} do
        {:epos, _} -> "Stell deine Szenen nach dem auf, was die Fakten erzählen"
        {_, :schreiben} -> "Erzähl nach deiner GLIEDERUNG"
        {_, :durchsicht} -> "Prüf den Entwurf an den Fakten"
        _ -> "Gliedere nach dem, was die Fakten erzählen"
      end

    {s,
     {:ok,
      "Die Fakten dieser Sitzung gehören zu keinem Bogen. #{weiter}; straenge() nennt die " <>
        "Stränge der ganzen Kampagne."}}
  end

  def boegen(%Stand{} = s, _args) do
    zugeordnet = s.boegen |> Enum.flat_map(& &1.fakten) |> MapSet.new()
    ohne = for f <- s.fakten, not MapSet.member?(zugeordnet, f.id), do: f.id

    zeilen =
      Enum.map(s.boegen, fn b ->
        Enum.join(
          [
            b.titel,
            "Art: #{b.art}",
            "Status: #{b.status || "—"}",
            "Leitfrage: #{b.leitfrage || "—"}",
            "Fakten: #{Enum.join(b.fakten, ", ")}"
          ],
          "\t"
        )
      end)

    kopf =
      case {s.art, s.lauf} do
        {:epos, _} ->
          "Bögen, die Fakten dieser Sitzung berühren. Art: arc = Handlungsbogen, context = " <>
            "Hintergrund und Weltwissen, rauschen = Gespräch am Tisch. Deine Szenen nennen " <>
            "diese Titel, wie sie hier stehen."

        {:chronik, _} ->
          "Bögen, die Fakten dieser Sitzung berühren. Art: arc = Handlungsbogen, context = " <>
            "Hintergrund und Weltwissen, rauschen = Gespräch am Tisch. Ein Bogen kann " <>
            "mehrere Phasen der Chronik umfassen."

        {_, :schreiben} ->
          "Bögen, die Fakten dieser Sitzung berühren. Art: arc = Handlungsbogen (jeder kommt " <>
            "im Resümee vor oder steht begründet in fertig(ausgelassen)), context = " <>
            "Hintergrund und Weltwissen, rauschen = Gespräch am Tisch."

        {_, :durchsicht} ->
          "Bögen, die Fakten dieser Sitzung berühren. Art: arc = Handlungsbogen, context = " <>
            "Hintergrund und Weltwissen, rauschen = Gespräch am Tisch."

        _ ->
          "Bögen, die Fakten dieser Sitzung berühren. Art: arc = Handlungsbogen, context = " <>
            "Hintergrund und Weltwissen, rauschen = Gespräch am Tisch. Die Stationen deiner " <>
            "Gliederung — der Weg der Gruppe durch die Sitzung — nennen diese Titel, wie sie " <>
            "hier stehen."
      end

    schluss = if ohne == [], do: [], else: ["", "Ohne Bogen: #{Enum.join(ohne, ", ")}"]
    {s, {:ok, Enum.join([kopf, "" | zeilen] ++ schluss, "\n")}}
  end

  # ─── Vorgeschichte ────────────────────────────────────────────────────

  @doc "Die Resümees früherer Sitzungen (Werkzeug `vorige_resuemees`)."
  @spec vorige_resuemees(Stand.t(), map()) :: ergebnis()
  def vorige_resuemees(%Stand{fruehere: []} = s, _args), do: {s, {:ok, Stand.keine_frueheren()}}

  def vorige_resuemees(%Stand{} = s, p) do
    von = p["von"] || 1
    bis = p["bis"] || s.sitzung.nummer - 1

    cond do
      von > bis ->
        {s, {:error, "von (#{von}) ist größer als bis (#{bis})."}}

      true ->
        case Enum.filter(s.vorige_resuemees, &(&1.nummer >= von and &1.nummer <= bis)) do
          [] ->
            {s, {:ok, "Zu den früheren Sitzungen #{von} bis #{bis} liegt kein Resümee vor."}}

          treffer ->
            {s, {:ok, Enum.map_join(treffer, "\n\n", &resuemee_text/1)}}
        end
    end
  end

  defp resuemee_text(r), do: "## Sitzung #{r.nummer}#{name(r)}\n\n" <> String.trim(r.text)

  defp name(%{name: n}) when is_binary(n) and n != "", do: " — " <> n
  defp name(_), do: ""

  @doc "Die Gedanken zu einer früheren Sitzung (Werkzeug `vorige_gedanken`)."
  @spec vorige_gedanken(Stand.t(), map()) :: ergebnis()
  def vorige_gedanken(%Stand{fruehere: []} = s, _args), do: {s, {:ok, Stand.keine_frueheren()}}

  def vorige_gedanken(%Stand{} = s, %{"sitzung" => nr}) do
    if nr in Stand.fruehere_nummern(s) do
      g =
        Enum.find(s.vorige_gedanken, &(&1.nummer == nr)) ||
          %{nummer: nr, fakten_jack: nil, resuemee_jack: nil, epos_jack: nil}

      {s,
       {:ok,
        Enum.join(
          [
            "## Sitzung #{nr} — Gedächtnis beim Lesen des Mitschnitts",
            "",
            gedaechtnis_text(g.fakten_jack),
            "",
            "## Sitzung #{nr} — Notizen zum Resümee",
            "",
            notizen_text(g.resuemee_jack),
            "",
            "## Sitzung #{nr} — Notizen zum Epos-Kapitel",
            "",
            notizen_text(Map.get(g, :epos_jack), Stand.abschnitte(:epos))
          ],
          "\n"
        )}}
    else
      {s, {:error, nicht_frueher(s, nr)}}
    end
  end

  # Die Abschnitte je Jack: beim Resümee-Jack FORM, GLIEDERUNG, OFFEN, beim
  # Epos-Jack FORM, SZENEN, ABWEICHUNG, OFFEN (`Stand.abschnitte/1`).
  defp notizen_text(ablage, abschnitte \\ Stand.abschnitte())

  defp notizen_text(nil, _abschnitte), do: "(keine abgelegt)"

  defp notizen_text(ablage, abschnitte) do
    case String.trim(Notizen.text_aus(ablage, "## ", abschnitte)) do
      "" -> "(keine abgelegt)"
      t -> t
    end
  end

  # Das Register des Fakten-Jack, wie es im abgelegten Stand liegt
  # (String-Schlüssel nach dem JSON-Rundlauf). Die Blocknummern gelten für
  # den Mitschnitt jener Sitzung und bleiben deshalb weg.
  defp gedaechtnis_text(register) when is_list(register) and register != [] do
    reihe = Worker.Jack.Stand.abschnitte_alle()
    gruppen = Enum.group_by(register, &to_string(feld(&1, :abschnitt)))
    namen = reihe ++ Enum.sort(Map.keys(gruppen) -- reihe)

    namen
    |> Enum.flat_map(fn a ->
      zeilen =
        gruppen
        |> Map.get(a, [])
        |> Enum.filter(&(is_binary(feld(&1, :zeile)) and String.trim(feld(&1, :zeile)) != ""))
        |> Enum.map(&"#{feld(&1, :schluessel)} — #{feld(&1, :zeile)}")

      if zeilen == [], do: [], else: ["### " <> a | zeilen] ++ [""]
    end)
    |> Enum.join("\n")
    |> String.trim_trailing()
    |> case do
      "" -> "(keins abgelegt)"
      t -> t
    end
  end

  defp gedaechtnis_text(_), do: "(keins abgelegt)"

  defp feld(m, k) when is_map(m), do: Map.get(m, k) || Map.get(m, Atom.to_string(k))
  defp feld(_m, _k), do: nil

  # ─── Mitschnitt ───────────────────────────────────────────────────────

  # Die Werkzeuge des Fakten-Jack auf dem eingebetteten Mitschnitt-Stand —
  # `bloecke` und `block` mit `sitzung` (`Mitschnitte`), die zwei Suchen an
  # Stelle von `suche` (`Suche`), `cast` und `straenge` mit eigenem Text.
  defp mitschnitt(%Stand{} = s) do
    Mitschnitte.werkzeuge(s) ++
      Suche.werkzeuge(s) ++
      [
        %{
          name: "cast",
          beschreibung:
            "Die bekannten handelnden Personen der Kampagne, je Zeile ein Name — zum " <>
              "Nachschlagen, wie eine Figur heißt.",
          parameter: objekt(%{}),
          wiederholung: :frei,
          ausfuehren: auf_mitschnitt(&Mitschnitt.cast/2)
        },
        %{
          name: "straenge",
          beschreibung:
            "Die bekannten Stränge der ganzen Kampagne, je Zeile ein Titel. Die Bögen " <>
              "dieser Sitzung liefert boegen().",
          parameter: objekt(%{}),
          wiederholung: :frei,
          ausfuehren: auf_mitschnitt(&Mitschnitt.straenge/2)
        }
      ]
  end

  defp auf_mitschnitt(fun) do
    fn %Stand{} = s, argumente ->
      {m, ergebnis} = fun.(s.mitschnitt, argumente)
      {%{s | mitschnitt: m}, ergebnis}
    end
  end
end
