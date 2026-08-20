defmodule Worker.Discord.Presence do
  @moduledoc """
  Issue #988: der **pure Kern** der Discord-Voice-Präsenz — wer sitzt im Kanal,
  wer spricht gerade, wessen Tonspur wird gespeichert. Bewusst getrennt vom
  `VoiceSession`-GenServer (der ohne echten Nostrum-Bot kaum testbar ist):
  alles, was hier entschieden wird, ist ohne Discord-Verbindung mit Tests
  festnagelbar.

  ## „Wer spricht" ohne Sprech-Event

  Es gibt kein brauchbares Discord-Event dafür: `VOICE_SPEAKING_UPDATE` meldet
  laut Nostrum-Doku ausschließlich den **Bot selbst** („when the bot starts or
  stops playing audio"). Das Signal steckt stattdessen im Paketstrom — Discord
  überträgt pro Sprecher **nur während gesprochen wird** (dieselbe Eigenschaft,
  auf der schon die #985-Zeitkorrektur aufbaut), und jedes Paket trägt seine
  SSRC. Nostrums Doku zu `VOICE_INCOMING_PACKET` benennt die SSRC→User-Zuordnung
  ausdrücklich als vorgesehenen Weg dafür.

  Ein Paket bedeutet also: diese Person spricht JETZT. Weil zwischen zwei Silben
  kurze Lücken liegen, gilt ein **Nachlauf** (`discord_speaking_grace_ms`) — ohne ihn
  würde das UI im Sprechrhythmus flackern.

  ## Warum gedrosselt wird

  Nostrum beziffert den Paketstrom auf „about 50 events per second per speaking
  user". Ein Broadcast pro Paket würde die LiveViews fluten; deshalb baut
  `VoiceSession` den Snapshot in einem festen Takt (`discord_presence_tick_ms`) statt bei jedem
  Paket — gleiche Größenordnung wie der bestehende 5-Hz-`mic_level`-Pfad des
  Browser-Mikros.

  ## Zustände im UI

  Die Consent-Angabe kommt aus `Worker.Discord.ConsentGate` und ist damit
  **dieselbe** Entscheidung, die im Audio-Pfad die Spur speichert oder verwirft
  (#1002). Das durchgestrichene Icon im Hub verspricht deshalb keinen Ausschluss,
  den es nicht gibt — es zeigt exakt den Zustand, nach dem auch gehandelt wird.
  """

  # Nachlauf, in dem jemand nach dem letzten Paket noch als „spricht" gilt.
  # Nachlauf (Default 400 ms): lang genug für Sprechpausen zwischen Silben und
  # Wörtern (bei 20-ms-Paketen sind das 20 ausgefallene Pakete), kurz genug,
  # dass das Ende einer Äußerung sichtbar wird statt nachzuhängen. Takt
  # (Default 200 ms): 5 Hz — flüssig fürs Auge, ein Zehntel der Paketrate.
  #
  # Issue #1062: beide Werte kommen aus den Settings
  # (`discord_speaking_grace_ms` / `discord_presence_tick_ms`). Die zwei
  # Accessoren unten sind die EINZIGEN Lesestellen; `speaking?/3` bekommt den
  # Nachlauf als Parameter, damit der pure Kern dieses Moduls pur bleibt.

  @type participant :: %{
          required(String.t()) => String.t() | boolean()
        }

  @doc "Nachlauf in ms, nach dem jemand ohne Paket wieder als still gilt."
  @spec speaking_grace_ms() :: pos_integer()
  def speaking_grace_ms, do: Worker.Settings.get(:discord_speaking_grace_ms)

  @doc "Broadcast-Takt in ms."
  @spec tick_ms() :: pos_integer()
  def tick_ms, do: Worker.Settings.get(:discord_presence_tick_ms)

  @doc """
  Baut die Teilnehmerliste für den Hub.

  - `participant_ids` — wer laut Discord im Voice-Channel sitzt (Strings).
  - `last_packet_at` — `%{discord_id => monotone ms}` des letzten Pakets.
  - `consent_by_id` — `%{discord_id => boolean}`, das Urteil des ConsentGate.
  - `now_ms` — monotone Jetzt-Zeit (injiziert, damit testbar).

  Deterministisch sortiert (nach `discord_id`) — sonst flackert die Icon-
  Reihenfolge im UI bei jedem Tick, weil MapSet-/Map-Iteration keine stabile
  Ordnung garantiert.
  """
  @spec snapshot([String.t()], %{String.t() => integer()}, %{String.t() => boolean()}, integer()) ::
          [participant()]
  def snapshot(participant_ids, last_packet_at, consent_by_id, now_ms)
      when is_list(participant_ids) and is_map(last_packet_at) and is_map(consent_by_id) do
    # Issue #1062: EINMAL je Snapshot lesen, nicht je Teilnehmer — jeder
    # `Settings.get/2` ist eine Mnesia-Transaktion, und dieser Pfad läuft im
    # Präsenz-Takt.
    grace = speaking_grace_ms()

    participant_ids
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(fn did ->
      %{
        "discord_id" => did,
        "speaking" => speaking?(Map.get(last_packet_at, did), now_ms, grace),
        "consent" => Map.get(consent_by_id, did, false) == true
      }
    end)
  end

  @doc """
  Spricht diese Person gerade? `nil` (nie ein Paket gesehen) ⇒ nein.

  Ein Zeitstempel aus der Zukunft (Uhr-Sprung o.ä.) zählt als „spricht" — die
  Alternative wäre, ihn als abgelaufen zu behandeln, was bei einem Sprung nach
  vorn die Anzeige fälschlich einfrieren ließe.

  Der dritte Parameter ist der Nachlauf. Ohne ihn wird er aus den Settings
  gelesen (`speaking?/2`, die eingeführte Form); mit ihm ist die Funktion rein
  und ohne Mnesia testbar.
  """
  @spec speaking?(integer() | nil, integer(), pos_integer() | nil) :: boolean()
  def speaking?(last_at, now_ms, grace_ms \\ nil)

  def speaking?(nil, _now_ms, _grace_ms), do: false

  def speaking?(last_at, now_ms, grace_ms) when is_integer(last_at) and is_integer(now_ms),
    do: now_ms - last_at < (grace_ms || speaking_grace_ms())

  def speaking?(_last_at, _now_ms, _grace_ms), do: false

  @doc """
  Räumt Sprech-Zeitstempel von Personen weg, die den Kanal verlassen haben.

  Ohne das wüchse `last_packet_at` über eine lange Session mit jedem Gast
  monoton weiter — klein, aber ein unbegrenzter State im RAM ist genau die
  Klasse, die dieses Projekt sonst konsequent deckelt.
  """
  @spec prune(%{String.t() => integer()}, [String.t()]) :: %{String.t() => integer()}
  def prune(last_packet_at, participant_ids)
      when is_map(last_packet_at) and is_list(participant_ids) do
    Map.take(last_packet_at, participant_ids)
  end

  @doc """
  Anfangsbestand aus Nostrums `voice_states` der Guild (öffentliches Feld der
  `Nostrum.Struct.Guild`): alle User im gegebenen Voice-Channel, ohne den Bot
  selbst. Nimmt die Rohliste entgegen (kein Nostrum-Call hier drin) — damit
  bleibt die Filterlogik pur und testbar.

  Der Bot sitzt seit #989 UNGEMUTET im Kanal (er spricht die Consent-Ansage) —
  er würde sonst als eigener „Teilnehmer" mit Sprech-Puls auftauchen.
  """
  @spec initial_participants([map()], non_neg_integer(), non_neg_integer() | nil) :: [String.t()]
  def initial_participants(voice_states, voice_channel_id, bot_user_id)
      when is_list(voice_states) do
    voice_states
    |> Enum.filter(fn vs -> Map.get(vs, :channel_id) == voice_channel_id end)
    |> Enum.map(fn vs -> Map.get(vs, :user_id) end)
    |> Enum.reject(&is_nil/1)
    |> Enum.reject(&(&1 == bot_user_id))
    |> Enum.map(&to_string/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  def initial_participants(_voice_states, _channel, _bot), do: []
end
