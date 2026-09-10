defmodule Worker.Jack.Messlauf do
  @moduledoc """
  Ein Messlauf wie Reihe C des Spikes (#1174), für J3 (#1195): derselbe
  Ablauf, dieselben Aufträge, dasselbe Modell, damit der Elixir-Port gegen
  den Spike gemessen werden kann. Nachgebaut aus `treiber_s1.sh`,
  `iterieren.sh` und `kette_c.sh`; eine Phase 3 gibt es nicht mehr (Toms
  Entscheidung, 10.09.).

  **Ablauf.**

    * **Durchgang 1:** Phase 1 (Lesen, Gedächtnis anlegen) mit dem Auftrag
      `s1_phase1.md` und der Zeile „Der Mitschnitt hat die Blöcke 0 bis N.“,
      danach Phase 2 (Sammeln) in einer **frischen** Sitzung mit
      `s1_phase2.md` und dem Gedächtnis aus Phase 1 unter „## Dein
      Gedächtnis“ — wie der Treiber, der das Gedächtnis als Datei rettet,
      nicht den Verlauf. Beide Phasen müssen mit `fertig` abschließen, sonst
      endet der Messlauf (wie `kette_c.sh`, Stufe 1).
    * **Folgedurchgänge:** Phase 2 mit `s1_folgelauf.md` („Verifizieren“),
      der Stand kommt aus der Ablage des vorigen Durchgangs
      (`Worker.Jack.Fortsetzung`). Gesättigt ist der Lauf, wenn ein
      Durchgang keine neue Aussage mehr bringt; höchstens `:durchgaenge`
      (Default 8, wie `kette_c.sh`). Ein Folgedurchgang ohne `fertig` beendet
      den Lauf nicht (wie `iterieren.sh`), nur ein Fehler der Laufzeit.

  **Einstellungen wie in Reihe C** (Torwächter-Log und `pi-konfig`, von eve
  bestätigt): `qwen3.8:27b`, `temperature` 0.7, `top_p` 0.8,
  `frequency_penalty` 0.4, kein Seed, `max_tokens` 60 000 (vom Torwächter
  gesetzt); Kompaktierung bei Fenster 98 304, Reserve 4096, behalten 8000,
  mit dem Arbeitsstand des Spikes (`Worker.Jack.Zusammenfassung`) im Rahmen
  von pi; der Auftrag **nicht** angeheftet (wie pi); pis Standard-
  Systemprompt (`Worker.Jack.Systemprompt`). Das Kontextfenster am Server
  muss 98 304 sein (`OLLAMA_CONTEXT_LENGTH`) — der Client setzt es nicht.

  **Ablage** unter `:nach`: je Durchgang ein Verzeichnis `dN` mit dem Stand
  nach Phase 2 (`aussagen.jsonl`, `fortsetzung.json`, Journal, Protokoll),
  in `d1/phase1` der Stand nach Phase 1, dazu die `:beilagen` (für eves
  Auswertung `paare_bauen.py`: `bloecke_mit_sprecher.tsv`,
  `fakten_voll.tsv`) in jedem `dN`, und `messlauf.json` mit dem Verlauf.

  **Ehrliche Grenzen:**

    * pi schickte zusätzlich `max_completion_tokens` 8192 (aus `models.json`);
      ob Ollama das beachtete, ist aus Reihe C nicht zu sagen — keine Antwort
      wurde so lang. Der Port schickt es nicht.
    * pi kennt weder Runden- noch Zeitdeckel; hier gelten `:max_runden`
      (Default 5000) und `:max_ms` (Default sechs Stunden) je Phase.
    * Der Systemprompt ist rekonstruiert, nicht mitgeschnitten (siehe dort).
  """

  alias Worker.Agent.Modell.Ollama
  alias Worker.Jack.{Fortsetzung, Gedaechtnis, Halter, Stand, Systemprompt, Werkzeuge}
  alias Worker.Jack.Zusammenfassung

  @auftraege %{phase1: "s1_phase1.md", phase2: "s1_phase2.md", folgelauf: "s1_folgelauf.md"}

  @doc """
  Das Modell der Reihe C: `qwen3.8:27b` über Ollama mit dem Sampling des
  Torwächters. Optionen: `:endpunkt`, `:modell_name`, dazu alles, was
  `Worker.Agent.Modell.Ollama` kennt.
  """
  @spec modell_reihe_c(keyword()) :: {module(), keyword()}
  def modell_reihe_c(opts \\ []) do
    {Ollama,
     Keyword.merge(
       [
         endpunkt: "http://localhost:11434",
         modell: Keyword.get(opts, :modell_name, "qwen3.8:27b"),
         temperatur: 0.7,
         max_ausgabe: 60_000,
         extra: %{"top_p" => 0.8, "frequency_penalty" => 0.4}
       ],
       Keyword.drop(opts, [:modell_name])
     )}
  end

  @doc """
  Die Aufträge aus einem Verzeichnis lesen (`s1_phase1.md`, `s1_phase2.md`,
  `s1_folgelauf.md`). Fehlt einer, ist das ein Fehler.
  """
  @spec auftraege(Path.t()) :: {:ok, map()} | {:error, term()}
  def auftraege(dir) do
    Enum.reduce_while(@auftraege, {:ok, %{}}, fn {k, datei}, {:ok, acc} ->
      pfad = Path.join(dir, datei)

      case File.read(pfad) do
        {:ok, text} -> {:cont, {:ok, Map.put(acc, k, text)}}
        {:error, _} -> {:halt, {:error, {:auftrag_fehlt, pfad}}}
      end
    end)
  end

  @doc """
  Der Messlauf. Optionen: `:eingabe` (Pflicht; `%{bloecke:, cast:,
  straenge:}` aus `Worker.Jack.Abzug.spike_laden/2` oder `laden/1`),
  `:auftraege` (Pflicht; aus `auftraege/1`), `:nach` (Pflicht;
  Laufverzeichnis), `:modell` (Default `modell_reihe_c/0`), `:durchgaenge`,
  `:sicht` (Beobachter, etwa `Worker.Jack.Sicht`), `:beilagen` (Liste
  `{quellpfad, zielname}`), `:melden` (`fn ereignis -> … end`, für den
  Mix-Task), `:max_runden`, `:max_ms`.

  Liefert `%{ende: :gesaettigt | :deckel | {:abgebrochen, grund},
  durchgaenge: [...]}`.
  """
  @spec laufen(keyword()) :: map()
  def laufen(opts) do
    e = Keyword.fetch!(opts, :eingabe)
    a = Keyword.fetch!(opts, :auftraege)
    nach = Keyword.fetch!(opts, :nach)
    File.mkdir_p!(nach)

    basis = [bloecke: e.bloecke, cast: e.cast, straenge: e.straenge]
    s1 = Stand.neu(basis ++ [phase: 1])

    auftrag1 =
      String.trim_trailing(a.phase1) <> "\n\nDer Mitschnitt hat die Blöcke 0 bis #{s1.max_block}."

    {p1, s1} = phase(s1, auftrag1, Path.join([nach, "d1", "phase1"]), 1, opts)

    ergebnis =
      if abgeschlossen?(p1) do
        s2 = Stand.neu(basis ++ [phase: 2, register: s1.register])
        erster = durchgang(1, s2, a.phase2, nach, opts)

        if abgeschlossen?(erster.ergebnis),
          do: weiter(2, [erster], basis, a, nach, opts),
          else: fertig({:abgebrochen, {:phase2_ohne_abschluss, ende(erster.ergebnis)}}, [erster])
      else
        fertig({:abgebrochen, {:phase1_ohne_abschluss, ende(p1)}}, [])
      end

    schreiben(nach, ergebnis)
    ergebnis
  end

  defp weiter(n, bisher, basis, a, nach, opts) do
    cond do
      n > Keyword.get(opts, :durchgaenge, 8) ->
        fertig(:deckel, bisher)

      true ->
        vorher = Path.join(nach, "d#{n - 1}")

        case Fortsetzung.laden(vorher, basis ++ [phase: 2]) do
          {:ok, s} ->
            d = durchgang(n, s, a.folgelauf, nach, opts)
            alle = bisher ++ [d]

            cond do
              match?({:error, _}, d.ergebnis) ->
                fertig({:abgebrochen, {:laufzeit, ende(d.ergebnis)}}, alle)

              d.neu <= 0 ->
                fertig(:gesaettigt, alle)

              true ->
                weiter(n + 1, alle, basis, a, nach, opts)
            end

          {:error, grund} ->
            fertig({:abgebrochen, {:fortsetzung, grund}}, bisher)
        end
    end
  end

  defp durchgang(n, %Stand{} = s, auftrag, nach, opts) do
    dir = Path.join(nach, "d#{n}")
    vorher = s.lfd
    text = String.trim_trailing(auftrag) <> "\n\n## Dein Gedächtnis\n\n" <> gedaechtnis(s)
    {ergebnis, s} = phase(s, text, dir, 2, opts)
    beilegen(dir, Keyword.get(opts, :beilagen, []))

    d = %{
      nr: n,
      dir: dir,
      durchgang: s.durchgang,
      vorher: vorher,
      bestand: s.lfd,
      neu: s.lfd - vorher,
      ende: ende(ergebnis),
      ergebnis: ergebnis
    }

    melden(opts, {:durchgang, Map.delete(d, :ergebnis)})
    d
  end

  defp gedaechtnis(s), do: s |> Gedaechtnis.notizen_text() |> String.trim_trailing()

  defp phase(%Stand{} = s, auftrag, dir, nr, opts) do
    File.mkdir_p!(dir)
    melden(opts, {:phase, nr, dir})
    {:ok, halter} = Halter.start_link(s, beobachter: opts[:sicht], ablage: dir)

    ergebnis =
      Worker.Agent.laufen(
        modell: Keyword.get_lazy(opts, :modell, fn -> modell_reihe_c() end),
        system: Systemprompt.pi(),
        nachrichten: [%{role: :user, content: auftrag}],
        anheften: false,
        werkzeuge: Werkzeuge.fuer(halter),
        kontext: [
          fenster: 98_304,
          reserve: 4096,
          behalten: 8000,
          zusammenfassen: Zusammenfassung.fuer(halter)
        ],
        max_runden: Keyword.get(opts, :max_runden, 5000),
        max_ms: Keyword.get(opts, :max_ms, 6 * 3_600_000),
        beobachter: opts[:sicht],
        protokoll: Path.join(dir, "protokoll.jsonl")
      )

    stand = Halter.stand(halter)
    Agent.stop(halter)
    {ergebnis, stand}
  end

  defp abgeschlossen?({:ok, %{ende: :halt}}), do: true
  defp abgeschlossen?(_ergebnis), do: false

  defp ende({_, %{ende: ende}}), do: ende
  defp ende(anderes), do: anderes

  defp beilegen(dir, beilagen) do
    for {quelle, ziel} <- beilagen,
        File.exists?(quelle),
        do: File.cp!(quelle, Path.join(dir, ziel))
  end

  defp fertig(ende, durchgaenge) do
    %{ende: ende, durchgaenge: Enum.map(durchgaenge, &Map.delete(&1, :ergebnis))}
  end

  defp schreiben(nach, ergebnis) do
    json = %{
      "ende" => inspect(ergebnis.ende),
      "durchgaenge" =>
        Enum.map(ergebnis.durchgaenge, fn d ->
          %{
            "nr" => d.nr,
            "verzeichnis" => d.dir,
            "durchgang" => d.durchgang,
            "vorher" => d.vorher,
            "bestand" => d.bestand,
            "neu" => d.neu,
            "ende" => inspect(d.ende)
          }
        end)
    }

    File.write!(Path.join(nach, "messlauf.json"), Jason.encode_to_iodata!(json, pretty: true))
  end

  defp melden(opts, ereignis), do: if(f = opts[:melden], do: f.(ereignis))
end
