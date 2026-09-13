defmodule Worker.Jack.Resuemee do
  @moduledoc """
  Jack schreibt das Resümee (J5, #1209, Epic #1195) — die Ablaufsteuerung.

  Drei Läufe:

    1. **Überblick** (B1, `laufen_ueberblick/2`) — das Gegenstück zu Jacks
       Gedächtnis: Jack liest alle Fakten der Sitzung, notiert zuerst die
       FORM, die er aus der Überschrift der Resümee-Spalte ableitet, und legt
       danach die GLIEDERUNG an, gestützt auf die Fakten und die
       kampagnenweiten Bögen. Stellen, an denen die Fakten zum Verstehen nicht
       reichen, notiert er unter OFFEN.
    2. **Schreiben** (B2, `laufen_schreiben/3`) — ein frischer Lauf ohne
       Erinnerung an den Überblick (Maintainer): Jack bekommt zuerst den Ton
       (Grundton und Resümee-Ton aus „Stil setzen“), dann seine Notizen
       (FORM zuerst), dann den Auftrag, und schreibt Absatz für Absatz; jeder
       Satz nennt die Fakten, auf die er sich stützt
       (`Worker.Jack.Resuemee.Entwurf`). Heraus kommt der Entwurf als
       Markdown (`Worker.Jack.Resuemee.Ergebnis`).
    3. **Durchsicht** (B3, `laufen_durchsicht/4`) — wieder ein frischer
       Lauf: Jack bekommt Ton, Notizen und seinen Entwurf und geht ihn Absatz
       für Absatz gegen die Fakten durch. Gnädig (Maintainer): er ändert nur
       grobe Schnitzer und bestätigt alles andere
       (`Worker.Jack.Resuemee.Durchsicht`); Hinweise auf großgeschriebene
       Wörter ohne Fundstelle zeigen ihm, wo er genauer hinsieht
       (`Worker.Jack.Resuemee.Hinweise`), lehnen aber nie ab.

  **Länge und Weg (#1209):** das Resümee ist ein „Was bisher geschah“, das
  den **Weg der Gruppe** durch die Sitzung erzählt. `max_woerter` — je
  Kampagne in „Stil setzen“ gesetzt, sonst 150 (`Shared.ResuemeeLaenge`,
  gelesen von `Worker.Jack.Resuemee.Eingabe`) — ist das **Ziel**, das
  Doppelte die **Obergrenze** (`Worker.Jack.Resuemee.Laenge`). Der Überblick
  legt die GLIEDERUNG als Weg an, Station für Station, höchstens
  `Worker.Jack.Resuemee.Stand.max_gliederung/1` Stationen, und bekommt die
  Spanne ihrer Fakten in Blocknummern als Hinweis (`Worker.Jack.Resuemee.Weg`);
  das Schreiben schließt erst ab, wenn jede Station einen Satz hat, der
  Entwurf unter der Obergrenze liegt und — über dem Ziel — eine
  `laenge_begruendung` dasteht; die Durchsicht ersetzt nicht über die
  Obergrenze hinaus und verliert keine Station. Die Aufträge erklären es
  (`{{max_woerter}}`, `{{obergrenze}}`, `{{max_gliederung}}`), die Werkzeuge
  prüfen es hart. Die Begründung des Schreibens reist in den Stand der
  Durchsicht mit, damit sie in den Zählwerten steht.

  `laufen/2` fährt die drei Läufe nacheinander auf derselben Eingabe,
  `resuemee/2` dasselbe für eine Sitzung aus dem Repo — die Eingabe wird
  einmal gebaut. **Scheitert die Durchsicht, gilt der Entwurf aus dem
  Schreiben:** sie darf das Resümee nicht verhindern. Den Einbau in die
  Pipeline, die eigene Modell-Einstellung und das Ablegen des Stands als
  Ereignis trägt `Worker.Jack.Resuemee.Pipeline` (B4).

  **Laufband:** mit `:melde_stufe` meldet `laufen/2` jeden Lauf als eigene
  Stufe (`Shared.PipelineStufen`: `resuemee_ueberblick`, `render`,
  `resuemee_durchsicht`) — Beginn, Ende, und über einen Melder je Lauf die
  Zählung (`Worker.Jack.Resuemee.Melder`). Eine gescheiterte Durchsicht geht
  als `{:error, {:resuemee_durchsicht, grund}}` ans Band, damit sie in
  `/admin/errors` ihre eigene Klasse bekommt.

  **Wie beim Fakten-Jack:** dasselbe Modell (`Worker.Jack.Pipeline.modell/0`;
  in der Pipeline eigens wählbar, `Worker.Jack.Resuemee.Pipeline.modell/0`),
  dasselbe Kontextfenster (`Worker.Jack.Pipeline.kontext_fenster/0`) und
  dieselbe Kompaktierung (`Worker.Jack.Phase.kontext/2`) mit einer
  Zusammenfassung aus dem Arbeitsstand
  (`Worker.Jack.Resuemee.Zusammenfassung`), derselbe Systemprompt
  (`Worker.Jack.Systemprompt.pi/0`) und dasselbe Nachhaken, wenn eine
  Antwort ohne Werkzeugaufruf endet (`Worker.Jack.Phase.nachhaken/1`).

  **Anders als beim Fakten-Jack ist der Auftrag angeheftet** (Default der
  Laufzeit): der Fakten-Jack fährt `anheften: false`, weil seine Aufträge
  so gemessen sind; für das Resümee gibt es keine Messung, gegen die es
  vergleichbar bleiben müsste, und der Auftrag trägt Überschrift, Ton und
  Notizen — genau das, was nach einer Kompaktierung nicht fehlen darf.

  Die Aufträge kommen aus `priv/jack/auftraege/resuemee_ueberblick.md`
  (`auftrag/2`), `resuemee_schreiben.md` (`auftrag_schreiben/3`) und
  `resuemee_durchsicht.md` (`auftrag_durchsicht/4`).
  """

  require Logger

  alias Worker.Jack.Resuemee.{Durchsicht, Eingabe, Entwurf, Ergebnis, Lauf, Melder, Notizen}
  alias Worker.Jack.Resuemee.{Stand, Werkzeuge, Zusammenfassung}

  @vorlage_ueberblick "resuemee_ueberblick.md"
  @vorlage_schreiben "resuemee_schreiben.md"
  @vorlage_durchsicht "resuemee_durchsicht.md"
  @keine_notizen "(Aus dem Überblick liegen keine Notizen vor.)"

  # Die Stufennamen des Laufbands (`Shared.PipelineStufen`). Das Schreiben
  # heißt „render“, weil `/admin/errors` und die Spalten-Anzeige daran hängen.
  @stufe_ueberblick "resuemee_ueberblick"
  @stufe_schreiben "render"
  @stufe_durchsicht "resuemee_durchsicht"

  @doc """
  Der Überblick für eine Sitzung aus dem Repo: `Eingabe.aus_repo/1`, dann
  `laufen_ueberblick/2` mit denselben Optionen.
  """
  @spec ueberblick(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def ueberblick(session_id, opts \\ []) do
    with {:ok, e} <- Eingabe.aus_repo(session_id), do: laufen_ueberblick(e, opts)
  end

  @doc """
  Überblick und Schreiben für eine Sitzung aus dem Repo: `Eingabe.aus_repo/1`
  einmal, dann `laufen/2` mit denselben Optionen.
  """
  @spec resuemee(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def resuemee(session_id, opts \\ []) do
    with {:ok, e} <- Eingabe.aus_repo(session_id), do: laufen(e, opts)
  end

  @doc """
  Überblick, Schreiben und Durchsicht nacheinander auf derselben Eingabe:
  Schreiben und Durchsicht bekommen die Ablage des Überblicks
  (`Worker.Jack.Resuemee.Stand.ablage/1`), die Durchsicht dazu den Entwurf
  des Schreibens. Optionen wie `laufen_ueberblick/2`, für alle Läufe
  dieselben; `:auftrag` gilt hier nicht (ein Text kann nicht alle Aufträge
  sein). `durchsicht: false` überspringt die Durchsicht.

  Liefert `{:ok, %{ueberblick:, schreiben:, durchsicht:, markdown:}}` oder
  den Fehler von Überblick bzw. Schreiben. `durchsicht` ist das Ergebnis von
  `laufen_durchsicht/4`, `:uebersprungen`, oder `{:error, grund}`: **eine
  gescheiterte Durchsicht lässt das Ganze nicht scheitern** — dann ist
  `markdown` der Entwurf aus dem Schreiben, und der Fehler steht im Log und im
  Ergebnis.

  `melde_stufe:` — der Rückruf fürs Laufband (`(stufe, ereignis)` mit
  `:beginn`, `{:ende, :ok | {:error, grund}}`, `{:zaehlung, gesamt,
  durchgang}`, `{:gelesen, n, durchgang}`), siehe Moduledoc. Ohne ihn meldet
  der Lauf nichts. Ein `:stand_beobachter` bekommt jeden Stand weiterhin —
  über den Melder des Laufs.
  """
  @spec laufen(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def laufen(eingabe, opts \\ []) do
    opts = Keyword.delete(opts, :auftrag)
    melde = Keyword.get(opts, :melde_stufe) || fn _stufe, _ereignis -> :ok end
    opts = Keyword.delete(opts, :melde_stufe)

    # Jeder Lauf als Stufe des Laufbands (`Melder.gemeldet/5`).
    with {:ok, u} <-
           Melder.gemeldet(@stufe_ueberblick, melde, opts, &laufen_ueberblick(eingabe, &1)),
         ablage = Stand.ablage(u.stand),
         {:ok, s} <-
           Melder.gemeldet(@stufe_schreiben, melde, opts, &laufen_schreiben(eingabe, ablage, &1)) do
      {:ok, durchsehen(%{ueberblick: u, schreiben: s}, eingabe, ablage, melde, opts)}
    end
  end

  defp durchsehen(r, eingabe, ablage, melde, opts) do
    if Keyword.get(opts, :durchsicht, true) do
      lauf = &laufen_durchsicht(eingabe, ablage, r.schreiben.stand.entwurf, &1)

      case Melder.gemeldet(@stufe_durchsicht, melde, opts, lauf, :resuemee_durchsicht) do
        {:ok, d} ->
          # Die Begründung einer Überschreitung gab das Schreiben; die
          # Zählwerte kommen aus dem Stand der Durchsicht.
          b = r.schreiben.stand.laenge_begruendung
          d = %{d | stand: %{d.stand | laenge_begruendung: b}}
          Map.merge(r, %{durchsicht: d, markdown: d.markdown})

        {:error, grund} = fehler ->
          Logger.warning(
            "Resümee-Jack: Durchsicht von Sitzung #{eingabe.sitzung.nummer} gescheitert, es " <>
              "gilt der Entwurf aus dem Schreiben: #{inspect(grund, limit: 20)}"
          )

          Map.merge(r, %{durchsicht: fehler, markdown: r.schreiben.markdown})
      end
    else
      Map.merge(r, %{durchsicht: :uebersprungen, markdown: r.schreiben.markdown})
    end
  end

  @doc """
  Fährt den Überblick auf einer Eingabe (`Worker.Jack.Resuemee.Eingabe`).

  Optionen: `:modell` (`{modul, opts}`; ohne es `Worker.Jack.Pipeline.modell/0`),
  `:kontext_fenster` (ohne es `Worker.Jack.Pipeline.kontext_fenster/0`;
  mindestens `Worker.Jack.Phase.mindestfenster/0`), `:auftrag` (Text; ohne
  ihn `auftrag/2`), `:denken_zurueck` (Default `false`), `:max_runden`
  (5000), `:max_ms` (6 Stunden), `:beobachter` (bekommt das Protokoll der
  Laufzeit), `:stand_beobachter` (bekommt den Stand, siehe
  `Worker.Jack.Resuemee.Halter`), `:protokoll` (Pfad), `:bei_stopp`
  (Default `Worker.Jack.Phase.nachhaken/1`).

  Liefert `{:ok, %{stand:, runden:, ms:}}`, wenn Jack mit `fertig`
  abschloss; sonst `{:error, {:ueberblick_ohne_abschluss, ende}}`. Eine
  Sitzung ohne Fakten ist `{:error, :keine_fakten}` — ohne Fakten gibt es
  nichts zu gliedern, und `fertig` könnte nie gelingen.
  """
  @spec laufen_ueberblick(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def laufen_ueberblick(eingabe, opts \\ []) do
    Lauf.starten(
      eingabe,
      opts,
      fn -> Stand.neu(eingabe) end,
      fn -> auftrag(eingabe) end,
      :ueberblick_ohne_abschluss,
      jack()
    )
  end

  @doc """
  Fährt das Schreiben auf einer Eingabe, mit der Ablage des Überblicks
  (`Worker.Jack.Resuemee.Stand.ablage/1`) als Notizen. Ein frischer Lauf:
  neuer Halter, `lauf: :schreiben`, nichts gelesen
  (`Worker.Jack.Resuemee.Stand.fuer_schreiben/2`). Optionen wie
  `laufen_ueberblick/2`; ohne `:auftrag` gilt `auftrag_schreiben/3`.

  Liefert `{:ok, %{stand:, runden:, ms:, markdown:}}`, wenn Jack mit
  `fertig` abschloss; sonst `{:error, {:schreiben_ohne_abschluss, ende}}`.
  Ohne Fakten `{:error, :keine_fakten}`.
  """
  @spec laufen_schreiben(map(), map() | nil, keyword()) :: {:ok, map()} | {:error, term()}
  def laufen_schreiben(eingabe, ablage, opts \\ []) do
    with {:ok, r} <-
           Lauf.starten(
             eingabe,
             opts,
             fn -> Stand.fuer_schreiben(eingabe, ablage) end,
             fn -> auftrag_schreiben(eingabe, ablage) end,
             :schreiben_ohne_abschluss,
             jack()
           ) do
      {:ok, Map.put(r, :markdown, Ergebnis.markdown(r.stand))}
    end
  end

  @doc """
  Fährt die Durchsicht auf einer Eingabe, mit der Ablage des Überblicks und
  dem Entwurf aus dem Schreiben (`s.entwurf` des Schreib-Stands, oder als
  JSON — `Worker.Jack.Resuemee.Stand.entwurf_aus/1`). Ein frischer Lauf:
  neuer Halter, `lauf: :durchsicht`
  (`Worker.Jack.Resuemee.Stand.fuer_durchsicht/3`). Optionen wie
  `laufen_ueberblick/2`; ohne `:auftrag` gilt `auftrag_durchsicht/4`.

  Liefert `{:ok, %{stand:, runden:, ms:, markdown:}}` — `markdown` ist der
  Entwurf nach der Durchsicht —, wenn Jack mit `fertig` abschloss; sonst
  `{:error, {:durchsicht_ohne_abschluss, ende}}`. Ohne Fakten
  `{:error, :keine_fakten}`, ohne Absatz im Entwurf `{:error, :entwurf_leer}`.
  """
  @spec laufen_durchsicht(map(), map() | nil, [map()], keyword()) ::
          {:ok, map()} | {:error, term()}
  def laufen_durchsicht(eingabe, ablage, entwurf, opts \\ []) do
    with :ok <- Lauf.fakten_da(eingabe),
         :ok <- entwurf_da(entwurf),
         {:ok, r} <-
           Lauf.starten(
             eingabe,
             opts,
             fn -> Stand.fuer_durchsicht(eingabe, ablage, entwurf) end,
             fn -> auftrag_durchsicht(eingabe, ablage, entwurf) end,
             :durchsicht_ohne_abschluss,
             jack()
           ) do
      {:ok, Map.put(r, :markdown, Ergebnis.markdown(r.stand))}
    end
  end

  defp entwurf_da(entwurf) do
    if Stand.entwurf_aus(entwurf) == [], do: {:error, :entwurf_leer}, else: :ok
  end

  # Die Teile des Resümee-Jack für die gemeinsame Laufmechanik
  # (`Worker.Jack.Resuemee.Lauf`); das Abbild ist `Stand.abbild/1`.
  defp jack, do: %{werkzeuge: &Werkzeuge.fuer/1, zusammenfassung: &Zusammenfassung.fuer/1}

  # ─── Aufträge ─────────────────────────────────────────────────────────

  @doc """
  Der Auftrag des Überblicks: die Vorlage `resuemee_ueberblick.md` aus `dir`
  (Default `priv/jack/auftraege/`), gefüllt mit `fuellen/2`. Fehlt sie, ist
  das `{:error, {:auftrag_fehlt, pfad}}`.
  """
  @spec auftrag(map(), Path.t() | nil) :: {:ok, String.t()} | {:error, term()}
  def auftrag(eingabe, dir \\ nil) do
    with {:ok, text} <- Lauf.vorlage(@vorlage_ueberblick, dir), do: {:ok, fuellen(text, eingabe)}
  end

  @doc """
  Der Auftrag des Schreibens: die Vorlage `resuemee_schreiben.md` aus `dir`
  (Default `priv/jack/auftraege/`), gefüllt mit `fuellen_schreiben/3`. Fehlt
  sie, ist das `{:error, {:auftrag_fehlt, pfad}}`.
  """
  @spec auftrag_schreiben(map(), map() | nil, Path.t() | nil) ::
          {:ok, String.t()} | {:error, term()}
  def auftrag_schreiben(eingabe, ablage, dir \\ nil) do
    with {:ok, text} <- Lauf.vorlage(@vorlage_schreiben, dir),
         do: {:ok, fuellen_schreiben(text, eingabe, ablage)}
  end

  @doc """
  Der Auftrag der Durchsicht: die Vorlage `resuemee_durchsicht.md` aus `dir`
  (Default `priv/jack/auftraege/`), gefüllt mit `fuellen_durchsicht/4`.
  Fehlt sie, ist das `{:error, {:auftrag_fehlt, pfad}}`.
  """
  @spec auftrag_durchsicht(map(), map() | nil, [map()], Path.t() | nil) ::
          {:ok, String.t()} | {:error, term()}
  def auftrag_durchsicht(eingabe, ablage, entwurf, dir \\ nil) do
    with {:ok, text} <- Lauf.vorlage(@vorlage_durchsicht, dir),
         do: {:ok, fuellen_durchsicht(text, eingabe, ablage, entwurf)}
  end

  @doc """
  Setzt die Angaben einer Sitzung in die Vorlage ein: `{{ueberschrift}}`,
  `{{sitzung}}` (Sessionnummer), `{{anzahl_fakten}}`, `{{letzter_block}}`,
  `{{fruehere}}` (ein Satz über die früheren Sitzungen; ohne sie der
  neutrale Hinweis `Worker.Jack.Resuemee.Stand.keine_frueheren/0`),
  `{{max_woerter}}` (das Ziel in Wörtern, #1209; ohne Angabe der Standard,
  `Shared.ResuemeeLaenge.wirksam/1`), `{{obergrenze}}` (das Doppelte,
  `Shared.ResuemeeLaenge.hoechstens/1`) und `{{max_gliederung}}` (höchstens
  so viele Stationen, `Worker.Jack.Resuemee.Stand.max_gliederung/1`).
  Unbekannte Platzhalter bleiben stehen.
  """
  @spec fuellen(String.t(), map()) :: String.t()
  def fuellen(text, eingabe), do: einsetzen(text, grundwerte(eingabe))

  @doc """
  Wie `fuellen/2`, dazu `{{ton}}` (`Worker.Jack.Resuemee.Stand.ton/1` aus
  `eingabe.flavor`) und `{{notizen}}` (die Ablage des Überblicks als Text,
  Abschnitte als `###`, FORM zuerst; ohne Notizen ein Hinweis darauf).
  """
  @spec fuellen_schreiben(String.t(), map(), map() | nil) :: String.t()
  def fuellen_schreiben(text, eingabe, ablage),
    do: einsetzen(text, schreibwerte(eingabe, ablage))

  @doc """
  Wie `fuellen_schreiben/3`, dazu `{{entwurf}}` (der Entwurf aus dem
  Schreiben, wie `entwurf()` ihn zeigt: Absätze mit Nummern, Sätze mit ihren
  Fakten), `{{anzahl_absaetze}}` und `{{max_durchgaenge}}`.
  """
  @spec fuellen_durchsicht(String.t(), map(), map() | nil, [map()]) :: String.t()
  def fuellen_durchsicht(text, eingabe, ablage, entwurf) do
    s = Stand.fuer_durchsicht(eingabe, ablage, entwurf)

    werte =
      eingabe
      |> schreibwerte(ablage)
      |> Map.merge(%{
        "entwurf" => Entwurf.entwurf_text(s),
        "anzahl_absaetze" => Integer.to_string(length(s.entwurf)),
        "max_durchgaenge" => Integer.to_string(Durchsicht.max_durchgaenge())
      })

    einsetzen(text, werte)
  end

  defp schreibwerte(eingabe, ablage) do
    notizen =
      case String.trim(Notizen.text_aus(ablage, "### ")) do
        "" -> @keine_notizen
        t -> t
      end

    eingabe
    |> grundwerte()
    |> Map.merge(%{"ton" => Stand.ton(Map.get(eingabe, :flavor)), "notizen" => notizen})
  end

  defp grundwerte(eingabe) do
    fruehere = eingabe |> Map.get(:fruehere, []) |> Enum.map(& &1.nummer)
    max_woerter = Shared.ResuemeeLaenge.wirksam(Map.get(eingabe, :max_woerter))

    %{
      "ueberschrift" => Map.get(eingabe, :ueberschrift) || "Resümee",
      "sitzung" => to_string(eingabe.sitzung.nummer),
      "anzahl_fakten" => Integer.to_string(length(eingabe.fakten)),
      "letzter_block" => Integer.to_string(max(length(Map.get(eingabe, :bloecke, [])) - 1, 0)),
      "fruehere" => Lauf.fruehere_text(fruehere),
      "max_woerter" => Integer.to_string(max_woerter),
      "obergrenze" => Integer.to_string(Stand.obergrenze(max_woerter)),
      "max_gliederung" => Integer.to_string(Stand.max_gliederung(max_woerter))
    }
  end

  # In einem Durchgang (`Worker.Jack.Resuemee.Lauf.einsetzen/2`).
  defp einsetzen(text, werte), do: Lauf.einsetzen(text, werte)
end
