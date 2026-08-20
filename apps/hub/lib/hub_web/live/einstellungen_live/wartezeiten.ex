defmodule HubWeb.EinstellungenLive.Wartezeiten do
  @moduledoc """
  Issue #1062: der Wartezeiten-Block am Ende von `/settings`.

  Anlass war EIN hart verdrahteter Wert (`CampaignReplay`, 30 min), der einen
  ausgelieferten Knopf unbenutzbar machte, sobald jemand ein stärkeres lokales
  Modell fuhr. Die Lehre ist allgemein: eine Wartezeit im Modul-Attribut ist
  erst nach einem Deploy änderbar — und wer sie braucht, sitzt gerade am
  Spieltisch.

  **Eine Liste, nicht drei.** `@felder` speist die Formularfelder, die
  Reihenfolge der Anzeige UND (über `keys/0`) die Integer-Normalisierung in
  `HubWeb.EinstellungenLive.Options`. Ein Feld hier zu ergänzen genügt; die
  #1090-Lektion — eine an drei Stellen von Hand gepflegte Liste vergisst
  irgendwann einen Eintrag, und nichts wird rot — gilt hier genauso.

  Die Werte sind bewusst NICHT auf Anfänger zugeschnitten: wer hier dreht,
  weiss, warum. Deshalb steht neben jedem Feld, was passiert, wenn es zu klein
  ist — das ist die Information, die man beim Drehen braucht.
  """

  use HubWeb, :html

  # {key, Beschriftung, Hilfetext}
  @gruppen [
    {"Kampagnen-Replay & Probelauf",
     [
       {:replay_stage_timeout_ms, "Replay: Frist ohne Fortschritt",
        "Bricht den Kampagnen-Replay ab, wenn eine Session so lange KEINE " <>
          "Statusmeldung mehr sendet. Misst Stille, nicht Gesamtdauer — ein Lauf, " <>
          "der Fortschritt zeigt, läuft beliebig lange. Zu klein: der Replay bricht " <>
          "nach der ersten Session ab und die übrigen bleiben unangetastet."},
       {:probelauf_stage_timeout_ms, "Probelauf: Frist pro Schritt",
        "Derselbe Wächter im Probelauf. Dessen Sessions sind synthetisch und kurz."}
     ]},
    {"Hub-Verbindung",
     [
       {:hub_publish_timeout_ms, "Publish (einzeln)",
        "Wartezeit auf die seq-Zuweisung des Hubs für einen einzelnen Intent."},
       {:hub_publish_batch_timeout_ms, "Publish (Batch)",
        "Dasselbe für einen Frame mit bis zu 100 Events."},
       {:hub_publish_chunk_pause_ms, "Pause zwischen Batch-Frames",
        "Lässt Hub-PubSub und LiveView-Diffing zwischen zwei Frames drainen. " <>
          "Zu klein: ein grosser Backlog flutet die Oberfläche."}
     ]},
    {"LLM (Cloud-Backends)",
     [
       {:llm_cloud_receive_timeout_ms, "Antwortfrist Completion",
        "Das Gegenstück zu HTTP-Timeout auf der lokalen Seite. Zu klein: lange " <>
          "Render-Outputs brechen mitten im Text ab."},
       {:llm_cloud_models_receive_timeout_ms, "Antwortfrist Modell-Liste",
        "Nur Metadaten, deshalb deutlich kürzer."},
       {:llm_cloud_initial_backoff_ms, "Erster Retry-Abstand",
        "Wird pro Versuch verdoppelt (429/5xx/Netzfehler, zwei Versuche)."},
       {:llm_cloud_models_cache_ttl_ms, "Standzeit Modell-Liste",
        "Wie lange die geholte Modell-Liste wiederverwendet wird."}
     ]},
    {"Sidecars",
     [
       {:faithfulness_sidecar_timeout_ms, "NLI-Sidecar: Antwortfrist",
        "Pro Grounding-Prüfung im Verify-Gate."},
       {:sidecar_health_poll_interval_ms, "Sidecar-Start: Poll-Abstand",
        "Takt der /health-Abfrage, bis ein frisch gestarteter Sidecar antwortet."}
     ]},
    {"Materializer",
     [
       {:materializer_call_timeout_ms, "Einzel-Apply",
        "Wartezeit auf das Anwenden eines einzelnen Events."},
       {:materializer_batch_timeout_base_ms, "Batch: Grundwert",
        "Die Batch-Frist ist Grundwert + Anzahl × Aufschlag, gedeckelt."},
       {:materializer_batch_timeout_per_event_ms, "Batch: Aufschlag je Event", ""},
       {:materializer_batch_timeout_max_ms, "Batch: Deckel",
        "Zu klein: ein grosser Sync-Backlog läuft ins Timeout statt durchzulaufen."}
     ]},
    {"Aufnahme & Rohaudio",
     [
       {:streamer_ghost_timeout_ms, "Mikro: Frist bis „weg\"",
        "Ohne Audio-Chunk seit dieser Zeit gilt ein Streamer als getrennt. " <>
          "Default entspricht 8 verpassten 500-ms-Chunks."},
       {:streamer_sweep_interval_ms, "Mikro: Prüftakt", ""},
       {:audio_recover_delay_ms, "Recovery: erster Scan nach dem Boot",
        "Verzögerung, bis GpuQueue, Mnesia und HubClient sicher oben sind."},
       {:audio_recover_interval_ms, "Recovery: Wiederholung",
        "Takt, in dem liegengebliebenes Audio erneut aufgegriffen wird (#1055)."},
       {:audio_retention_check_interval_ms, "Archiv: Purge-Takt",
        "Wie oft das Audio-Archiv auf abgelaufene Aufnahmen geprüft wird."},
       {:audio_late_append_debounce_ms, "Late-Append: Sammelfenster",
        "Trifft ein Chunk nach dem Session-Ende ein, wird so lange auf weitere " <>
          "gewartet, bevor nach-transkribiert wird."}
     ]},
    {"Discord-Bot",
     [
       {:discord_join_settle_ms, "Pause nach Kanal-Beitritt",
        "Bevor gesprochen wird. Zu klein: die Ansage beginnt, bevor die " <>
          "Voice-Verbindung trägt."},
       {:discord_announce_poll_ms, "Ansage: Poll-Abstand",
        "Takt der „ist die Ansage durch?\"-Abfrage."},
       {:discord_announce_max_ms, "Ansage: Obergrenze",
        "Danach wird lieber ohne Ansage aufgezeichnet als gar nicht."},
       {:discord_pending_delay_ms, "Einwilligung: Erinnerungsabstand",
        "Nach dem letzten Beitritt; jeder neue Beitritt setzt ihn zurück."},
       {:discord_bot_idle_poll_ms, "Gateway: Token-Poll im Leerlauf",
        "Rein lokal (Settings/ENV), kein HTTP."},
       {:discord_speaking_grace_ms, "Präsenz: Sprech-Nachlauf",
        "Nachlauf, bis jemand ohne Paket wieder als still gilt. Zu klein: die " <>
          "Anzeige flackert zwischen den Silben."},
       {:discord_presence_tick_ms, "Präsenz: Broadcast-Takt",
        "Zu klein: der Paketstrom flutet die LiveViews."},
       {:discord_flush_slow_ms, "Flush: Warnschwelle",
        "Ab dieser Flush-Dauer wird gewarnt — der Stop blockiert den Recorder " <>
          "so lange."}
     ]},
    {"Worker-Lebenszyklus",
     [
       {:lifecycle_halt_grace_ms, "Frist bis zum harten Halt",
        "Zwischen „Node hält an\" und dem Abschuss. Zu klein: laufendes IO wird " <>
          "abgeschnitten."},
       {:updater_tick_ms, "Selbst-Update: Prüftakt", ""},
       {:updater_backoff_ms, "Selbst-Update: Sperre nach Fehlversuch", ""}
     ]}
  ]

  @doc "Alle Keys in Anzeige-Reihenfolge — auch die Quelle der Int-Normalisierung."
  @spec keys() :: [atom()]
  def keys, do: for({_titel, felder} <- @gruppen, {k, _l, _h} <- felder, do: k)

  @doc "Die Gruppen für die Anzeige."
  def gruppen, do: @gruppen

  attr(:settings, :map, required: true)

  def block(assigns) do
    assigns = assign(assigns, :gruppen, @gruppen)

    ~H"""
    <div class="mt-8 border-t border-bg-3/60 pt-6">
      <h2 class="text-sm font-semibold text-ink-0 uppercase tracking-wider mb-2">
        Wartezeiten
      </h2>
      <p class="text-xs text-ink-2 mb-4">
        Alle Fristen und Takte des Workers, in Millisekunden. Die Vorgabewerte sind
        die bisher fest verdrahteten — wer nichts ändert, ändert nichts.
        <strong class="text-ink-1">Leeres Feld = Vorgabewert.</strong>
        Werte werden beim Speichern auf höchstens 24 h begrenzt.
      </p>

      <.form for={%{}} phx-submit="save">
        <div class="space-y-6">
          <fieldset :for={{titel, felder} <- @gruppen} class="panel p-4">
            <legend class="text-xs uppercase tracking-widest text-ink-2 px-2">
              {titel}
            </legend>

            <div class="grid gap-4 sm:grid-cols-2">
              <label :for={{key, beschriftung, hilfe} <- felder} class="block">
                <span class="text-sm text-ink-1">{beschriftung}</span>
                <input
                  type="number"
                  min="0"
                  step="100"
                  name={"settings[#{key}]"}
                  value={@settings[Atom.to_string(key)]}
                  class="mt-1 block w-full bg-bg-0 border border-bg-3 rounded-md px-3 py-2 text-ink-0 font-mono text-sm focus:border-accent focus:ring-0"
                />
                <p :if={hilfe != ""} class="text-xs text-ink-2 mt-1">{hilfe}</p>
              </label>
            </div>
          </fieldset>
        </div>

        <div class="flex justify-end gap-3 mt-4">
          <.btn variant="primary" icon="check" type="submit">Wartezeiten speichern</.btn>
        </div>
      </.form>
    </div>
    """
  end
end
