defmodule HubWeb.CampaignLive.Editors do
  @moduledoc """
  Issue #570 (God-Module-Split aus `HubWeb.CampaignLive.Components`): die großen
  interaktiven Function-Components der Kampagnen-LiveView — Speaker-Picker,
  Refs-Popover, Mic-Setup-Modal und Stil/Flavor-Editor.

  Trennung von `Components`: dort leben die kleinen Präsentations-/Formatierungs-
  Helfer (`display_for`, `render_md_safe`, `column`, …); hier die
  zeilenstarken Modals/Editoren. `HubWeb.CampaignLive` importiert beide, sodass
  das colocated Template die `<.foo>`-Aufrufe unverändert auflöst.
  """
  use HubWeb, :html

  # Issue #570: die geteilten Präsentations-Helfer (display_for/3,
  # pseudo_speaker_label, output_label, vorgabe_set?, slot_*_class,
  # editable_slot_label, …) bleiben in Components und werden hier importiert.
  import HubWeb.CampaignLive.Components

  # Issue #19: Modal zum Zuordnen eines Diarisierungs-Pseudo-Sprechers zu
  # einem echten Kampagnen-Mitglied.
  attr(:pick, :map, required: true)
  attr(:members, :list, required: true)
  attr(:users, :map, required: true)
  attr(:character_names, :map, default: %{})
  attr(:assignments, :map, default: %{})

  def speaker_picker(assigns) do
    assigns = assign(assigns, :current, Map.get(assigns.assignments, assigns.pick.label))

    ~H"""
    <div
      role="dialog"
      aria-modal="true"
      aria-labelledby="speaker-picker-title"
      phx-window-keydown="speaker_pick_cancel"
      phx-key="Escape"
      class="fixed inset-0 z-50 flex items-center justify-center bg-bg-0/70 backdrop-blur-sm"
    >
      <div
        class="bg-bg-1 border border-bg-3 rounded-md shadow-2xl max-w-md w-full mx-4 p-5 flex flex-col gap-3"
        phx-click-away="speaker_pick_cancel"
      >
        <h3 id="speaker-picker-title" class="text-sm text-ink-0 font-semibold">
          {pseudo_speaker_label(@pick.label)} zuordnen
        </h3>
        <p class="text-xs text-ink-2">
          Wähle das Kampagnen-Mitglied, das hinter diesem Sprecher steckt. Die
          Zuordnung gilt für die ganze Session.
        </p>
        <ul class="text-xs text-ink-1 flex flex-col gap-1 max-h-80 overflow-y-auto">
          <%= for m <- @members do %>
            <li>
              <button
                type="button"
                phx-click="speaker_assign"
                phx-value-label={@pick.label}
                phx-value-session={@pick.session_id}
                phx-value-discord_id={m["discord_id"]}
                class={[
                  "text-left w-full hover:bg-bg-2/50 rounded px-2 py-1.5 cursor-pointer flex items-center justify-between",
                  m["discord_id"] == @current && "bg-bg-2/40"
                ]}
              >
                <span>{display_for(m["discord_id"], @users, @character_names)}</span>
                <span :if={m["discord_id"] == @current} class="text-accent text-[10px]">✓ aktuell</span>
              </button>
            </li>
          <% end %>
        </ul>
        <div class="flex justify-between pt-2">
          <.btn
            :if={is_binary(@current) and @current != ""}
            variant="ghost"
            phx-click="speaker_unassign"
            phx-value-label={@pick.label}
            phx-value-session={@pick.session_id}
          >
            Zuordnung aufheben
          </.btn>
          <.btn variant="ghost" phx-click="speaker_pick_cancel">Schließen</.btn>
        </div>
      </div>
    </div>
    """
  end

  # Issue #114: Source-Refs-Popover. Zwei Modi:
  # - kind in ["summary", "epos", "chronik"]: refs ist [utterance_id, ...]
  #   → liste die Utterances + biete goto_utterance an.
  # - kind == "utterance": refs ist [%{kind, id, label}, ...] (Backward-Index)
  #   → liste die Einträge die diese Utterance zitieren + biete goto_entry an.
  attr(:popover, :map, required: true)
  attr(:utterances, :list, required: true)
  attr(:users, :map, required: true)
  attr(:character_names, :map, default: %{})

  def refs_popover(%{popover: %{kind: "utterance"}} = assigns) do
    ~H"""
    <.lt_modal on_close="hide_refs" max_width="max-w-lg">
      <h3 class="text-sm text-ink-0 font-semibold">
        Diese Utterance wird zitiert in {length(@popover.refs)} Eintrag/Einträgen
      </h3>
      <%= if @popover.refs == [] do %>
        <p class="text-xs text-ink-2 mt-3">Niemand zitiert sie aktuell.</p>
      <% else %>
        <ul class="text-xs text-ink-1 flex flex-col gap-1 max-h-80 overflow-y-auto mt-3">
          <%= for entry <- @popover.refs do %>
            <li>
              <button
                type="button"
                phx-click="goto_entry"
                phx-value-kind={entry.kind}
                phx-value-id={entry.id}
                class="text-left w-full hover:bg-bg-2/50 rounded px-2 py-1 cursor-pointer"
              >
                <span class="text-ink-2 uppercase tracking-wider text-[10px] mr-2">{entry.kind}</span>
                {entry.label}
              </button>
            </li>
          <% end %>
        </ul>
      <% end %>
      <div class="flex justify-end pt-3">
        <.btn variant="ghost" phx-click="hide_refs">Schließen</.btn>
      </div>
    </.lt_modal>
    """
  end

  def refs_popover(assigns) do
    ~H"""
    <.lt_modal on_close="hide_refs" max_width="max-w-lg">
      <h3 class="text-sm text-ink-0 font-semibold">
        Quellen ({length(@popover.refs)} Utterance{if length(@popover.refs) == 1, do: "", else: "s"})
      </h3>
      <%= if @popover.refs == [] do %>
        <p class="text-xs text-ink-2 mt-3">
          Dieser Eintrag hat keine source_refs (Pre-#114-Stand oder LLM-JSON-Parse fehlgeschlagen).
        </p>
      <% else %>
        <ul class="text-xs text-ink-1 flex flex-col gap-1 max-h-80 overflow-y-auto mt-3">
          <%= for uid <- @popover.refs do %>
            <%
              utt = Enum.find(@utterances, &((&1["id"] || &1[:id]) == uid))
              speaker_did = utt && (utt["discord_id"] || utt[:discord_id])
              speaker_name = display_for(speaker_did, @users, @character_names)
              text_preview =
                case utt do
                  %{} = u -> u["text"] || u[:text] || ""
                  _ -> "(Quelle nicht mehr verfügbar)"
                end
            %>
            <li>
              <button
                type="button"
                phx-click="goto_utterance"
                phx-value-id={uid}
                class="text-left w-full hover:bg-bg-2/50 rounded px-2 py-1 cursor-pointer"
                disabled={is_nil(utt)}
              >
                <span class="text-accent font-mono text-[10px] mr-2">{String.slice(uid, 0, 8)}</span>
                <span :if={speaker_name} class="text-ink-2 mr-1">{speaker_name}:</span>
                <span class={if is_nil(utt), do: "text-rec-soft italic", else: ""}>
                  {text_preview |> to_string() |> String.slice(0, 120)}
                </span>
              </button>
            </li>
          <% end %>
        </ul>
      <% end %>
      <div class="flex justify-end pt-3">
        <.btn variant="ghost" phx-click="hide_refs">Schließen</.btn>
      </div>
    </.lt_modal>
    """
  end

  # Issue #64: Audio-Aufnahme-Consent-Modal. Erstaufnahme-Gate vor
  # getUserMedia/getDisplayMedia. Texte hardcoded auf Deutsch — TODO #18
  # (i18n) sobald das Übersetzungs-Framework steht, die vier Punkte +
  # Button-Labels extrahieren.
  #
  # Issue #317: mode-aware. Im :multi-Modus (Raummikro) werden drei
  # zusätzliche Absätze gerendert, die die Aufnahme-Dritter-, Diarisierungs-
  # und SL-Verantwortungs-Punkte klarstellen. Akzeptieren in diesem Modus
  # speichert Version "v2", die auch den Per-Spieler-Pfad (v1) mit abdeckt.
  # `assigns.mode` ist :per_player | :multi | nil — nil fällt auf den
  # Per-Spieler-Text zurück.
  # Issue #391/#400: Setup-Popup vor der Aufnahme. Ein einziges Modal — Device-
  # Auswahl + ASR-Phrasen-Test, und bei fehlendem Consent zusätzlich das Häkchen.
  # KEIN Aufnahme-Button und kein "Bestätigen": sobald ein Mikro offen ist
  # lauscht der Hook automatisch; sprich die angezeigte Phrase. Das Modal
  # schließt automatisch sobald die Phrase erkannt wurde UND (kein Consent
  # nötig ODER Häkchen gesetzt). Nur "Abbrechen" als bewusste Geste (auch
  # Backdrop/Escape via lt_modal-on_close).
  attr(:devices, :map, required: true)
  attr(:consent_required, :boolean, required: true)
  attr(:consent_acked, :boolean, required: true)
  attr(:consent_mode, :atom, default: nil)
  attr(:local_level, :float, default: 0.0)
  attr(:phrase, :map, default: nil)
  attr(:checking, :boolean, default: false)
  attr(:last_transcript, :string, default: nil)
  attr(:phrase_ok, :boolean, default: false)
  attr(:error, :string, default: nil)

  def mic_setup_modal(assigns) do
    ~H"""
    <.lt_modal
      on_close="mic_setup_cancel"
      title="Mikrofon einrichten"
      max_width="max-w-lg"
      dismiss_on_outside={false}
    >
      <div class="flex flex-col gap-4">
        <%= if @consent_required do %>
          <div class="text-sm text-ink-1 flex flex-col gap-2 max-h-64 overflow-y-auto pr-1 border border-border rounded-md p-3 bg-surface-2/40">
            <p :if={@consent_mode == :multi} class="text-ink-0">
              Du startest gleich den <strong>Raummikro-Modus</strong>: <strong>eine</strong>
              Audioquelle (dein Gerät) nimmt den ganzen Tisch auf — du nimmst damit
              auch andere Anwesende mit auf.
            </p>
            <p :if={@consent_mode != :multi}>
              Bevor das Mikrofon aktiviert wird, möchten wir dich aufklären, was
              mit den Audiodaten passiert:
            </p>
            <ul class="list-disc list-inside space-y-1 text-ink-2">
              <li>
                Audio wird im Browser aufgezeichnet und in 500-ms-Chunks an den
                für diese Kampagne zuständigen Worker übertragen.
              </li>
              <li>
                Der Worker läuft auf der Hardware des Spielleiters (lokal oder
                auf seinem Server) und transkribiert mit Whisper – der
                loretracker-Hub selbst speichert keine Audiodaten.
              </li>
              <li>
                Audio-Chunks werden im Worker zwischengespeichert, solange die
                Session läuft und für mögliche Re-Transkriptionen verfügbar
                bleiben sollen. Eine zeitlich harte Retention-Vorgabe gibt es
                aktuell noch nicht – frag deinen Spielleiter wie er es hält.
              </li>
              <li :if={@consent_mode != :multi}>
                Du kannst deine eigenen Utterances jederzeit in der
                Protokoll-Spalte editieren oder löschen. Eine ganze Session
                löscht der Spielleiter über die Kampagne.
              </li>
              <li :if={@consent_mode == :multi}>
                Die Aufnahme wird im Worker <strong>post-session per Diarisierung
                automatisch nach Stimmen getrennt</strong>
                und Pseudo-Sprechern zugewiesen. Du als Spielleiter ordnest die
                Pseudo-Sprecher danach in der UI echten Kampagnen-Mitgliedern zu.
              </li>
              <li :if={@consent_mode == :multi}>
                <strong>Du bist als Spielleiter dafür verantwortlich</strong>, das
                Einverständnis aller Mitspieler einzuholen, bevor du startest.
                Mitspieler ohne loretracker-Account können ihre Utterances nicht
                selbst editieren — Korrekturen und Löschungen musst du als SL
                übernehmen.
              </li>
            </ul>
          </div>

          <label class="flex items-start gap-2 text-sm text-ink-1 cursor-pointer">
            <input
              type="checkbox"
              phx-click="mic_setup_consent_toggle"
              checked={@consent_acked}
              class="mt-0.5 rounded border-border bg-bg text-primary focus:ring-primary"
            />
            <span :if={@consent_mode == :multi}>
              Ich habe die Punkte gelesen, habe das Einverständnis der Mitspieler
              eingeholt und stimme der Aufnahme zu.
            </span>
            <span :if={@consent_mode != :multi}>
              Ich habe die Punkte gelesen und stimme der Aufnahme zu.
            </span>
          </label>
        <% end %>

        <div class="flex flex-col gap-1">
          <label class="text-sm text-ink-1" for="mic-setup-device">Mikrofon wählen</label>
          <form phx-change="mic_setup_select_device">
            <select
              id="mic-setup-device"
              name="device_id"
              class="w-full bg-bg border border-border rounded px-2 py-1.5 text-sm text-ink-0"
            >
              <option :if={@devices.devices == []} value="" disabled selected>
                Mikrofone werden geladen …
              </option>
              <option
                :for={d <- @devices.devices}
                value={d.device_id}
                selected={d.device_id == @devices.preferred_id}
              >
                {d.label}
              </option>
            </select>
          </form>
        </div>

        <div class="flex flex-col gap-2">
          <p class="text-sm text-ink-1">
            Sprich bitte diesen Satz — sobald ein Mikro gewählt ist, wird automatisch
            zugehört und geprüft, ob dein Audio verständlich ankommt:
          </p>
          <blockquote class="text-base text-ink-0 font-medium italic border-l-2 border-primary pl-3 py-1">
            „{@phrase && @phrase.text}"
            <span :if={@phrase && @phrase.source != ""} class="block mt-1 text-xs text-ink-2 not-italic font-normal">
              — {@phrase.source}
            </span>
          </blockquote>
          <.vu_bar level={@local_level} class="w-full h-2" />

          <%!-- Status: lauscht / transkribiert / Treffer / daneben / Block-Fehler --%>
          <p :if={@error} class="text-xs text-danger">
            {@error}
          </p>
          <p :if={!@error and @checking} class="text-xs text-ink-2">
            Audio wird geprüft …
          </p>
          <p :if={!@error and not @checking and @phrase_ok} class="text-xs text-success">
            Phrase erkannt — Aufnahme startet …
          </p>
          <p
            :if={!@error and not @checking and not @phrase_ok and is_binary(@last_transcript)}
            class="text-xs text-warning"
          >
            <%= if @last_transcript == "" do %>
              Nichts verstanden — bitte etwas lauter und deutlicher noch einmal sprechen.
            <% else %>
              Erkannt: „{@last_transcript}" — passt noch nicht, sprich die Phrase bitte noch einmal.
            <% end %>
          </p>
          <p
            :if={!@error and not @checking and not @phrase_ok and is_nil(@last_transcript)}
            class="text-xs text-ink-2"
          >
            Höre zu … sprich die Phrase.
          </p>
          <p
            :if={@phrase_ok and @consent_required and not @consent_acked}
            class="text-xs text-warning"
          >
            Phrase erkannt — bitte oben erst die Audio-Aufnahme akzeptieren.
          </p>
        </div>

        <div class="flex justify-end pt-2">
          <.btn variant="ghost" type="button" phx-click="mic_setup_cancel">
            Abbrechen
          </.btn>
        </div>
      </div>
    </.lt_modal>
    """
  end

  # Issue #405: Silence-Watchdog-Modal nach HubWeb.MicLive verschoben.

  # Stil/Voice der Render-Prompts für diese Kampagne (#787): Slots base (Welt/
  # Setting, gilt für beide Renders) + summary/epos (Voice pro Render-Artefakt).
  # Der Stil wirkt im Render-Schritt hinter dem Verify-Gate — Extraktion ist
  # stilfrei, die Timeline deterministisch (chronik-Tab = nur Spaltentitel).
  # Issue #313: Reiterleiste (Resümee/Epos/Chronik mit default|gesetzt-Badge) +
  # farbige Inline-Prompt-Vorschau: `vorgegeben` (grau, read-only) vs.
  # `editierbar` (amber Textareas, an flavor_drafts gebunden). Speichern feuert
  # CampaignFlavorSet (Ton) + CampaignVorgabeSet (Überschrift = Spaltentitel;
  # beim Resümee zusätzlich Textsorte-Direktive im Prompt).
  attr(:campaign, :map, default: nil)
  attr(:stil_stage, :string, default: nil)
  attr(:segments, :list, default: [])
  attr(:preview_error, :any, default: nil)
  attr(:flavor_drafts, :map, default: %{})
  attr(:vorgabe_drafts, :map, default: %{})
  attr(:is_member?, :boolean, default: false)

  def flavor_editor(assigns) do
    ~H"""
    <div class="px-6 py-3 border-b border-bg-3/60 bg-bg-1/50 text-xs">
      <div class="flex items-center gap-2 mb-3">
        <span class="text-base">🎭</span>
        <span class="uppercase tracking-widest text-ink-2 text-[10px]">Stil &amp; Ausgabe pro Spalte</span>
      </div>

      <%!-- #787: summary/epos zeigen die RENDER-Prompts (aus verifizierten
           Fakten) — dort wirkt der Stil, hinter dem Verify-Gate. chronik hat
           keinen Prompt (Timeline deterministisch, #724) — der Tab setzt nur
           die Spalten-Überschrift. --%>
      <div class="flex flex-wrap gap-2 mb-3">
        <%= for stage <- ["summary", "epos", "chronik"] do %>
          <button
            type="button"
            phx-click="stil_stage"
            phx-value-stage={stage}
            class={[
              "px-3 py-1 rounded border text-[11px] transition-colors",
              (@stil_stage == stage) && "border-accent text-accent bg-accent/10" ||
                "border-bg-3 text-ink-2 hover:text-ink-1"
            ]}
          >
            {output_label(@campaign, stage)}
            <span class={[
              "ml-1 text-[9px] uppercase",
              vorgabe_set?(@campaign, stage) && "text-accent" || "text-ink-2/50"
            ]}>
              {if vorgabe_set?(@campaign, stage), do: "gesetzt", else: "default"}
            </span>
          </button>
        <% end %>
      </div>

      <%= if @stil_stage do %>
        <% name_set? = String.trim(to_string(@vorgabe_drafts["name"] || "")) != "" %>
        <% stage = @stil_stage %>
        <form phx-submit="stil_save" phx-change="stil_preview" class="flex flex-col gap-3">
          <input type="hidden" name="stage" value={stage} />

          <div class="grid gap-2 sm:grid-cols-2">
            <%!-- #787: Ton-Felder nur für die LLM-Renders — die Chronik/Timeline
                 ist deterministisch (kein Prompt, kein Stil). --%>
            <%= if stage != "chronik" do %>
              <label class="flex flex-col gap-1">
                <span class={["text-[10px] uppercase tracking-widest", slot_text_class("base")]}>Ton (allgemein)</span>
                <textarea
                  name="base"
                  rows="2"
                  maxlength="2000"
                  phx-debounce="250"
                  placeholder="Welt/Setting, Grundton — gilt für alle Spalten"
                  class={["w-full rounded px-2 py-1 text-[11px] bg-bg-0 focus:ring-0 border", slot_field_class("base")]}
                ><%= @flavor_drafts["base"] %></textarea>
              </label>

              <label class="flex flex-col gap-1">
                <span class={["text-[10px] uppercase tracking-widest", slot_text_class(stage)]}>{editable_slot_label(stage, stage)}</span>
                <textarea
                  name={stage}
                  rows="2"
                  maxlength="2000"
                  phx-debounce="250"
                  placeholder="Ton speziell für diese Spalte"
                  class={["w-full rounded px-2 py-1 text-[11px] bg-bg-0 focus:ring-0 border", slot_field_class(stage)]}
                ><%= Map.get(@flavor_drafts, stage, "") %></textarea>
              </label>
            <% end %>

            <label class="flex flex-col gap-1">
              <span class={["text-[10px] uppercase tracking-widest", slot_text_class("name")]}>Überschrift</span>
              <input
                type="text"
                name="name"
                value={@vorgabe_drafts["name"]}
                maxlength="60"
                phx-debounce="250"
                placeholder={default_output_label(stage)}
                class={["w-full rounded px-2 py-1 text-[11px] bg-bg-0 focus:ring-0 border", slot_field_class("name")]}
              />
              <%!-- #787: beim Resümee wirkt der Name als Textsorte im Prompt +
                   als Spaltentitel; bei Epos/Chronik NUR als Spaltentitel
                   (Epos-Kapitel-Kopf deterministisch #752, Timeline kein LLM). --%>
              <%= if stage != "summary" do %>
                <span class="text-ink-2/50 text-[9px]">
                  benennt nur die Spalte — {if stage == "epos",
                    do: "die Kapitel-Köpfe bleiben deterministisch",
                    else: "der Zeitstrahl selbst hat keinen Stil"}
                </span>
              <% end %>
            </label>

            <input type="hidden" name="darstellungsform" value="fliesstext" />
          </div>

          <%= if stage == "chronik" do %>
            <div class="text-ink-2/50 text-[10px]">
              Der Zeitstrahl wird deterministisch aus den verifizierten, datierten
              Fakten gebaut — es gibt keinen LLM-Prompt und keinen Ton. Nur die
              Spalten-Überschrift ist einstellbar.
            </div>
          <% else %>
            <div class="text-ink-2/50 text-[10px]">
              Live-Prompt — deine Eingaben erscheinen unten <span class="text-ink-1">in der Farbe ihres Feldes</span>; grau ist fest vorgegeben.
            </div>

            <div class="border border-bg-3/60 rounded p-3 bg-bg-0/40 text-[11px] leading-relaxed whitespace-pre-wrap text-ink-2/55">
              <%= if @preview_error do %>
                <div class="text-ink-2/60 italic mb-2">
                  Prompt-Vorschau nicht verfügbar ({inspect(@preview_error)}) — Felder lassen sich trotzdem speichern.
                </div>
              <% end %>
              <%= for seg <- @segments do %>
                <%= cond do %>
                  <% seg["kind"] == "editable" -> %>
                    <% val = if seg["slot"] == "name", do: to_string(@vorgabe_drafts["name"] || ""), else: to_string(Map.get(@flavor_drafts, seg["slot"], "")) %>
                    <%= if String.trim(val) == "" do %>
                      <span class={["italic", slot_dim_class(seg["slot"])]}>[{editable_slot_label(seg["slot"], stage)}]</span>
                    <% else %>
                      <span class={["font-medium", slot_text_class(seg["slot"])]}>{val}</span>
                    <% end %>
                  <% seg["kind"] == "heading_frame" -> %>
                    <span :if={name_set?}>{seg["text"]}</span>
                  <% true -> %>
                    <span>{seg["text"]}</span>
                <% end %>
              <% end %>
            </div>
          <% end %>

          <div class="flex justify-end gap-2">
            <.btn variant="ghost" type="button" phx-click="stil_close">Schließen</.btn>
            <%= if @is_member? do %>
              <.btn variant="primary" icon="check" type="submit">Speichern</.btn>
            <% end %>
          </div>
        </form>
      <% else %>
        <p class="text-ink-2/60 italic text-[11px]">
          Wähle oben eine Spalte: links die farbigen Eingabefelder (Ton, Überschrift,
          Darstellung), darunter der vollständige Prompt — deine Eingaben werden live
          in der Farbe ihres Feldes eingeblendet, grau ist fest vorgegeben.
        </p>
      <% end %>
    </div>
    """
  end
end
