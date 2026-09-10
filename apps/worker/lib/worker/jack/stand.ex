defmodule Worker.Jack.Stand do
  @moduledoc """
  Der Stand eines Jack-Auftrags: was er liest, was er weiß, was er
  eingetragen hat. Reine Daten; jedes Werkzeug nimmt einen Stand und liefert
  einen neuen.

  Im Spike lag das in globalen Variablen und Dateien im Ausgabeabbild
  (`EINGETRAGEN`, `REGISTER`, `OFFENE_DUBLETTEN`, `aussagen.jsonl`, …). Hier
  ist es ein Struct, damit ein Lauf ohne Datei und ohne Prozess testbar ist.

    * `bloecke` — `%{nummer => %{text:, sprecher:, block_id:}}`. Jack sieht
      Nummern 0…n; die Block-ID ist die content-adressierte ID des geglätteten
      Snapshots, mit der Prod-Fakten ihre `source_refs` zitieren. Der Sprecher
      ist ein Figurenname, **nie** eine Discord-ID.
    * `eingetragen` — der Bestand, in Eintragsreihenfolge, je
      `%{nr:, woerter:, kurz:, voll:}`; `voll` ist der Datensatz mit
      String-Schlüsseln, wie er später in das Event geht.
    * `register` — das Gedächtnis, je `%{abschnitt:, schluessel:, zeile:, bloecke:}`.
    * `offene` / `ausgegeben` — die GUIDs des Verifikationstors
      (`Worker.Jack.Tor`).
    * `journal` — was der Spike nach `abgelehnt.jsonl` und `dubletten.jsonl`
      schrieb, als `{datei, eintrag}`; für die Auswertung, nicht für Jack.
    * `guid_quelle` — `fn n -> guid end`; im Betrieb zufällig, in Tests ein
      Zähler.
    * `phase`, `rolle` — 1 Lesen, 2 Sammeln, 3 Ordnen; in Phase 3 die Rolle
      `"a"` (ordnen), `"b"` (prüfen) oder `"c"` (nachbessern).
    * `gelesen` / `sammelnd` — die gelesenen Bereiche `{von, bis}` dieses
      Durchgangs; `sammelnd` sind die, die nach der ersten Aussage gelesen
      wurden. Daran prüft `fertig` die Lückenlosigkeit.
    * `beppo_pos`, `portion`, `weiter_leer` — der Beppo-Modus: nächste
      Blocknummer, Größe einer Portion, Aufrufe von `weiter` nach dem Ende.
      Welche Portionen geliefert wurden, steht im Journal (`beppo.jsonl`).
    * `unveraendert` — je `"ABSCHNITT/schluessel"`, wie oft `notiz` einen
      Eintrag unverändert schreiben wollte.
    * `abschluss_zahlversuche` — Aufrufe von `fertig` mit falschen Zahlen.
  """

  alias Worker.Jack.Beleg

  @abschnitte ~w(FIGUREN ABLAUF AUFTRAG THEMEN OFFEN)
  @alter_escape "(kein Cast-Treffer)"
  @deckel 5

  defstruct bloecke: %{},
            max_block: -1,
            cast: [],
            beppo: false,
            durchgang: 1,
            eingetragen: [],
            lfd: 0,
            offene: %{},
            ausgegeben: %{},
            geraten: 0,
            versuche: %{},
            kollisionen: %{},
            bestaetigt: %{},
            belegte_bloecke: MapSet.new(),
            hoechster_belegter_block: -1,
            themen: [],
            register: [],
            abgelehnt: 0,
            journal: [],
            guid_zaehler: 0,
            guid_quelle: nil,
            phase: 1,
            rolle: "a",
            straenge: [],
            gelesen: [],
            sammelnd: [],
            portion: 100,
            beppo_pos: 0,
            weiter_leer: 0,
            unveraendert: %{},
            abschluss_zahlversuche: 0

  @type block :: %{text: String.t(), sprecher: String.t(), block_id: String.t()}
  @type eintrag :: %{nr: pos_integer(), woerter: MapSet.t(), kurz: String.t(), voll: map()}
  @type notiz :: %{
          abschnitt: String.t(),
          schluessel: String.t(),
          zeile: String.t(),
          bloecke: [integer()]
        }
  @type t :: %__MODULE__{}

  @doc """
  Neuer Stand. Optionen: `:bloecke` (Liste in Mitschnittreihenfolge), `:cast`,
  `:straenge`, `:register`, `:beppo`, `:beppo_pos`, `:durchgang`, `:phase`
  (1, 2 oder 3), `:rolle` (`"a"`, `"b"`, `"c"`), `:portion`, `:guid_quelle`.

  Die Portion von `weiter` ist im Lesen 100 Blöcke, sonst 40, und nie unter
  5 — wie im Spike (`S1_PORTION`).
  """
  @spec neu(keyword()) :: t()
  def neu(opts) do
    bloecke =
      opts |> Keyword.get(:bloecke, []) |> Enum.with_index() |> Map.new(fn {b, i} -> {i, b} end)

    phase = Keyword.get(opts, :phase, 1)

    %__MODULE__{
      bloecke: bloecke,
      max_block: map_size(bloecke) - 1,
      cast: Keyword.get(opts, :cast, []),
      straenge: Keyword.get(opts, :straenge, []),
      register: Keyword.get(opts, :register, []),
      beppo: Keyword.get(opts, :beppo, false),
      beppo_pos: Keyword.get(opts, :beppo_pos, 0),
      durchgang: Keyword.get(opts, :durchgang, 1),
      phase: phase,
      rolle: Keyword.get(opts, :rolle, "a"),
      portion: max(5, Keyword.get(opts, :portion, if(phase == 1, do: 100, else: 40))),
      guid_quelle: Keyword.get(opts, :guid_quelle, &zufalls_guid/1)
    }
  end

  @doc "Die fünf Abschnitte, die das Gerüst des Gedächtnisses verlangt."
  @spec abschnitte() :: [String.t()]
  def abschnitte, do: @abschnitte

  @doc """
  Alle Abschnitte, die `notiz` annimmt: das Gerüst und `ABLEHNUNGEN`, in das
  Phase 3 schreibt, was die prüfende Rolle zurückgerollt hat. Ein eigener
  Abschnitt, nicht `OFFEN`: dort steht, was offen bleiben soll.
  """
  @spec abschnitte_alle() :: [String.t()]
  def abschnitte_alle, do: @abschnitte ++ ["ABLEHNUNGEN"]

  @doc """
  Die Lücken, die eine Menge von Bereichen `{von, bis}` in `0..max` lässt, als
  `"von-bis"`. Vertauschte Grenzen gelten als richtig herum.
  """
  @spec luecken([{integer(), integer()}], integer()) :: [String.t()]
  def luecken(bereiche, max) do
    {luecken, bis} =
      bereiche
      |> Enum.map(fn {v, b} -> {min(v, b), max(v, b)} end)
      |> Enum.sort()
      |> Enum.reduce({[], -1}, fn {v, b}, {acc, bis} ->
        acc = if v > bis + 1, do: ["#{bis + 1}-#{v - 1}" | acc], else: acc
        {acc, max(b, bis)}
      end)

    luecken = if bis < max, do: ["#{bis + 1}-#{max}" | luecken], else: luecken
    Enum.reverse(luecken)
  end

  @doc "Der alte Escape-Wert — nur noch zum Erkennen und Abweisen."
  @spec alter_escape() :: String.t()
  def alter_escape, do: @alter_escape

  @doc "Ab dem wievielten Fehlversuch mit derselben Aussage aufgegeben wird."
  @spec deckel() :: pos_integer()
  def deckel, do: @deckel

  @doc "Text und Sprecher eines Blocks."
  @spec block(t(), integer()) :: block() | nil
  def block(%__MODULE__{bloecke: b}, nr), do: Map.get(b, nr)

  @doc """
  Was dem Gerüst im Gedächtnis fehlt: je fehlendem Abschnitt `"## NAME"`, oder
  `"(zu duenn: …)"` bei weniger als zehn Einträgen mit Inhalt. Gezählt wird
  nur, was Inhalt hat.
  """
  @spec geruest_fehlt(t()) :: [String.t()]
  def geruest_fehlt(%__MODULE__{} = s) do
    voll = eintraege_mit_inhalt(s)

    fehlend =
      for a <- @abschnitte, not Enum.any?(voll, &(&1.abschnitt == a)), do: "## " <> a

    cond do
      fehlend != [] -> fehlend
      length(voll) < 10 -> ["(zu duenn: #{length(voll)} Eintraege mit Inhalt, mindestens 10)"]
      true -> []
    end
  end

  @doc "Die Einträge des Gedächtnisses, die Inhalt haben."
  @spec eintraege_mit_inhalt(t()) :: [notiz()]
  def eintraege_mit_inhalt(%__MODULE__{register: r}),
    do: Enum.filter(r, &(String.trim(&1.zeile || "") != ""))

  @doc "Der Datensatz einer Aussage im Bestand."
  @spec bestand_von(t(), integer()) :: map() | nil
  def bestand_von(%__MODULE__{eingetragen: e}, nr),
    do: Enum.find_value(e, fn x -> if x.nr == nr, do: x.voll end)

  @doc "Eine neue Aussage an den Bestand hängen."
  @spec eintragen(t(), map()) :: t()
  def eintragen(%__MODULE__{} = s, voll), do: %{s | eingetragen: s.eingetragen ++ [eintrag(voll)]}

  @doc "Den Datensatz einer Aussage ersetzen (oder anhängen, wenn es sie nicht gibt)."
  @spec ersetzen(t(), integer(), map()) :: t()
  def ersetzen(%__MODULE__{} = s, nr, voll) do
    if Enum.any?(s.eingetragen, &(&1.nr == nr)) do
      %{s | eingetragen: Enum.map(s.eingetragen, &if(&1.nr == nr, do: eintrag(voll), else: &1))}
    else
      eintragen(s, voll)
    end
  end

  defp eintrag(voll) do
    claim = Map.get(voll, "claim") || ""

    %{
      nr: voll["nummer"],
      woerter: Beleg.woerter(claim),
      kurz: String.slice(claim, 0, 60),
      voll: voll
    }
  end

  @doc "Eine neue GUID aus der Quelle des Stands."
  @spec guid(t()) :: {String.t(), t()}
  def guid(%__MODULE__{} = s) do
    n = s.guid_zaehler + 1
    {s.guid_quelle.(n), %{s | guid_zaehler: n}}
  end

  @doc "Eine zufällige GUID im Format 8-4-4-4-12, wie im Spike."
  @spec zufalls_guid(term()) :: String.t()
  def zufalls_guid(_n) do
    h = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)

    Enum.join(
      [
        String.slice(h, 0, 8),
        String.slice(h, 8, 4),
        String.slice(h, 12, 4),
        String.slice(h, 16, 4),
        String.slice(h, 20, 12)
      ],
      "-"
    )
  end

  @doc "Einen Eintrag ins Journal schreiben (`datei` wie im Spike, z.B. `\"dubletten.jsonl\"`)."
  @spec journal(t(), String.t(), map()) :: t()
  def journal(%__MODULE__{} = s, datei, eintrag),
    do: %{s | journal: [{datei, eintrag} | s.journal]}

  @doc "Das Journal in Schreibreihenfolge."
  @spec journal_liste(t()) :: [{String.t(), map()}]
  def journal_liste(%__MODULE__{journal: j}), do: Enum.reverse(j)

  @doc "Die Stränge einer Aussage merken — in der Reihenfolge ihres ersten Auftretens."
  @spec themen_merken(t(), [String.t()]) :: t()
  def themen_merken(%__MODULE__{} = s, threads) do
    %{
      s
      | themen:
          Enum.reduce(List.wrap(threads), s.themen, fn t, acc ->
            if t in acc, do: acc, else: acc ++ [t]
          end)
    }
  end

  @doc "Die Blöcke einer Aussage als belegt merken."
  @spec belegte_merken(t(), [integer()]) :: t()
  def belegte_merken(%__MODULE__{} = s, refs) do
    refs = refs |> List.wrap() |> Enum.filter(&is_integer/1)

    %{
      s
      | belegte_bloecke: Enum.into(refs, s.belegte_bloecke),
        hoechster_belegter_block: Enum.max([s.hoechster_belegter_block | refs])
    }
  end
end
