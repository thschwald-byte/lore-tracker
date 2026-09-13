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

  **Länge (#1209):** das Resümee ist ein „Was bisher geschah“ in höchstens
  `max_woerter` Wörtern — je Kampagne in „Stil setzen“ gesetzt, sonst 75
  (`Shared.ResuemeeLaenge`, gelesen von `Worker.Jack.Resuemee.Eingabe`).
  Der Überblick gliedert in höchstens
  `Worker.Jack.Resuemee.Stand.max_gliederung/1` Punkte und wählt damit aus
  (`Worker.Jack.Resuemee.Notizen`); das Schreiben schließt erst unter der
  Grenze ab, die Durchsicht ersetzt nicht darüber hinaus. Die Aufträge
  erklären es (`{{max_woerter}}`, `{{max_gliederung}}`), die Werkzeuge prüfen
  es hart.

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

  alias Worker.Jack.{Phase, Pipeline, Systemprompt}
  alias Worker.Jack.Resuemee.{Durchsicht, Eingabe, Entwurf, Ergebnis, Halter, Melder, Notizen}
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

    with {:ok, u} <- gemeldet(@stufe_ueberblick, melde, opts, &laufen_ueberblick(eingabe, &1)),
         ablage = Stand.ablage(u.stand),
         {:ok, s} <-
           gemeldet(@stufe_schreiben, melde, opts, &laufen_schreiben(eingabe, ablage, &1)) do
      {:ok, durchsehen(%{ueberblick: u, schreiben: s}, eingabe, ablage, melde, opts)}
    end
  end

  # Ein Lauf als Stufe des Laufbands: Beginn, ein Melder für die Zählung (er
  # reicht jeden Stand an den `:stand_beobachter` weiter), Ende. `tag` markiert
  # den Fehler fürs Band (die Durchsicht bekommt ihre eigene Klasse).
  defp gemeldet(stufe, melde, opts, lauf, tag \\ nil) do
    melde.(stufe, :beginn)
    melder = Melder.start(melde, stufe, weiter: opts[:stand_beobachter])
    ergebnis = lauf.(Keyword.put(opts, :stand_beobachter, melder))
    Melder.stopp(melder)
    melde.(stufe, {:ende, fuers_band(ergebnis, tag)})
    ergebnis
  end

  defp fuers_band({:ok, _}, _tag), do: :ok
  defp fuers_band({:error, grund}, nil), do: {:error, grund}
  defp fuers_band({:error, grund}, tag), do: {:error, {tag, grund}}

  defp durchsehen(r, eingabe, ablage, melde, opts) do
    if Keyword.get(opts, :durchsicht, true) do
      lauf = &laufen_durchsicht(eingabe, ablage, r.schreiben.stand.entwurf, &1)

      case gemeldet(@stufe_durchsicht, melde, opts, lauf, :resuemee_durchsicht) do
        {:ok, d} ->
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
    starten(
      eingabe,
      opts,
      fn -> Stand.neu(eingabe) end,
      fn -> auftrag(eingabe) end,
      :ueberblick_ohne_abschluss
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
           starten(
             eingabe,
             opts,
             fn -> Stand.fuer_schreiben(eingabe, ablage) end,
             fn -> auftrag_schreiben(eingabe, ablage) end,
             :schreiben_ohne_abschluss
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
    with :ok <- fakten_da(eingabe),
         :ok <- entwurf_da(entwurf),
         {:ok, r} <-
           starten(
             eingabe,
             opts,
             fn -> Stand.fuer_durchsicht(eingabe, ablage, entwurf) end,
             fn -> auftrag_durchsicht(eingabe, ablage, entwurf) end,
             :durchsicht_ohne_abschluss
           ) do
      {:ok, Map.put(r, :markdown, Ergebnis.markdown(r.stand))}
    end
  end

  defp entwurf_da(entwurf) do
    if Stand.entwurf_aus(entwurf) == [], do: {:error, :entwurf_leer}, else: :ok
  end

  defp starten(eingabe, opts, stand, auftrag, fehler) do
    with :ok <- fakten_da(eingabe),
         {:ok, modell} <- aus_opts(opts, :modell, &Pipeline.modell/0),
         {:ok, fenster} <- fenster(opts),
         {:ok, auftrag} <- aus_opts(opts, :auftrag, auftrag) do
      case fahren(stand.(), auftrag, modell, fenster, opts) do
        {:ok, r} -> {:ok, r}
        {:error, ende} -> {:error, {fehler, ende}}
      end
    end
  end

  defp fakten_da(%{fakten: [_ | _]}), do: :ok
  defp fakten_da(_eingabe), do: {:error, :keine_fakten}

  defp aus_opts(opts, schluessel, sonst) do
    case Keyword.fetch(opts, schluessel) do
      {:ok, wert} -> {:ok, wert}
      :error -> sonst.()
    end
  end

  # Ein zu kleines Fenster ist vor dem Lauf ein Fehler, statt dass die
  # Laufzeit mitten im Start mit `ArgumentError` abbricht (wie
  # `Pipeline.kontext_fenster/0`).
  defp fenster(opts) do
    mindestens = Phase.mindestfenster()

    case Keyword.fetch(opts, :kontext_fenster) do
      {:ok, n} when is_integer(n) and n >= mindestens -> {:ok, n}
      {:ok, anderes} -> {:error, {:kontext_fenster_ungueltig, anderes, mindestens}}
      :error -> Pipeline.kontext_fenster()
    end
  end

  defp fahren(s, auftrag, modell, fenster, opts) do
    {:ok, halter} = Halter.start_link(s, beobachter: opts[:stand_beobachter])

    ergebnis =
      Worker.Agent.laufen(
        modell: modell,
        system: Systemprompt.pi(),
        nachrichten: [%{role: :user, content: auftrag}],
        denken_zurueck: Keyword.get(opts, :denken_zurueck, false),
        werkzeuge: Werkzeuge.fuer(halter),
        kontext: Phase.kontext(fenster, Zusammenfassung.fuer(halter)),
        max_runden: Keyword.get(opts, :max_runden, 5000),
        max_ms: Keyword.get(opts, :max_ms, 6 * 3_600_000),
        beobachter: opts[:beobachter],
        protokoll: opts[:protokoll],
        bei_stopp: Keyword.get(opts, :bei_stopp, &Phase.nachhaken/1)
      )

    stand = Halter.stand(halter)
    Agent.stop(halter)

    case ergebnis do
      {:ok, %{ende: :halt} = b} -> {:ok, %{stand: stand, runden: b.runden, ms: b.ms}}
      _ -> {:error, Phase.ende(ergebnis)}
    end
  end

  # ─── Aufträge ─────────────────────────────────────────────────────────

  @doc """
  Der Auftrag des Überblicks: die Vorlage `resuemee_ueberblick.md` aus `dir`
  (Default `priv/jack/auftraege/`), gefüllt mit `fuellen/2`. Fehlt sie, ist
  das `{:error, {:auftrag_fehlt, pfad}}`.
  """
  @spec auftrag(map(), Path.t() | nil) :: {:ok, String.t()} | {:error, term()}
  def auftrag(eingabe, dir \\ nil) do
    with {:ok, text} <- vorlage(@vorlage_ueberblick, dir), do: {:ok, fuellen(text, eingabe)}
  end

  @doc """
  Der Auftrag des Schreibens: die Vorlage `resuemee_schreiben.md` aus `dir`
  (Default `priv/jack/auftraege/`), gefüllt mit `fuellen_schreiben/3`. Fehlt
  sie, ist das `{:error, {:auftrag_fehlt, pfad}}`.
  """
  @spec auftrag_schreiben(map(), map() | nil, Path.t() | nil) ::
          {:ok, String.t()} | {:error, term()}
  def auftrag_schreiben(eingabe, ablage, dir \\ nil) do
    with {:ok, text} <- vorlage(@vorlage_schreiben, dir),
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
    with {:ok, text} <- vorlage(@vorlage_durchsicht, dir),
         do: {:ok, fuellen_durchsicht(text, eingabe, ablage, entwurf)}
  end

  defp vorlage(name, dir) do
    pfad = Path.join(dir || Application.app_dir(:worker, "priv/jack/auftraege"), name)

    case File.read(pfad) do
      {:ok, text} -> {:ok, text}
      {:error, _} -> {:error, {:auftrag_fehlt, pfad}}
    end
  end

  @doc """
  Setzt die Angaben einer Sitzung in die Vorlage ein: `{{ueberschrift}}`,
  `{{sitzung}}` (Sessionnummer), `{{anzahl_fakten}}`, `{{letzter_block}}`,
  `{{fruehere}}` (ein Satz über die früheren Sitzungen; ohne sie der
  neutrale Hinweis `Worker.Jack.Resuemee.Stand.keine_frueheren/0`),
  `{{max_woerter}}` (die Länge des Resümees, #1209; ohne sie der Standard,
  `Shared.ResuemeeLaenge.wirksam/1`) und `{{max_gliederung}}` (höchstens so
  viele Gliederungspunkte, `Worker.Jack.Resuemee.Stand.max_gliederung/1`).
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
      "fruehere" => fruehere_text(fruehere),
      "max_woerter" => Integer.to_string(max_woerter),
      "max_gliederung" => Integer.to_string(Stand.max_gliederung(max_woerter))
    }
  end

  # In einem Durchgang: was eingesetzt wird (Ton und Notizen sind Text von
  # Menschen bzw. vom Modell), wird nicht noch einmal nach Platzhaltern
  # durchsucht.
  defp einsetzen(text, werte),
    do: Regex.replace(~r/\{\{(\w+)\}\}/, text, fn ganz, name -> Map.get(werte, name, ganz) end)

  defp fruehere_text([]), do: Stand.keine_frueheren()
  defp fruehere_text([n]), do: "Vor dieser Sitzung liegt Sitzung #{n}."

  defp fruehere_text(nrs),
    do: "Vor dieser Sitzung liegen die Sitzungen #{Enum.join(nrs, ", ")}."
end
