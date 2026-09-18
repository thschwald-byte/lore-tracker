defmodule Worker.Jack.Resuemee.Stand do
  @moduledoc """
  Der Stand des Resümee-Jack (J5, #1209): was er zu lesen hat, was er gelesen
  hat, was er notiert hat. Reine Daten wie `Worker.Jack.Stand`; jedes
  Werkzeug nimmt einen Stand und liefert einen neuen.

  Drei Läufe — **Überblick** (B1), **Schreiben** (B2) und **Durchsicht**
  (B3). `lauf` sagt, welcher gerade läuft; `entwurf` bleibt im Überblick
  leer, `durchsicht` ist nur in der Durchsicht gesetzt. Den Stand des
  Schreibens baut `fuer_schreiben/2`: frisch aus der Eingabe, dazu nur die
  Notizen des Überblicks; den der Durchsicht `fuer_durchsicht/3`: dazu der
  Entwurf aus dem Schreiben.

    * `sitzung` — `%{id:, nummer:, name:}` der Sitzung, deren Resümee
      entsteht.
    * `fakten` — die Fakten dieser Sitzung in der Reihenfolge des
      gespeicherten Bestands, je `t:fakt/0` (`Worker.Jack.Resuemee.Eingabe.fakten/4`).
      Jack adressiert sie über eine kurze ID (`"S4-F12"`: Sitzung 4, Fakt 12),
      nicht über die inhaltsbasierte Fakt-ID der Pipeline (`fakt_id`) — die
      ist ein Hash, und ein Hash wird beim Abschreiben leicht verfälscht.
    * `fruehere` — die Sitzungen mit kleinerer Nummer, aufsteigend, je
      `%{nummer:, name:, fakten: [fakt]}`. „Vorherig“ heißt kleinere
      Sessionnummer, nicht zuletzt erzeugt (Maintainer, 12.09.2026).
    * `boegen` — die Bögen, die Fakten dieser Sitzung berühren
      (`Worker.Jack.Resuemee.Eingabe.boegen/2`).
    * `vorige_resuemees` — `[%{nummer:, name:, text:}]`.
    * `vorige_gedanken` — `[%{nummer:, name:, fakten_jack:, resuemee_jack:,
      epos_jack:}]`; `fakten_jack` ist das Gedächtnis des Fakten-Jack jener
      Sitzung (Register aus `JackStandAbgelegt`), `resuemee_jack` die Notizen
      des Resümee-Jack (`ablage/1`, abgelegt als `JackResuemeeStandAbgelegt`),
      `epos_jack` die des Epos-Jack (`JackEposStandAbgelegt`, J6 #1210). Alle
      drei dürfen `nil` sein — für eine Sitzung, die (noch) keiner bearbeitet
      hat; `epos_jack` darf fehlen.
    * `ueberschrift` — die Überschrift der Resümee-Spalte aus „Stil setzen“;
      aus ihr leitet Jack die FORM ab.
    * `flavor` — `%{base:, summary:}` für den Ton; gebraucht ab B2.
    * `max_woerter` — das **Ziel** in Wörtern (Länge aus „Stil setzen“,
      sonst der Standard, `Shared.ResuemeeLaenge`). Die harte Obergrenze ist
      das Doppelte (`obergrenze/1`); dazwischen verlangt `fertig` eine
      Begründung (`Worker.Jack.Resuemee.Laenge`). Daraus folgt auch der Deckel
      der GLIEDERUNG (`max_gliederung/1`).
    * `laenge_begruendung` — warum das Resümee über dem Ziel liegt, wie
      `fertig` im Schreiben sie angenommen hat; `nil`, solange keine gegeben
      ist.
    * `mitschnitt` — ein `Worker.Jack.Stand` mit der Kontextliste der
      Sitzung, damit `Worker.Jack.Lesen` (bloecke, block, cast, straenge)
      unverändert darauf arbeitet — dieselbe Nummerierung wie beim
      Fakten-Jack, auf die die Fakten mit ihren Blöcken zeigen.

  **Derselbe Stand trägt den Epos-Jack** (E1, #1210, `Worker.Jack.Epos`):
  die Lesebasis, die Werkzeuge zum Lesen und der Halter sind dieselben; was
  sich unterscheidet, sagt `art`.

    * `art` — `:resuemee` (Standard) oder `:epos`. Gemeinsame Module, die dem
      Modell etwas über „das Resümee“ sagen (`Worker.Jack.Resuemee.Lesen`,
      `.Mitschnitte`, `.Suche`), richten ihre Texte danach; für den
      Resümee-Jack bleibt alles, wie es war.
    * `resuemee_weg` — nur beim Epos-Jack: der Weg aus dem Resümee dieser
      Sitzung, die Stationen der GLIEDERUNG aus dem abgelegten Stand des
      Resümee-Jack, je `%{schluessel:, zeile:, fakten: [kurze IDs], boegen:}`
      (`Worker.Jack.Epos.Eingabe`). Leer, wenn keiner vorliegt.
    * `flavor` trägt beim Epos-Jack `%{base:, epos:}` statt `%{base:, summary:}`
      (`ton/2`).
    * `entwurf` trägt beim Epos-Jack (E2) Absätze freier Prosa,
      `%{titel:, text:, szene:}` (`Worker.Jack.Epos.Entwurf`), statt Absätzen
      aus geprüften Sätzen — die Funktionen zu Sätzen und Wörtern hier
      (`saetze/1`, `woerter/1`, `entwurf_zahlen/1`, …) gelten nur für den
      Resümee-Jack. Dasselbe gilt in seiner Durchsicht (E3,
      `Worker.Jack.Epos.Durchsicht`); `durchsicht` hat dort dieselbe Form.

  Die gemeinsame Lesebasis (E0, #1210) — alles bis einschließlich dieser
  Sitzung, für `suche_bisher`, `boegen_kampagne`, `vorige_kapitel` und den
  Mitschnitt früherer Sitzungen:

    * `kapitel` — die Epos-Kapitel bis einschließlich dieser Sitzung,
      `[%{nummer:, name:, text:}]`; das dieser Sitzung ist die bisherige
      Fassung (falls es sie gibt).
    * `chronik` — die Chronik-Einträge bis einschließlich dieser Sitzung in
      der Reihenfolge der Kampagne, `[%{nummer:, datum:, label:, text:}]`
      (`nummer` `nil` für einen Eintrag ohne bekannte Sitzung).
    * `boegen_kampagne` — die Bögen, die ein Fakt bis einschließlich dieser
      Sitzung berührt, mit allen diesen Fakten (Form wie `boegen`); `nil`
      heißt: aus den Fakten ableiten, ohne Leitfrage und Status
      (`Worker.Jack.Resuemee.Bisher.alle_boegen/1`).
    * `resuemee_diese` — die bisherige Fassung des Resümees dieser Sitzung
      oder `nil`.
    * `register_diese` — das Gedächtnis des Fakten-Jack zu dieser Sitzung
      (Register aus `JackStandAbgelegt`) oder `nil`.
    * `lader` — `fn nummer -> {:ok, bloecke} | {:error, grund} end`: lädt die
      Kontextliste einer früheren Sitzung (`Eingabe.aus_repo/1` setzt ihn aus
      dem Repo, Tests geben einen Fake); `nil` heißt: kein Mitschnitt
      früherer Sitzungen.
    * `mitschnitte` — die schon geladenen früheren Mitschnitte je
      Sitzungsnummer, `{:ok, Worker.Jack.Stand}` oder `{:error, grund}`
      (`Worker.Jack.Resuemee.Mitschnitte`). Ein frischer Lauf beginnt leer.
    * `suche` — je `{werkzeug, begriff}` die Position des Blätterns, je Quelle
      wie viele Treffer schon gezeigt sind (`Worker.Jack.Resuemee.Suche`).
      Steht nicht im Abbild und nicht in der Zusammenfassung.
    * `gelesen` — die IDs der Fakten **dieser** Sitzung, die Jack gesehen hat.
      Daran prüft `fertig`, ob er alle vor sich hatte.
    * `notizen` — je `t:notiz/0`, in Eintragsreihenfolge; die Reihenfolge der
      GLIEDERUNG ist die, in der Jack die Punkte anlegt.
    * `unveraendert` — je `"ABSCHNITT/schluessel"`, wie oft `notiz` einen
      Eintrag unverändert schreiben wollte.
    * `entwurf` — das Resümee im Entstehen (B2), eine Liste von
      `t:absatz/0` in Lesereihenfolge. Die Absatznummer ist die Position
      ab 1; streicht Jack einen Absatz, rücken die dahinter auf.
    * `durchsicht` — nur in der Durchsicht (B3):
      `%{durchgang:, absaetze: [%{status:, gesehen:}], ausgang: [absatz]}`;
      `absaetze` läuft parallel zum Entwurf, `ausgang` ist der Entwurf aus
      dem Schreiben. Die Regeln stehen in `Worker.Jack.Resuemee.Durchsicht`.
    * `abschluss_zahlversuche` — Aufrufe von `fertig` mit falschen Zahlen.
    * `journal` — was die Werkzeuge für die Auswertung festhalten, als
      `{datei, eintrag}`; Jack sieht es nicht.
  """

  alias Worker.Jack.Stand, as: Mitschnitt

  @abschnitte ~w(FORM GLIEDERUNG OFFEN)
  @abschnitte_epos ~w(FORM SZENEN ABWEICHUNG OFFEN)
  @abschnitte_chronik ~w(PHASEN SCHLUESSELSZENEN OFFEN)
  @keine_frueheren "Es gibt keine früheren Sitzungen — mit dieser Sitzung beginnt die Aufzeichnung."
  @kein_ton "Für diese Kampagne ist kein Ton vorgegeben."
  @standard_woerter Shared.ResuemeeLaenge.standard()
  # Wörter je Gliederungspunkt, gerechnet auf die Obergrenze (das Doppelte des
  # Ziels): beim Standard 150 zwölf Stationen, bei 75 sechs (Maintainer,
  # 13.09.2026). Gegriffen, nicht gemessen.
  @woerter_je_punkt 25
  @mindestens_punkte 3

  defstruct art: :resuemee,
            lauf: :ueberblick,
            sitzung: %{id: nil, nummer: nil, name: nil},
            fakten: [],
            fruehere: [],
            boegen: [],
            vorige_resuemees: [],
            vorige_gedanken: [],
            ueberschrift: "Resümee",
            flavor: %{base: nil, summary: nil},
            max_woerter: @standard_woerter,
            laenge_begruendung: nil,
            resuemee_weg: [],
            mitschnitt: nil,
            kapitel: [],
            chronik: [],
            boegen_kampagne: nil,
            resuemee_diese: nil,
            register_diese: nil,
            lader: nil,
            mitschnitte: %{},
            suche: %{},
            gelesen: MapSet.new(),
            notizen: [],
            unveraendert: %{},
            entwurf: [],
            # Issue #1211 (J7): die Chronik-Einträge, die der Chronik-Jack in
            # diesem Lauf baut. `chronik` daneben bleibt die Lesebasis — der
            # BESTAND, den er vorfindet; `eintraege` ist sein Ergebnis.
            eintraege: [],
            durchsicht: nil,
            abschluss_zahlversuche: 0,
            journal: []

  @type fakt :: %{
          optional(:refs) => [String.t()],
          id: String.t(),
          fakt_id: String.t() | nil,
          sitzung: pos_integer(),
          aussage: String.t(),
          figur: String.t() | nil,
          typ: String.t(),
          boegen: [%{titel: String.t(), art: String.t()}],
          datum: String.t() | nil,
          erzaehlzeit: String.t(),
          bloecke: [non_neg_integer()],
          ohne_block: non_neg_integer()
        }
  @type notiz :: %{
          abschnitt: String.t(),
          schluessel: String.t(),
          zeile: String.t(),
          fakten: [String.t()],
          boegen: [String.t()]
        }
  @typedoc """
  Ein Satz des Entwurfs: der Text (Leerraum zusammengezogen), die kurzen
  IDs der Fakten in der Schreibweise des Bestands, und die zwei
  Markierungen — `uebergang` (ohne Fakten) und `rueckblick` (nur Fakten
  früherer Sitzungen). Welche Kombination gilt, prüft
  `Worker.Jack.Resuemee.Entwurf.satz_pruefen/2`.
  """
  @type satz :: %{
          text: String.t(),
          fakten: [String.t()],
          uebergang: boolean(),
          rueckblick: boolean()
        }
  @typedoc "Ein Absatz des Entwurfs; ohne Titel ist er Fließtext."
  @type absatz :: %{titel: String.t() | nil, saetze: [satz()]}
  @type t :: %__MODULE__{}

  @doc """
  Neuer Stand aus der Eingabe (`Worker.Jack.Resuemee.Eingabe`): `sitzung`,
  `fakten`, `fruehere`, `boegen`, `vorige_resuemees`, `vorige_gedanken`,
  `bloecke` (die Kontextliste in der Form von `Worker.Jack.Pipeline.eingabe/4`),
  `cast`, `straenge`, `ueberschrift`, `flavor`, `max_woerter`, dazu die
  Lesebasis (E0, #1210) `kapitel`, `chronik`, `boegen_kampagne`,
  `resuemee_diese`, `register_diese` und der Lader `mitschnitt_laden`, beim
  Epos-Jack (E1, #1210) dazu `art` und `resuemee_weg`.
  Fehlende Listen gelten als leer, eine fehlende Überschrift als „Resümee“,
  eine fehlende oder ungültige Länge als der Standard
  (`Shared.ResuemeeLaenge.wirksam/1`), ein fehlender Lader als „kein
  Mitschnitt früherer Sitzungen“, eine fehlende Art als `:resuemee`.
  """
  @spec neu(map()) :: t()
  def neu(eingabe) do
    %__MODULE__{
      art: Map.get(eingabe, :art, :resuemee),
      resuemee_weg: Map.get(eingabe, :resuemee_weg, []),
      kapitel: Map.get(eingabe, :kapitel, []),
      chronik: Map.get(eingabe, :chronik, []),
      boegen_kampagne: Map.get(eingabe, :boegen_kampagne),
      resuemee_diese: Map.get(eingabe, :resuemee_diese),
      register_diese: Map.get(eingabe, :register_diese),
      lader: Map.get(eingabe, :mitschnitt_laden),
      sitzung: Map.fetch!(eingabe, :sitzung),
      fakten: Map.get(eingabe, :fakten, []),
      fruehere: Map.get(eingabe, :fruehere, []),
      boegen: Map.get(eingabe, :boegen, []),
      vorige_resuemees: Map.get(eingabe, :vorige_resuemees, []),
      vorige_gedanken: Map.get(eingabe, :vorige_gedanken, []),
      ueberschrift: Map.get(eingabe, :ueberschrift) || "Resümee",
      flavor: Map.get(eingabe, :flavor) || %{base: nil, summary: nil},
      max_woerter: Shared.ResuemeeLaenge.wirksam(Map.get(eingabe, :max_woerter)),
      mitschnitt:
        Mitschnitt.neu(
          bloecke: Map.get(eingabe, :bloecke, []),
          cast: Map.get(eingabe, :cast, []),
          straenge: Map.get(eingabe, :straenge, [])
        )
    }
  end

  @doc """
  Der Stand des zweiten Laufs, des Schreibens (B2): frisch aus der Eingabe
  wie `neu/1`, `lauf: :schreiben`, dazu die Notizen des Überblicks aus
  seiner Ablage (`ablage/1`, String- oder Atom-Schlüssel) — sonst nichts.
  Jack beginnt ohne Erinnerung an das Lesen (Maintainer): nichts gilt als
  gelesen, der Entwurf ist leer. `nil` als Ablage heißt: keine Notizen.
  """
  @spec fuer_schreiben(map(), map() | nil) :: t()
  def fuer_schreiben(eingabe, ablage),
    do: %{neu(eingabe) | lauf: :schreiben, notizen: aus_ablage(ablage)}

  defp aus_ablage(ablage) do
    for r <- notizliste(ablage), is_map(r) do
      %{
        abschnitt: to_string(wert(r, :abschnitt)),
        schluessel: to_string(wert(r, :schluessel)),
        zeile: wert(r, :zeile),
        fakten: List.wrap(wert(r, :fakten)),
        boegen: List.wrap(wert(r, :boegen))
      }
    end
  end

  @doc """
  Der Stand des dritten Laufs, der Durchsicht (B3): frisch aus der Eingabe
  wie `fuer_schreiben/2` mit den Notizen des Überblicks, `lauf: :durchsicht`,
  dazu der Entwurf aus dem Schreiben (`entwurf_aus/1`) und die Durchsicht im
  ersten Durchgang, jeder Absatz offen.
  """
  @spec fuer_durchsicht(map(), map() | nil, [map()]) :: t()
  def fuer_durchsicht(eingabe, ablage, entwurf),
    do: eingabe |> fuer_schreiben(ablage) |> mit_durchsicht(entwurf_aus(entwurf))

  @doc """
  Setzt einen Stand in die Durchsicht: `lauf: :durchsicht`, `absaetze` als
  Entwurf und die Durchsicht im ersten Durchgang, jeder Absatz offen. Für den
  Resümee-Jack (`fuer_durchsicht/3`) wie für den Epos-Jack
  (`Worker.Jack.Epos.Durchsicht.stand/3`, #1210), dessen Absätze freie Prosa
  sind — die Buchhaltung kennt nur ihre Zahl.
  """
  @spec mit_durchsicht(t(), [map()]) :: t()
  def mit_durchsicht(%__MODULE__{} = s, absaetze) do
    %{
      s
      | lauf: :durchsicht,
        entwurf: absaetze,
        durchsicht: %{
          durchgang: 1,
          absaetze: Enum.map(absaetze, fn _ -> %{status: :offen, gesehen: false} end),
          ausgang: absaetze
        }
    }
  end

  @doc """
  Ein Entwurf als Liste von `t:absatz/0` — aus dem Stand des Schreibens
  (Atom-Schlüssel) oder als JSON (String-Schlüssel, wie B4 ihn ablegen
  wird). Fehlende Markierungen gelten als `false`, fehlende Fakten als leer.
  """
  @spec entwurf_aus([map()] | nil) :: [absatz()]
  def entwurf_aus(entwurf) do
    for a <- List.wrap(entwurf), is_map(a) do
      %{
        titel: wert(a, :titel),
        saetze:
          for s <- List.wrap(wert(a, :saetze)), is_map(s) do
            %{
              text: wert(s, :text) || "",
              fakten: List.wrap(wert(s, :fakten)),
              uebergang: wert(s, :uebergang) == true,
              rueckblick: wert(s, :rueckblick) == true
            }
          end
      }
    end
  end

  defp notizliste(%{"notizen" => n}) when is_list(n), do: n
  defp notizliste(%{notizen: n}) when is_list(n), do: n
  defp notizliste(_keine), do: []

  defp wert(r, k), do: Map.get(r, k, Map.get(r, Atom.to_string(k)))

  @doc """
  Die Abschnitte der Notizen im Überblick: beim Resümee-Jack FORM,
  GLIEDERUNG, OFFEN; beim Epos-Jack (`:epos`, #1210) FORM, SZENEN,
  ABWEICHUNG, OFFEN; beim Chronik-Jack (`:chronik`, #1211) PHASEN,
  SCHLUESSELSZENEN, OFFEN — dort ist der Abschnitt zugleich die
  Wichtigkeit des Eintrags, den das Schreiben daraus anlegt.

  **Jede Art hat ihre eigene Klausel, es gibt keinen Auffangzweig.** Der gab
  es bis #1211, und er hat den Chronik-Jack gekostet: `abschnitte(:chronik)`
  fiel still auf die Resümee-Abschnitte zurück, `notiz` erzwang damit
  FORM/GLIEDERUNG/OFFEN, und der Überblick konnte nie abschließen — ohne
  Fehler, ohne Warnung. Eine unbekannte Art wirft jetzt.
  """
  @spec abschnitte(:resuemee | :epos | :chronik) :: [String.t()]
  def abschnitte(art \\ :resuemee)
  def abschnitte(:resuemee), do: @abschnitte
  def abschnitte(:epos), do: @abschnitte_epos
  def abschnitte(:chronik), do: @abschnitte_chronik

  @doc """
  Der Hinweis, wenn es keine früheren Sitzungen gibt — neutral und wörtlich
  so vom Maintainer vorgegeben (12.09.2026).
  """
  @spec keine_frueheren() :: String.t()
  def keine_frueheren, do: @keine_frueheren

  @doc """
  Der Ton für das Schreiben (B2) aus `flavor` (`%{base:, summary:}`, wie
  `Worker.Jack.Resuemee.Eingabe.flavor/1`): Grundton der Kampagne und Ton
  des Resümees, je als eigener Absatz. Ist beides leer, ein neutraler Satz,
  dass kein Ton vorgegeben ist. Beim Epos-Jack (`art` `:epos`, #1210) aus
  `%{base:, epos:}` (`Worker.Jack.Epos.Eingabe.flavor/1`): Grundton und Ton
  des Epos.
  """
  @spec ton(map() | nil, :resuemee | :epos) :: String.t()
  def ton(flavor, art \\ :resuemee) do
    flavor = flavor || %{}

    teile =
      for {name, k} <- ton_teile(art),
          v = Map.get(flavor, k),
          is_binary(v) and String.trim(v) != "",
          do: "**#{name}:** #{String.trim(v)}"

    if teile == [], do: @kein_ton, else: Enum.join(teile, "\n\n")
  end

  defp ton_teile(:epos), do: [{"Grundton der Kampagne", :base}, {"Ton des Epos", :epos}]
  defp ton_teile(_art), do: [{"Grundton der Kampagne", :base}, {"Ton des Resümees", :summary}]

  @doc "Die Nummern der früheren Sitzungen, aufsteigend."
  @spec fruehere_nummern(t()) :: [pos_integer()]
  def fruehere_nummern(%__MODULE__{fruehere: f}), do: Enum.map(f, & &1.nummer)

  @doc """
  Ein Fakt dieser oder einer früheren Sitzung über seine kurze ID;
  Groß-/Kleinschreibung und Leerraum egal.
  """
  @spec fakt(t(), String.t()) :: fakt() | nil
  def fakt(%__MODULE__{} = s, id) when is_binary(id) do
    k = kanonisch(id)
    Enum.find(alle_fakten(s), &(kanonisch(&1.id) == k))
  end

  def fakt(_s, _id), do: nil

  @doc "Ob ein Fakt zu dieser Sitzung gehört."
  @spec diese_sitzung?(t(), fakt()) :: boolean()
  def diese_sitzung?(%__MODULE__{sitzung: %{nummer: n}}, %{sitzung: n}), do: true
  def diese_sitzung?(_s, _f), do: false

  defp alle_fakten(s), do: s.fakten ++ Enum.flat_map(s.fruehere, & &1.fakten)

  defp kanonisch(id), do: id |> String.trim() |> String.upcase()

  @doc """
  Der Titel eines bekannten Bogens oder Strangs, wie er geschrieben steht —
  `nil`, wenn es ihn weder unter den Bögen dieser Sitzung noch unter den
  Strängen der Kampagne gibt. Handlungsbögen erfindet Jack nicht neu.
  """
  @spec bogen(t(), String.t()) :: String.t() | nil
  def bogen(%__MODULE__{} = s, titel) when is_binary(titel) do
    k = Worker.ThreadOverride.normalize(titel)

    (Enum.map(s.boegen, & &1.titel) ++ s.mitschnitt.straenge)
    |> Enum.find(&(Worker.ThreadOverride.normalize(&1) == k))
  end

  def bogen(_s, _titel), do: nil

  @doc "Einen Fakt dieser Sitzung als gelesen merken; andere bleiben unberührt."
  @spec gelesen_merken(t(), [fakt()]) :: t()
  def gelesen_merken(%__MODULE__{} = s, fakten) do
    ids = for f <- fakten, diese_sitzung?(s, f), do: f.id
    %{s | gelesen: Enum.into(ids, s.gelesen)}
  end

  @doc """
  Die Positionen (ab 1) der Fakten dieser Sitzung, die noch nicht gelesen
  sind, als Bereiche `"von-bis"` bzw. `"n"`.
  """
  @spec ungelesen(t()) :: [String.t()]
  def ungelesen(%__MODULE__{} = s) do
    s.fakten
    |> Enum.with_index(1)
    |> Enum.reject(fn {f, _} -> MapSet.member?(s.gelesen, f.id) end)
    |> Enum.map(&elem(&1, 1))
    |> bereiche()
  end

  defp bereiche(nummern) do
    nummern
    |> Enum.chunk_while(
      [],
      fn
        n, [] -> {:cont, [n]}
        n, [letzte | _] = acc when n == letzte + 1 -> {:cont, [n | acc]}
        n, acc -> {:cont, Enum.reverse(acc), [n]}
      end,
      fn
        [] -> {:cont, []}
        acc -> {:cont, Enum.reverse(acc), []}
      end
    )
    |> Enum.map(fn
      [n] -> "#{n}"
      [v | rest] -> "#{v}-#{List.last(rest)}"
    end)
  end

  @doc "Die Einträge eines Abschnitts, die Inhalt haben."
  @spec abschnitt(t(), String.t()) :: [notiz()]
  def abschnitt(%__MODULE__{notizen: n}, name),
    do: Enum.filter(n, &(&1.abschnitt == name and String.trim(&1.zeile || "") != ""))

  @doc "Der FORM-Eintrag oder `nil`."
  @spec form(t()) :: notiz() | nil
  def form(%__MODULE__{} = s), do: s |> abschnitt("FORM") |> List.first()

  @doc "Die IDs der Fakten dieser Sitzung, die ein GLIEDERUNG-Eintrag nennt."
  @spec abgedeckt(t()) :: MapSet.t()
  def abgedeckt(%__MODULE__{} = s) do
    eigene = MapSet.new(s.fakten, & &1.id)

    s
    |> abschnitt("GLIEDERUNG")
    |> Enum.flat_map(& &1.fakten)
    |> MapSet.new()
    |> MapSet.intersection(eigene)
  end

  # ─── Länge (#1209) ────────────────────────────────────────────────────

  @doc """
  Wie viele Punkte die GLIEDERUNG höchstens hat: `max(3, round(2 * max_woerter
  / 25))` — beim Standard 150 zwölf, bei 75 sechs. Die Gliederung ist der Weg
  der Gruppe durch die Sitzung, Station für Station; mehr Stationen trägt ein
  Resümee bis zur Obergrenze (`obergrenze/1`) nicht. Die 25 Wörter je Station
  sind gegriffen, nicht gemessen. Nimmt einen Stand oder die Wortzahl.
  """
  @spec max_gliederung(t() | pos_integer()) :: pos_integer()
  def max_gliederung(%__MODULE__{max_woerter: m}), do: max_gliederung(m)

  def max_gliederung(m) when is_integer(m),
    do: max(@mindestens_punkte, round(Shared.ResuemeeLaenge.hoechstens(m) / @woerter_je_punkt))

  @doc """
  Wie viele Wörter das Resümee höchstens hat: das Doppelte des Ziels
  (`Shared.ResuemeeLaenge.hoechstens/1`). Nimmt einen Stand oder das Ziel.
  """
  @spec obergrenze(t() | pos_integer()) :: pos_integer()
  def obergrenze(%__MODULE__{max_woerter: m}), do: obergrenze(m)
  def obergrenze(m), do: Shared.ResuemeeLaenge.hoechstens(m)

  @doc """
  Die Wörter des Entwurfs, wie die Grenze sie zählt: alle Satztexte und alle
  Absatztitel. Gezählt wird, was durch Leerraum getrennt ist — ein
  Gedankenstrich zwischen Leerzeichen zählt mit; benannte Grenze, großzügig
  gegen Jack.
  """
  @spec woerter(t()) :: non_neg_integer()
  def woerter(%__MODULE__{entwurf: e}), do: woerter_in(e)

  @doc "Die Wörter einer Liste von Absätzen (`t:absatz/0`), gezählt wie `woerter/1`."
  @spec woerter_in([absatz()]) :: non_neg_integer()
  def woerter_in(absaetze) do
    absaetze
    |> Enum.flat_map(fn a -> [a.titel || "" | Enum.map(a.saetze, & &1.text)] end)
    |> Enum.map(&(&1 |> String.split() |> length()))
    |> Enum.sum()
  end

  @doc "Der Wortstand in Worten: „X Wörter — Ziel M, höchstens 2M“."
  @spec woerter_text(t()) :: String.t()
  def woerter_text(%__MODULE__{} = s),
    do: "#{woerter(s)} Wörter — Ziel #{s.max_woerter}, höchstens #{obergrenze(s)}"

  @doc "Ob der Entwurf mehr Wörter hat als das Ziel."
  @spec ueber_ziel?(t()) :: boolean()
  def ueber_ziel?(%__MODULE__{} = s), do: woerter(s) > s.max_woerter

  @doc "Ob der Entwurf mehr Wörter hat, als das Resümee haben darf (die Obergrenze)."
  @spec ueber_obergrenze?(t()) :: boolean()
  def ueber_obergrenze?(%__MODULE__{} = s), do: woerter(s) > obergrenze(s)

  # ─── Entwurf (B2) ─────────────────────────────────────────────────────

  @doc "Alle Sätze des Entwurfs in Lesereihenfolge."
  @spec saetze(t()) :: [satz()]
  def saetze(%__MODULE__{entwurf: e}), do: Enum.flat_map(e, & &1.saetze)

  @doc "Absätze, Sätze, Übergänge, Rückblicke und Wörter (`woerter/1`) des Entwurfs."
  @spec entwurf_zahlen(t()) :: %{atom() => non_neg_integer()}
  def entwurf_zahlen(%__MODULE__{} = s) do
    saetze = saetze(s)

    %{
      absaetze: length(s.entwurf),
      saetze: length(saetze),
      uebergaenge: Enum.count(saetze, & &1.uebergang),
      rueckblicke: Enum.count(saetze, & &1.rueckblick),
      woerter: woerter(s)
    }
  end

  @doc "Die IDs der Fakten dieser Sitzung, die ein Satz des Entwurfs nennt."
  @spec im_text(t()) :: MapSet.t()
  def im_text(%__MODULE__{} = s) do
    s
    |> saetze()
    |> Enum.flat_map(& &1.fakten)
    |> MapSet.new()
    |> MapSet.intersection(MapSet.new(s.fakten, & &1.id))
  end

  @doc """
  Die berührten Bögen der Art `arc`, von denen kein Satz einen Fakt **dieser**
  Sitzung nennt — was `fertig` im Schreiben verlangt, sofern der Bogen nicht
  begründet ausgelassen ist. Ein Rückblick auf einen früheren Fakt desselben
  Bogens erzählt nicht, was der Bogen in dieser Sitzung tat, und zählt
  deshalb nicht.
  """
  @spec arc_ohne_satz(t()) :: [String.t()]
  def arc_ohne_satz(%__MODULE__{} = s) do
    zitiert = im_text(s)

    for b <- s.boegen,
        b.art == "arc",
        not Enum.any?(b.fakten, &MapSet.member?(zitiert, &1)),
        do: b.titel
  end

  @doc "Ein Bogen dieser Sitzung über seinen Titel (Schreibweise egal), sonst `nil`."
  @spec bogen_dieser_sitzung(t(), String.t()) :: map() | nil
  def bogen_dieser_sitzung(%__MODULE__{} = s, titel) when is_binary(titel) do
    k = Worker.ThreadOverride.normalize(titel)
    Enum.find(s.boegen, &(Worker.ThreadOverride.normalize(&1.titel) == k))
  end

  def bogen_dieser_sitzung(_s, _titel), do: nil

  @doc """
  Was von den Notizen für spätere Sitzungen aufgehoben wird (B4: als
  „vorige Gedanken“), JSON-fähig mit String-Schlüsseln — dieselbe Form, die
  `vorige_gedanken` als `resuemee_jack` annimmt.
  """
  @spec ablage(t()) :: map()
  def ablage(%__MODULE__{} = s) do
    %{
      "notizen" =>
        Enum.map(s.notizen, fn n ->
          %{
            "abschnitt" => n.abschnitt,
            "schluessel" => n.schluessel,
            "zeile" => n.zeile,
            "fakten" => n.fakten,
            "boegen" => n.boegen
          }
        end)
    }
  end

  @doc """
  Der Stand als JSON-fähige Map für einen Beobachter (Laufsicht): Lauf,
  Sitzung, Lesestand, Notizen, offene Arbeit, dazu die Länge (`max_woerter`
  = Ziel, `obergrenze`) und `max_gliederung`. Im Schreiben dazu `woerter`
  (der Wortstand, `woerter/1`), `entwurf` (Absätze, Sätze, Übergänge,
  Rückblicke, Wörter), `markdown` (der Entwurf als Text,
  `Worker.Jack.Resuemee.Ergebnis.markdown/1`), `arc_ohne_satz`,
  `gliederung_ohne_satz` (je `%{"schluessel", "zeile"}`,
  `Worker.Jack.Resuemee.Weg.ohne_satz/1`) und `laenge_begruendung`; in der
  Durchsicht dieselben ohne `arc_ohne_satz`, dazu `durchsicht`
  (`Worker.Jack.Resuemee.Durchsicht.abbild/1`: Durchgang, offene Absätze,
  Status je Absatz, Zähler, Hinweise).
  """
  @spec abbild(t()) :: map()
  def abbild(%__MODULE__{} = s), do: Map.merge(abbild_basis(s), abbild_entwurf(s))

  defp abbild_entwurf(%__MODULE__{lauf: :schreiben} = s),
    do: s |> abbild_text() |> Map.put("arc_ohne_satz", arc_ohne_satz(s))

  defp abbild_entwurf(%__MODULE__{lauf: :durchsicht} = s),
    do: s |> abbild_text() |> Map.put("durchsicht", Worker.Jack.Resuemee.Durchsicht.abbild(s))

  defp abbild_entwurf(_s), do: %{}

  defp abbild_text(s) do
    %{
      "entwurf" => Map.new(entwurf_zahlen(s), fn {k, v} -> {Atom.to_string(k), v} end),
      "woerter" => woerter(s),
      "markdown" => Worker.Jack.Resuemee.Ergebnis.markdown(s),
      "gliederung_ohne_satz" =>
        Worker.Jack.Resuemee.Weg.abbild(Worker.Jack.Resuemee.Weg.ohne_satz(s)),
      "laenge_begruendung" => s.laenge_begruendung
    }
  end

  defp abbild_basis(s) do
    %{
      "lauf" => to_string(s.lauf),
      "sitzung" => s.sitzung.nummer,
      "ueberschrift" => s.ueberschrift,
      "fakten" => length(s.fakten),
      "gelesen" => MapSet.size(s.gelesen),
      "ungelesen" => ungelesen(s),
      "form" => with(%{zeile: z} <- form(s), do: z),
      "gliederung" => length(abschnitt(s, "GLIEDERUNG")),
      "max_gliederung" => max_gliederung(s),
      "max_woerter" => s.max_woerter,
      "obergrenze" => obergrenze(s),
      "notizen" => ablage(s)["notizen"],
      "journal" => s |> journal_liste() |> Enum.frequencies_by(&elem(&1, 0))
    }
  end

  @doc "Einen Eintrag ins Journal schreiben."
  @spec journal(t(), String.t(), map()) :: t()
  def journal(%__MODULE__{} = s, datei, eintrag),
    do: %{s | journal: [{datei, eintrag} | s.journal]}

  @doc "Das Journal in Schreibreihenfolge."
  @spec journal_liste(t()) :: [{String.t(), map()}]
  def journal_liste(%__MODULE__{journal: j}), do: Enum.reverse(j)
end
