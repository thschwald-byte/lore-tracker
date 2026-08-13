defmodule Worker.Discord.ConsentButton do
  alias Worker.Discord.ConsentGate

  @moduledoc """
  Issue #1005: die Einwilligung per **Klick** — Discord-Buttons im Voice-Kanal.

  ## Warum ein Klick und nicht (nur) die Stimme

  Gesprochene Zustimmung ist bequem, aber **nicht identitätsgebunden**: sagt
  Spieler A den Satz und Spieler B hat Lautsprecher statt Kopfhörer, landet A's
  Stimme in B's Tonspur — und die Spracherkennung würde daraus B's Einwilligung
  machen. Das ist der schwerste denkbare Fehler in diesem Feature (eine
  *unterstellte* Einwilligung), und rein akustisch ist er nicht ausschließbar.
  Ein Klick trägt dagegen die von Discord authentifizierte Identität
  (`interaction.user.id`).

  Dazu kommt der Live-Befund aus #1002: der Consent-Satz wurde gesagt und von
  Whisper **nicht** erkannt. Ein Einwilligungs-Mechanismus, durch den die
  Einwilligenden nicht durchkommen, trägt nicht.

  ## Alles hier ist PURE

  Payload-Bau, `custom_id`-Kodierung und die Gültigkeitsprüfung eines Klicks sind
  reine Funktionen — die `VoiceSession` und der `Consumer` sind ohne echten
  Nostrum-Bot kaum testbar, deshalb liegt jede *Entscheidung* außerhalb.

  ## Warum die `custom_id` Version UND Session trägt

  Discord-Nachrichten sind persistent: der Button von letzter Woche ist noch
  klickbar. Ohne Session im `custom_id` würde ein solcher Klick eine Zustimmung
  für die **heutige** Aufnahme erzeugen, ohne dass die Person davon weiß. Und
  ohne Version würde eine Zustimmung zum alten Wortlaut eine geänderte
  Einwilligung stillschweigend abdecken.

  ## Warum der `components`-Block eine schlichte Map ist

  `Nostrum.Struct.Component` hat `@derive Jason.Encoder` über **alle** Felder —
  serialisiert also `"url": null, "emoji": null, …` mit. Ob Discord das für jede
  Feldkombination akzeptiert, ist in Nostrum selbst nicht getestet (es gibt dort
  keine Component-Tests), und `:components` ist in der `Api.Message.create/2`-Doku
  nicht einmal gelistet — es funktioniert als Passthrough. Ein handgebauter,
  minimaler Block hat diese Unsicherheit nicht.
  """

  # Discord-Limit für custom_id ist 100 Zeichen. Präfix + Aktion + Version +
  # UUIDv7-Session (36) bleibt deutlich darunter.
  @prefix "audio_consent"
  @separator "|"

  # Nostrum.Constants.ButtonStyle: 3 = success (grün), 4 = danger (rot).
  @style_success 3
  @style_danger 4
  @type_action_row 1
  @type_button 2

  @doc """
  Die `custom_id` eines Buttons: Präfix, Aktion, Wortlaut-Version, Session.
  """
  @spec custom_id(:grant | :revoke, String.t()) :: String.t()
  def custom_id(action, session_id) when action in [:grant, :revoke] and is_binary(session_id) do
    Enum.join([@prefix, to_string(action), ConsentGate.version(), session_id], @separator)
  end

  @doc """
  `custom_id` zerlegen. Alles, was nicht exakt passt, ist `{:error, :malformed}` —
  hier wird bewusst nichts geraten.
  """
  @spec parse_custom_id(String.t()) ::
          {:ok, :grant | :revoke, String.t(), String.t()} | {:error, :malformed}
  def parse_custom_id(id) when is_binary(id) do
    case String.split(id, @separator) do
      [@prefix, "grant", version, session_id] when version != "" and session_id != "" ->
        {:ok, :grant, version, session_id}

      [@prefix, "revoke", version, session_id] when version != "" and session_id != "" ->
        {:ok, :revoke, version, session_id}

      _ ->
        {:error, :malformed}
    end
  end

  def parse_custom_id(_), do: {:error, :malformed}

  @doc """
  Darf dieser Klick gelten? PURE — die einzige Stelle, die darüber entscheidet.

  `:stale_version` = Klick auf eine Nachricht mit altem Einwilligungs-Wortlaut,
  `:stale_session` = Klick auf die Nachricht einer früheren Aufnahme (der
  häufigste Fall, weil Discord-Nachrichten liegen bleiben).
  """
  @spec verdict_for_click(
          {:ok, :grant | :revoke, String.t(), String.t()} | {:error, :malformed},
          String.t(),
          String.t()
        ) ::
          {:accept, :grant | :revoke}
          | {:reject, :malformed | :stale_version | :stale_session}
  def verdict_for_click({:error, :malformed}, _current_version, _live_session_id),
    do: {:reject, :malformed}

  def verdict_for_click({:ok, action, version, session_id}, current_version, live_session_id) do
    cond do
      version != current_version -> {:reject, :stale_version}
      session_id != live_session_id -> {:reject, :stale_session}
      true -> {:accept, action}
    end
  end

  def verdict_for_click(_parsed, _current_version, _live_session_id), do: {:reject, :malformed}

  @doc """
  Der Nachrichten-Payload für `Nostrum.Api.Message.create/2`. PURE.

  Der Text nennt bewusst **beide** Wege (klicken oder sprechen) und sagt die
  Konsequenz des Nichtstuns — ohne die wäre die Einwilligung nicht informiert.
  Beim Widerruf ist die Formulierung präzise: er beendet die Aufzeichnung, er
  löscht **nicht** rückwirkend bereits Gespeichertes (das wäre ein eigener
  Erasure-Pfad, und „wird gelöscht" wäre hier eine falsche Zusage).
  """
  @spec payload(String.t(), String.t() | nil) :: keyword()
  def payload(session_id, campaign_name \\ nil) when is_binary(session_id) do
    [content: content(campaign_name), components: [action_row(session_id)]]
  end

  @doc false
  @spec content(String.t() | nil) :: String.t()
  def content(campaign_name) do
    kampagne =
      case campaign_name do
        name when is_binary(name) and name != "" -> " für die Kampagne **#{name}**"
        _ -> ""
      end

    """
    🎙 **Diese Sitzung#{kampagne} wird aufgezeichnet.**

    Ohne deine Einwilligung wird deine Stimme **nicht gespeichert** — du kannst \
    normal mitspielen, deine Tonspur wird dann verworfen.

    Klicke auf **Ich stimme zu**.

    Die Einwilligung gilt auch für künftige Aufnahmen und kann jederzeit \
    widerrufen werden. Ein Widerruf beendet die Aufzeichnung ab diesem Moment; \
    bereits gespeicherte Aufnahmen werden dadurch nicht gelöscht.
    """
  end

  @doc false
  @spec action_row(String.t()) :: map()
  def action_row(session_id) do
    %{
      type: @type_action_row,
      components: [
        %{
          type: @type_button,
          style: @style_success,
          label: "Ich stimme zu",
          custom_id: custom_id(:grant, session_id)
        },
        %{
          type: @type_button,
          style: @style_danger,
          label: "Ich widerspreche",
          custom_id: custom_id(:revoke, session_id)
        }
      ]
    }
  end

  @doc "Antworttext auf einen Klick (ephemer, nur für den Klickenden sichtbar)."
  @spec ack_text(:grant | :revoke) :: String.t()
  def ack_text(:grant),
    do: "✅ Danke — deine Einwilligung ist gespeichert. Deine Stimme wird ab jetzt aufgezeichnet."

  def ack_text(:revoke),
    do:
      "🚫 Widerruf gespeichert. Ab jetzt wird deine Stimme nicht mehr aufgezeichnet. " <>
        "Bereits gespeicherte Aufnahmen bleiben davon unberührt."

  @doc "Antworttext auf einen abgelehnten Klick."
  @spec reject_text(:malformed | :stale_version | :stale_session) :: String.t()
  def reject_text(:stale_session),
    do:
      "Diese Nachricht gehört zu einer früheren Aufnahme. Für die laufende Sitzung " <>
        "erscheint eine neue Nachricht im Kanal."

  def reject_text(:stale_version),
    do:
      "Der Einwilligungstext hat sich geändert — bitte benutze die aktuelle Nachricht " <>
        "im Kanal."

  def reject_text(_), do: "Diese Schaltfläche ist nicht mehr gültig."
end
