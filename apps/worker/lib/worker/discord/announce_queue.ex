defmodule Worker.Discord.AnnounceQueue do
  @moduledoc """
  Issue #1013: die ENTSCHEIDUNGS-Seite der Beitritts-Ansagen — pure, ohne
  Nostrum/GenServer testbar (Muster `ConsentState`/`ConsentGate`/`Presence`).

  Die `VoiceSession` hält eine Instanz dieses Zustands und führt nur noch die
  Seiteneffekte aus (TTS-Task, `Voice.play`, Timer). Alles, was hier entschieden
  wird, war vorher der Grund, warum die Ansagen in #1005 bewusst NICHT verdrahtet
  wurden:

  * **Begrüßung nur beim ERSTEN Beitritt pro Person und Session** (`note_join/2`).
    Ein Netzwerk-Reconnect ist ein Leave+Join innerhalb von Sekunden — ohne
    Dedup würde jede instabile Verbindung zur Begrüßungsschleife. Benannte
    Entscheidung: auch ein echter zweiter Beitritt (Pause, Klo, zurück) wird
    nicht erneut begrüßt; die Ansage soll informieren, nicht Anwesenheit
    protokollieren.
  * **Erinnerungs-Deckel pro Person** (`@max_pending_reminders`, Issue-Vorgabe 2):
    ein fremder Bot oder eine dauerhaft stumme Person kann nie zustimmen und
    würde sonst einen Nag-Loop erzeugen. Gezählt wird beim tatsächlichen
    ANSAGEN (`pending_batch/2`), nicht beim Vormerken — sonst verbrauchte ein
    Debounce-Fenster, das leer verpufft, schon den Deckel.
  * **Sammelform statt Einzel-Ansagen**: `pending_batch/2` liefert die ganze
    fällige Gruppe auf einmal — `Announcement.text_for_pending/1` baut daraus
    die deutsche Aufzählung. Die Debounce-Zeit selbst gehört der Session
    (Timer = Seiteneffekt).
  * **Warteschlange statt Sofort-Play**: `Voice.play/4` liefert bei laufender
    Wiedergabe `{:error, …}` — der bisherige Code behandelte das als `:ok`
    (der in #1005/#1013 benannte Silent-Failure-Generator). Items werden hier
    gereiht und von der Session einzeln abgespielt; ein busy-Play legt das Item
    per `push_front/2` zurück.

  Der Namens-Cache lebt mit hier drin (`note_name/3`), weil Name und
  Ansage-Entscheidung zusammen reisen: das `member`-Objekt des
  `VOICE_STATE_UPDATE` ist die EINZIGE Quelle, die ohne HTTP-Call und ohne
  privilegierten Intent Namen liefert — und es kommt genau bei den Übergängen
  vorbei, die hier entschieden werden.

  Items: `{:join, name_or_nil}` · `{:pending, [name_or_nil]}` ·
  `{:granted, name_or_nil}` — die Texte baut `Worker.Discord.Announcement`
  (dort liegt auch die Unsprechbar-Behandlung; hier reisen rohe Namen).
  """

  # Issue-Vorgabe: maximal 2 Erinnerungen pro Person und Session.
  @max_pending_reminders 2

  @type item ::
          {:join, String.t() | nil}
          | {:pending, [String.t() | nil]}
          | {:granted, String.t() | nil}

  @type t :: %{
          items: [item()],
          greeted: MapSet.t(String.t()),
          pending_told: %{String.t() => non_neg_integer()},
          names: %{String.t() => String.t()}
        }

  @spec new() :: t()
  def new do
    %{items: [], greeted: MapSet.new(), pending_told: %{}, names: %{}}
  end

  @doc """
  Personen, die beim Bot-Join schon im Kanal sitzen, gelten als begrüßt: die
  #989-Erst-Ansage spricht bereits den ganzen Raum an — sie danach einzeln
  nachzubegrüßen wäre doppelt.
  """
  @spec seed_greeted(t(), [String.t()]) :: t()
  def seed_greeted(q, dids) when is_list(dids) do
    %{q | greeted: Enum.into(dids, q.greeted, &to_string/1)}
  end

  @doc """
  Namen aus dem `member`-Objekt mitschreiben. Leere/fehlende Namen überschreiben
  einen bekannten NICHT — ein späteres Event ohne `member` (Discord garantiert
  das Feld nicht) darf den Cache nicht löschen.
  """
  @spec note_name(t(), String.t(), String.t() | nil) :: t()
  def note_name(q, did, name) when is_binary(name) do
    case String.trim(name) do
      "" -> q
      n -> %{q | names: Map.put(q.names, to_string(did), n)}
    end
  end

  def note_name(q, _did, _name), do: q

  @spec name_for(t(), String.t()) :: String.t() | nil
  def name_for(q, did), do: Map.get(q.names, to_string(did))

  @doc """
  Ein Kanal-Beitritt. `{:greet, q}` beim ersten Mal, `{:skip, q}` bei jedem
  weiteren (Reconnects, Rückkehr aus der Pause — s. Moduledoc).
  """
  @spec note_join(t(), String.t()) :: {:greet | :skip, t()}
  def note_join(q, did) do
    did = to_string(did)

    if MapSet.member?(q.greeted, did) do
      {:skip, q}
    else
      {:greet, %{q | greeted: MapSet.put(q.greeted, did)}}
    end
  end

  @doc """
  Die fällige Pending-Gruppe: von den übergebenen (noch anwesenden, noch nicht
  zustimmenden) Personen die, deren Erinnerungs-Deckel noch nicht erreicht ist.
  Zählt die Erinnerung für GENAU die zurückgegebenen Personen hoch.

  Liefert `{[], q}` wenn niemand fällig ist — der Aufrufer sagt dann nichts an
  (die „nur bei Bedarf"-Regel aus dem Issue).
  """
  @spec pending_batch(t(), [String.t()]) :: {[String.t()], t()}
  def pending_batch(q, dids) when is_list(dids) do
    due =
      dids
      |> Enum.map(&to_string/1)
      |> Enum.uniq()
      |> Enum.filter(fn did -> Map.get(q.pending_told, did, 0) < @max_pending_reminders end)

    told =
      Enum.reduce(due, q.pending_told, fn did, acc ->
        Map.update(acc, did, 1, &(&1 + 1))
      end)

    {due, %{q | pending_told: told}}
  end

  @doc false
  @spec max_pending_reminders() :: pos_integer()
  def max_pending_reminders, do: @max_pending_reminders

  @doc "Item hinten anstellen (Normalfall)."
  @spec push(t(), item()) :: t()
  def push(q, item), do: %{q | items: q.items ++ [item]}

  @doc """
  Item VORNE einreihen — für den busy-Fall: `Voice.play/4` hat das Item
  abgelehnt, es ist noch nicht gesprochen und darf seinen Platz nicht verlieren.
  """
  @spec push_front(t(), item()) :: t()
  def push_front(q, item), do: %{q | items: [item | q.items]}

  @spec pop(t()) :: {item() | nil, t()}
  def pop(%{items: []} = q), do: {nil, q}
  def pop(%{items: [item | rest]} = q), do: {item, %{q | items: rest}}

  @spec empty?(t()) :: boolean()
  def empty?(q), do: q.items == []
end
