defmodule Worker.Jack.Resuemee.Stand do
  @moduledoc """
  Der Stand des Resümee-Jack (J5, #1209): was er zu lesen hat, was er gelesen
  hat, was er notiert hat. Reine Daten wie `Worker.Jack.Stand`; jedes
  Werkzeug nimmt einen Stand und liefert einen neuen.

  Drei Läufe sind geplant — **Überblick** (B1, gebaut), **Schreiben** (B2)
  und **Durchsicht** (B3). `lauf` sagt, welcher gerade läuft; `entwurf` und
  `durchsicht` sind für B2/B3 angelegt und bleiben im Überblick leer.

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
    * `vorige_gedanken` — `[%{nummer:, name:, fakten_jack:, resuemee_jack:}]`;
      `fakten_jack` ist das Gedächtnis des Fakten-Jack jener Sitzung (Register
      aus `JackStandAbgelegt`), `resuemee_jack` die Notizen des Resümee-Jack
      (`ablage/1`). Beides darf `nil` sein: die Notizen des Resümee-Jack legt
      erst B4 ab.
    * `ueberschrift` — die Überschrift der Resümee-Spalte aus „Stil setzen“;
      aus ihr leitet Jack die FORM ab.
    * `flavor` — `%{base:, summary:}` für den Ton; gebraucht ab B2.
    * `mitschnitt` — ein `Worker.Jack.Stand` mit der Kontextliste der
      Sitzung, damit `Worker.Jack.Lesen` (bloecke, block, suche, cast,
      straenge) unverändert darauf arbeitet — dieselbe Nummerierung wie beim
      Fakten-Jack, auf die die Fakten mit ihren Blöcken zeigen.
    * `gelesen` — die IDs der Fakten **dieser** Sitzung, die Jack gesehen hat.
      Daran prüft `fertig`, ob er alle vor sich hatte.
    * `notizen` — je `t:notiz/0`, in Eintragsreihenfolge; die Reihenfolge der
      GLIEDERUNG ist die, in der Jack die Punkte anlegt.
    * `unveraendert` — je `"ABSCHNITT/schluessel"`, wie oft `notiz` einen
      Eintrag unverändert schreiben wollte.
    * `abschluss_zahlversuche` — Aufrufe von `fertig` mit falschen Zahlen.
    * `journal` — was die Werkzeuge für die Auswertung festhalten, als
      `{datei, eintrag}`; Jack sieht es nicht.
  """

  alias Worker.Jack.Stand, as: Mitschnitt

  @abschnitte ~w(FORM GLIEDERUNG OFFEN)
  @keine_frueheren "Es gibt keine früheren Sitzungen — mit dieser Sitzung beginnt die Aufzeichnung."

  defstruct lauf: :ueberblick,
            sitzung: %{id: nil, nummer: nil, name: nil},
            fakten: [],
            fruehere: [],
            boegen: [],
            vorige_resuemees: [],
            vorige_gedanken: [],
            ueberschrift: "Resümee",
            flavor: %{base: nil, summary: nil},
            mitschnitt: nil,
            gelesen: MapSet.new(),
            notizen: [],
            unveraendert: %{},
            entwurf: [],
            durchsicht: nil,
            abschluss_zahlversuche: 0,
            journal: []

  @type fakt :: %{
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
  @type t :: %__MODULE__{}

  @doc """
  Neuer Stand aus der Eingabe (`Worker.Jack.Resuemee.Eingabe`): `sitzung`,
  `fakten`, `fruehere`, `boegen`, `vorige_resuemees`, `vorige_gedanken`,
  `bloecke` (die Kontextliste in der Form von `Worker.Jack.Pipeline.eingabe/4`),
  `cast`, `straenge`, `ueberschrift`, `flavor`. Fehlende Listen gelten als
  leer, eine fehlende Überschrift als „Resümee“.
  """
  @spec neu(map()) :: t()
  def neu(eingabe) do
    %__MODULE__{
      sitzung: Map.fetch!(eingabe, :sitzung),
      fakten: Map.get(eingabe, :fakten, []),
      fruehere: Map.get(eingabe, :fruehere, []),
      boegen: Map.get(eingabe, :boegen, []),
      vorige_resuemees: Map.get(eingabe, :vorige_resuemees, []),
      vorige_gedanken: Map.get(eingabe, :vorige_gedanken, []),
      ueberschrift: Map.get(eingabe, :ueberschrift) || "Resümee",
      flavor: Map.get(eingabe, :flavor) || %{base: nil, summary: nil},
      mitschnitt:
        Mitschnitt.neu(
          bloecke: Map.get(eingabe, :bloecke, []),
          cast: Map.get(eingabe, :cast, []),
          straenge: Map.get(eingabe, :straenge, [])
        )
    }
  end

  @doc "Die drei Abschnitte der Notizen im Überblick."
  @spec abschnitte() :: [String.t()]
  def abschnitte, do: @abschnitte

  @doc """
  Der Hinweis, wenn es keine früheren Sitzungen gibt — neutral und wörtlich
  so vom Maintainer vorgegeben (12.09.2026).
  """
  @spec keine_frueheren() :: String.t()
  def keine_frueheren, do: @keine_frueheren

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

  @doc """
  Die berührten Bögen der Art `arc`, die kein GLIEDERUNG-Eintrag nennt — was
  `fertig` im Überblick verlangt. `context` und `rauschen` sind frei.
  """
  @spec arc_ohne_gliederung(t()) :: [String.t()]
  def arc_ohne_gliederung(%__MODULE__{} = s) do
    genannt =
      s
      |> abschnitt("GLIEDERUNG")
      |> Enum.flat_map(& &1.boegen)
      |> MapSet.new(&Worker.ThreadOverride.normalize/1)

    for b <- s.boegen,
        b.art == "arc",
        not MapSet.member?(genannt, Worker.ThreadOverride.normalize(b.titel)),
        do: b.titel
  end

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
  Sitzung, Lesestand, Notizen, offene Arbeit.
  """
  @spec abbild(t()) :: map()
  def abbild(%__MODULE__{} = s) do
    %{
      "lauf" => to_string(s.lauf),
      "sitzung" => s.sitzung.nummer,
      "ueberschrift" => s.ueberschrift,
      "fakten" => length(s.fakten),
      "gelesen" => MapSet.size(s.gelesen),
      "ungelesen" => ungelesen(s),
      "form" => with(%{zeile: z} <- form(s), do: z),
      "gliederung" => length(abschnitt(s, "GLIEDERUNG")),
      "arc_ohne_gliederung" => arc_ohne_gliederung(s),
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
