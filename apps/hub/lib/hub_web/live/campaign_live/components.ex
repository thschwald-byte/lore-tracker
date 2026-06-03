defmodule HubWeb.CampaignLive.Components do
  @moduledoc """
  Function-Components + reine Präsentations-/Formatierungs-Helfer der
  `HubWeb.CampaignLive` (Issue #434, Cut 2).

  Reine View-Schicht: keine Funktion hier mutiert `socket` oder löst Events aus.
  `HubWeb.CampaignLive` importiert dieses Modul (für das colocated
  `campaign_live.html.heex`-Template und die Logik-seitig geteilten pure Helfer
  wie `display_for/2`, `render_md/1`, `faithfulness_index/2`). Deshalb darf hier
  KEINE Funktion aus `HubWeb.CampaignLive` aufgerufen werden — das wäre ein
  Import-Zirkel.
  """
  use HubWeb, :html

  # Duplikat von HubWeb.CampaignLive.@col_names (~w(chronik epos summaries
  # protokoll)). `can_collapse?/2` braucht die Spaltenanzahl. In CampaignLive
  # bleibt es zusätzlich als Compile-Literal stehen, weil der col_toggle-Guard
  # (`when col in @col_names`) keinen Funktionsaufruf erlaubt. Wert-Sync halten.
  @col_names ~w(chronik epos summaries protokoll)

  # Issue #313: Ausgabe-Überschrift pro Stage — aus der Vorgabe oder Default.
  def default_output_label("summary"), do: "Resümee"
  def default_output_label("epos"), do: "Epos"
  def default_output_label("chronik"), do: "Chronik"
  def default_output_label(_), do: ""

  def output_label(campaign, stage) do
    case get_in(campaign || %{}, ["vorgaben", stage, "name"]) do
      n when is_binary(n) and n != "" -> n
      _ -> default_output_label(stage)
    end
  end

  # „gesetzt" = eigener Name ODER abweichende Darstellungsform (nicht default).
  def vorgabe_set?(campaign, stage) do
    v = get_in(campaign || %{}, ["vorgaben", stage]) || %{}
    name_set = is_binary(v["name"]) and v["name"] != ""

    form_set =
      is_binary(v["darstellungsform"]) and v["darstellungsform"] not in ["", "fliesstext"]

    name_set or form_set
  end

  def editable_slot_label("base", _stage), do: "Ton (allgemein)"
  def editable_slot_label("name", _stage), do: "Überschrift"
  def editable_slot_label(slot, _stage), do: "Ton (#{default_output_label(slot)})"

  # Issue #320: feste Farbe pro Stil-Feld — das Eingabefeld und die Live-
  # Einblendung im Prompt teilen dieselbe Farbe, damit man Feld↔Position im
  # Prompt zuordnen kann. base=cyan, Stage-Ton=grün, Überschrift=amber.
  # Klassen als Literale, damit Tailwinds JIT sie generiert.
  def slot_field_class("base"),
    do: "text-primary border-primary/60 bg-primary/10 focus:border-primary"

  def slot_field_class("name"),
    do: "text-warning border-warning/60 bg-warning/10 focus:border-warning"

  def slot_field_class(_),
    do: "text-success border-success/60 bg-success/10 focus:border-success"

  def slot_text_class("base"), do: "text-primary"
  def slot_text_class("name"), do: "text-warning"
  def slot_text_class(_), do: "text-success"

  def slot_dim_class("base"), do: "text-primary/40"
  def slot_dim_class("name"), do: "text-warning/40"
  def slot_dim_class(_), do: "text-success/40"

  # Issue #291: Markdown → HTML für Resümee/Epos/Chronik-Anzeige.
  # LLM-Output ist intern → escape: false (Earmark gibt semantisches HTML).
  # Bei Parse-Warnings liefert Earmark trotzdem brauchbares HTML, daher
  # akzeptieren wir auch :error-Variante.
  def render_md(nil), do: ""
  def render_md(""), do: ""

  def render_md(text) when is_binary(text) do
    case Earmark.as_html(text, escape: false) do
      {:ok, html, _} -> Phoenix.HTML.raw(html)
      {:error, html, _} -> Phoenix.HTML.raw(html)
    end
  end

  @doc """
  Issue #385: Markdown → HTML für **user-editierten** Inhalt (Chronik-Body).
  Defense-in-Depth: `escape: true` neutralisiert literales HTML schon vor
  dem Sanitizer (z.B. `<script>` wird zu `&lt;script&gt;` bevor
  HtmlSanitizeEx es sieht), HtmlSanitizeEx.basic_html/1 ist die zweite
  Schicht.

  Wichtig: bewusst NICHT `render_md/1` benutzen — der nutzt `escape: false`
  für deterministischen LLM-Output, was bei User-Input gefährlich wäre.
  """
  def render_md_safe(nil), do: ""
  def render_md_safe(""), do: ""

  def render_md_safe(text) when is_binary(text) do
    html =
      case Earmark.as_html(text, escape: true) do
        {:ok, h, _} -> h
        {:error, h, _} -> h
      end

    html
    |> HtmlSanitizeEx.basic_html()
    |> Phoenix.HTML.raw()
  end

  # Issue #291: gestripptes Plain-Text für Vorschauen mit line-clamp (Chronik).
  # Überschriften/Listen-Marker/Inline-Marker raus, damit die 3-Zeilen-Vorschau
  # nicht „# …" oder „**…**" zeigt.
  def strip_md(nil), do: ""

  def strip_md(text) when is_binary(text) do
    text
    |> String.replace(~R/^\s*#{1,6}\s+/m, "")
    |> String.replace(~r/^\s*[->]\s+/m, "")
    |> String.replace(~r/^\s*[*+]\s+/m, "")
    |> String.replace(~r/\*\*([^*]+)\*\*/, "\\1")
    |> String.replace(~r/\*([^*]+)\*/, "\\1")
    |> String.replace(~r/_([^_]+)_/, "\\1")
    |> String.replace(~r/`([^`]+)`/, "\\1")
    |> String.replace(~r/\[([^\]]+)\]\([^)]+\)/, "\\1")
  end

  # Issue #291: Tailwind-Arbitrary-Variants stylen das gerenderte Markdown
  # ohne @tailwindcss/typography-Plugin. Klassen sind literal → JIT erkennt sie.
  def prose_classes do
    "[&_h1]:text-base [&_h1]:font-semibold [&_h1]:mt-3 [&_h1]:mb-1 " <>
      "[&_h2]:text-sm [&_h2]:font-semibold [&_h2]:mt-2 [&_h2]:mb-1 " <>
      "[&_h3]:text-sm [&_h3]:font-medium [&_h3]:mt-2 [&_h3]:mb-1 " <>
      "[&_p]:my-1 [&_strong]:font-semibold [&_em]:italic " <>
      "[&_ul]:list-disc [&_ul]:pl-5 [&_ul]:my-1 " <>
      "[&_ol]:list-decimal [&_ol]:pl-5 [&_ol]:my-1 " <>
      "[&_li]:my-0.5 " <>
      "[&_blockquote]:border-l-2 [&_blockquote]:border-bg-3/60 [&_blockquote]:pl-3 [&_blockquote]:italic [&_blockquote]:text-ink-2 [&_blockquote]:my-1 " <>
      "[&_code]:bg-bg-0/60 [&_code]:px-1 [&_code]:rounded [&_code]:text-[11px] " <>
      "[&_a]:text-accent [&_a]:underline"
  end

  # Resolve a Discord-ID → display name using the snapshot's `users` map.
  # New shape (Issue #6): %{discord_id => %{"display_name" => name, "avatar_url" => url}}.
  # Falls back to raw id if no record exists yet (e.g. legacy campaigns
  # pre-dating the owner-upsert fix).
  def display_for(discord_id, users) when is_map(users) do
    case Map.get(users, discord_id) do
      # Issue #57: User wurde gelöscht (oder hat sich noch nie eingeloggt).
      # Audit-Trail bleibt erhalten, aber wir zeigen statt der Discord-ID
      # einen sichtbaren Placeholder-Text.
      %{"deleted" => true} -> "[gelöschter User]"
      %{"display_name" => name} when is_binary(name) -> name
      # Tolerate the old flat-string format during the deploy roll-over.
      name when is_binary(name) -> name
      _ -> discord_id
    end
  end

  def display_for(discord_id, _), do: discord_id

  # `speaker:<sid>:3` → "Sprecher 4" (1-basiert für die Anzeige).
  def pseudo_speaker_label(did) do
    case did |> to_string() |> String.split(":") |> List.last() |> Integer.parse() do
      {n, _} -> "Sprecher #{n + 1}"
      :error -> "Sprecher ?"
    end
  end

  # Issue #2: character-name takes precedence over both display_name and
  # raw discord_id. Used in places where the per-campaign alias should win:
  # mainly the Mitspieler-Pill + Protokoll/Mic-Streamer rendering.
  def display_for(discord_id, users, char_names)
      when is_map(users) and is_map(char_names) do
    case Map.get(char_names, discord_id) do
      name when is_binary(name) and name != "" -> name
      _ -> display_for(discord_id, users)
    end
  end

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
  # Issue #317: mode-aware. Im :single_source-Modus (Raummikro) werden drei
  # zusätzliche Absätze gerendert, die die Aufnahme-Dritter-, Diarisierungs-
  # und SL-Verantwortungs-Punkte klarstellen. Akzeptieren in diesem Modus
  # speichert Version "v2", die auch den Per-Spieler-Pfad (v1) mit abdeckt.
  # `assigns.mode` ist :per_player | :single_source | nil — nil fällt auf den
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
            <p :if={@consent_mode == :single_source} class="text-ink-0">
              Du startest gleich den <strong>Raummikro-Modus</strong>: <strong>eine</strong>
              Audioquelle (dein Gerät) nimmt den ganzen Tisch auf — du nimmst damit
              auch andere Anwesende mit auf.
            </p>
            <p :if={@consent_mode != :single_source}>
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
              <li :if={@consent_mode != :single_source}>
                Du kannst deine eigenen Utterances jederzeit in der
                Protokoll-Spalte editieren oder löschen. Eine ganze Session
                löscht der Spielleiter über die Kampagne.
              </li>
              <li :if={@consent_mode == :single_source}>
                Die Aufnahme wird im Worker <strong>post-session per Diarisierung
                automatisch nach Stimmen getrennt</strong>
                und Pseudo-Sprechern zugewiesen. Du als Spielleiter ordnest die
                Pseudo-Sprecher danach in der UI echten Kampagnen-Mitgliedern zu.
              </li>
              <li :if={@consent_mode == :single_source}>
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
            <span :if={@consent_mode == :single_source}>
              Ich habe die Punkte gelesen, habe das Einverständnis der Mitspieler
              eingeholt und stimme der Aufnahme zu.
            </span>
            <span :if={@consent_mode != :single_source}>
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

  # Stil/Voice der LLM-Stages für diese Kampagne. 4 Slots: base (Welt/
  # Setting) + summary/epos/chronik (Voice/Persona pro Spalte). Member-
  # editierbar. Collapsed-View zeigt eine schmale Status-Zeile, Expanded
  # öffnet 4 Textareas als Akkordeon.
  # Issue #313: Stil-Editor pro Stage. Reiterleiste (Resümee/Epos/Chronik mit
  # default|gesetzt-Badge) + farbige Inline-Prompt-Vorschau: `vorgegeben`
  # (grau, read-only) vs. `editierbar` (amber Textareas, an flavor_drafts
  # gebunden). Speichern feuert CampaignFlavorSet (Ton) + CampaignVorgabeSet
  # (Name/Darstellung).
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

      <div class="flex flex-wrap gap-2 mb-3">
        <%= for stage <- ["chronik", "epos", "summary"] do %>
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
            </label>

            <%= if stage == "epos" do %>
              <label class="flex flex-col gap-1">
                <span class="text-ink-2 text-[10px] uppercase tracking-widest">Darstellung</span>
                <select
                  name="darstellungsform"
                  class="bg-bg-0 border border-bg-3 rounded px-2 py-1 text-[11px] text-ink-0 focus:border-accent focus:ring-0"
                >
                  <option value="fliesstext" selected={@vorgabe_drafts["darstellungsform"] != "stichpunkte"}>
                    Fließtext
                  </option>
                  <option value="stichpunkte" selected={@vorgabe_drafts["darstellungsform"] == "stichpunkte"}>
                    Stichpunkte
                  </option>
                </select>
              </label>
            <% else %>
              <input type="hidden" name="darstellungsform" value="fliesstext" />
            <% end %>
          </div>

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

  # Owner-only Danger-Zone: Kampagne löschen mit Name-Bestätigung. Cascade
  # läuft im Worker-Materializer (CampaignDeleted-Event).
  attr(:campaign_name, :string, required: true)
  attr(:confirming?, :boolean, default: false)
  attr(:typed, :string, default: "")

  def delete_zone(assigns) do
    ~H"""
    <div class="px-6 py-2 border-b border-bg-3/60 bg-bg-1/30 text-xs">
      <%= cond do %>
        <% @confirming? -> %>
          <form phx-submit="campaign_delete_confirm" phx-change="campaign_delete_typing" class="flex flex-col gap-2">
            <div class="flex items-center gap-2 text-rec-soft">
              <span class="text-base">⚠</span>
              <span class="uppercase tracking-widest text-[10px]">
                Kampagne unwiderruflich löschen
              </span>
              <span class="text-ink-2/70 text-[10px]">
                — alle Sessions, Protokolle, Resümees, Epos, Chronik werden mit gelöscht
              </span>
            </div>
            <div class="flex items-center gap-2">
              <span class="text-ink-2 text-[10px]">
                Tippe den Kampagnennamen zur Bestätigung: <code class="text-rec-soft">{@campaign_name}</code>
              </span>
            </div>
            <div class="flex gap-2 items-center">
              <input
                type="text"
                name="name"
                value={@typed}
                autocomplete="off"
                class="flex-1 bg-bg-0 border border-bg-3 rounded px-2 py-1 text-xs text-ink-0 focus:border-accent focus:ring-0 font-mono"
                placeholder={@campaign_name}
              />
              <.btn variant="ghost" phx-click="campaign_delete_cancel">Abbrechen</.btn>
              <.btn
                variant="danger"
                icon="trash"
                type="submit"
                disabled={String.trim(@typed) != @campaign_name}
              >
                Endgültig löschen
              </.btn>
            </div>
          </form>
        <% true -> %>
          <div class="flex items-center gap-2 justify-end">
            <.ls_icon_btn_compat
              kind={:cascade_delete}
              size={:md}
              phx-click="campaign_delete_request"
              title="Kampagne mit allen Einträgen unwiderruflich löschen"
            />
          </div>
      <% end %>
    </div>
    """
  end

  def recording_bar(assigns) do
    ~H"""
    <div class="flex items-center gap-3 px-6 py-3 bg-bg-1 border-b border-bg-3/60">
      <%= case rec_state(@active_session) do %>
        <% :recording -> %>
          <.ls_icon_btn_compat kind={:rec_pause} size={:md} phx-click="rec_pause" disabled={not @owner?} title="Aufnahme pausieren" />
          <.ls_icon_btn_compat kind={:rec_stop} size={:lg} phx-click="rec_stop" disabled={not @owner?} title="Aufnahme stoppen" />
          <.ls_icon_btn_compat kind={:marker} size={:md} phx-click="rec_marker" disabled={not @owner?} title="Szenen-Marker setzen" />
          <span class="ml-2 text-rec-soft text-xs uppercase tracking-widest">● Aufnahme läuft</span>
        <% :paused -> %>
          <.ls_icon_btn_compat kind={:rec_resume} size={:lg} phx-click="rec_resume" disabled={not @owner?} title="Aufnahme fortsetzen" />
          <.ls_icon_btn_compat kind={:rec_stop} size={:lg} phx-click="rec_stop" disabled={not @owner?} title="Aufnahme stoppen" />
          <.ls_icon_btn_compat kind={:marker} size={:md} phx-click="rec_marker" disabled={not @owner?} title="Szenen-Marker setzen" />
          <span class="ml-2 text-ink-2 text-xs uppercase tracking-widest">|| Pause</span>
        <% _ -> %>
          <.ls_icon_btn_compat
            kind={:rec_start}
            size={:lg}
            phx-click="rec_start"
            disabled={not @owner?}
            title="Aufnahme starten — pro Spieler eigenes Mikro"
          />
          <.btn
            :if={@owner?}
            phx-click="rec_single_start"
            title="Ein Raummikrofon für alle: startet Aufnahme UND Mikro in einem Klick. Sprecher werden nach der Session automatisch getrennt."
          >
            🎙 Raummikro starten
          </.btn>
          <span class="ml-2 text-ink-2 text-xs uppercase tracking-widest">○ Keine aktive Session</span>
      <% end %>
      <div class="flex-1"></div>
      <.mic_controls
        active_session={@active_session}
        mic_on?={@mic_on?}
        recording_here?={@recording_here?}
        mic_streamers={@mic_streamers}
        mic_levels={@mic_levels}
        current_discord_id={@current_discord_id}
        users={@users}
      />
      <span class="text-xs text-ink-2 font-mono">{elapsed(@active_session)}</span>
      <button
        id="col-sync-toggle-btn"
        type="button"
        title="Referenzen"
        class="inline-flex items-center justify-center w-8 h-8 rounded-md border border-white/10 text-fg bg-transparent hover:bg-surface-2 hover:text-primary transition-colors duration-150 text-xs font-mono font-bold"
      >
        R
      </button>
      <%= if @owner? do %>
        <.ls_icon_btn_compat
          kind={:power}
          size={:sm}
          phx-click="shutdown_worker"
          data-confirm="Worker wirklich herunterfahren?"
          title="Worker herunterfahren"
        />
      <% end %>
    </div>
    """
  end

  # Issue #415: Drei-Wege-Mikro-Button.
  #   :stop     — DIESER Browser nimmt gerade auf (recording_here?).
  #   :takeover — der Account nimmt auf einem ANDEREN Gerät auf (in Streamer-
  #               Liste, aber nicht hier) → „Hier übernehmen".
  #   :join     — niemand auf diesem Account nimmt auf → normal beitreten.
  # recording_here? hat Vorrang: lokales Recording schlägt die Streamer-Liste,
  # damit das aufnehmende Gerät nie fälschlich „übernehmen" zeigt.
  @doc false
  def mic_button_state(recording_here?, current_discord_id, mic_streamers) do
    cond do
      recording_here? -> :stop
      current_discord_id in (mic_streamers || []) -> :takeover
      true -> :join
    end
  end

  def mic_controls(assigns) do
    ~H"""
    <%= if @active_session do %>
      <div class="flex items-center gap-2">
        <span class="text-xs text-ink-2 font-mono">
          🎙 {length(@mic_streamers)} streamen
        </span>
        <%!-- Issue #391: pro Streamer Name + Live-VU-Bar. --%>
        <span
          :for={did <- @mic_streamers}
          class="flex items-center gap-1 text-[10px] text-ink-2 font-mono"
          title={display_for(did, @users)}
        >
          <span class="truncate max-w-[8rem]">{display_for(did, @users)}</span>
          <.vu_bar level={Map.get(@mic_levels, did, 0.0)} class="w-10" />
        </span>
        <%!-- Issue #415: Drei-Wege. recording_here? = DIESER Browser nimmt auf
              (browser-lokal, MicCapture-Hook). Account in Streamer-Liste, aber
              nicht hier → Aufnahme läuft auf einem anderen Gerät → „Hier
              übernehmen" (mic_join; der Supersede-Broadcast stoppt das andere
              Gerät beim Start). --%>
        <%= case mic_button_state(@recording_here?, @current_discord_id, @mic_streamers) do %>
          <% :stop -> %>
            <.ls_icon_btn_compat kind={:mic_off} size={:md} phx-click="mic_leave" title="Mein Mikro stoppen" />
          <% :takeover -> %>
            <.btn phx-click="mic_join" title="Aufnahme von deinem anderen Gerät hierher übernehmen">
              ⇄ Hier übernehmen
            </.btn>
          <% :join -> %>
            <.ls_icon_btn_compat kind={:mic_on} size={:md} phx-click="mic_join" title="Mit Mikro beitreten" />
        <% end %>
      </div>
    <% end %>
    """
  end

  # ─── Epos column ───────────────────────────────────────────────

  def epos_column(assigns) do
    ~H"""
    <%= if @collapsed? do %>
      <.collapsed_strip name="epos" title={@title} busy?={@busy?} />
    <% else %>
    <div class="bg-bg-1 flex flex-col min-h-0 flex-1 min-w-0 transition-all duration-200">
      <div class="col-header">
        <span class="flex items-center gap-2">
          {@title}
          <.busy_dot show?={@busy?} />
        </span>
        <span class="flex items-center gap-2">
        <%= cond do %>
          <% @can_edit? and @epos_mode == :view -> %>
            <.ls_icon_btn_compat kind={:edit} size={:sm} phx-click="epos_edit_start" title="Epos bearbeiten" />
          <% @epos_mode == :edit -> %>
            <span class="text-ink-2 text-[10px] font-sans normal-case tracking-normal">Bearbeitet…</span>
          <% true -> %>
            <span class="text-ink-2 text-[10px] font-sans normal-case tracking-normal">Main Campaign Book</span>
        <% end %>
          <.collapse_chevron name="epos" can_collapse?={@can_collapse?} direction={:close} />
        </span>
      </div>

      <div class="flex-1 overflow-y-auto p-4 scroll-smooth" data-col="epos">
        <%!-- Issue #370: 40vh Top-Spacer + Bottom-Spacer (siehe column-Component). --%>
        <div class="h-[40vh]" aria-hidden="true"></div>
        <%= cond do %>
          <% @waiting? and is_nil(@epos) -> %>
            <p class="text-ink-2 text-sm italic">Warte auf Worker.</p>
          <% @epos_mode == :diff -> %>
            <.epos_diff history={@epos_history} target_seq={@epos_diff_seq} current={@epos} />
          <% @epos_mode == :edit -> %>
            <form phx-submit="epos_edit_save" class="space-y-2">
              <textarea
                name="content_md"
                class="w-full h-72 bg-bg-0 border border-bg-3 rounded p-2 text-sm font-mono text-ink-0 focus:border-accent focus:ring-0"
                phx-update="ignore"
                id="epos-textarea"
              ><%= @epos_draft %></textarea>
              <div class="flex justify-end gap-2">
                <.ls_icon_btn_compat kind={:cancel} size={:md} phx-click="epos_edit_cancel" title="Abbrechen" />
                <.ls_icon_btn_compat kind={:confirm} size={:md} type="submit" title="Speichern" />
              </div>
            </form>
          <% @epos == nil or @epos["content_md"] in [nil, ""] -> %>
            <p class="text-ink-2 text-sm italic">
              Noch leer.<%= if @can_edit?, do: " Klick 'Bearbeiten' oben.", else: "" %>
            </p>
            <.epos_history_section history={@epos_history} />
          <% true -> %>
            <article class={["text-ink-0 text-sm leading-relaxed", prose_classes()]} data-anchor-id={@epos["id"]}>{render_md(@epos["content_md"])}</article>
            <.epos_history_section history={@epos_history} />
        <% end %>
        <div class="h-[40vh]" aria-hidden="true"></div>
      </div>
    </div>
    <% end %>
    """
  end

  def epos_history_section(assigns) do
    ~H"""
    <%= if @history != [] do %>
      <div class="mt-6 pt-3 border-t border-bg-3/60">
        <div class="uppercase tracking-widest text-ink-2 text-[10px] mb-2">Versionen</div>
        <ul class="space-y-1">
          <%= for h <- @history do %>
            <li class="flex items-baseline gap-2 text-xs">
              <span class="font-mono text-ink-2">#{h["seq"]}</span>
              <span class="text-ink-1">{format_ts(h["edited_at"])}</span>
              <span class={["pill", source_pill(h["source"])]}>
                {h["source"] || "?"}
              </span>
              <.ls_icon_btn_compat
                kind={:diff}
                size={:sm}
                phx-click="epos_diff_open"
                phx-value-seq={h["seq"]}
                title="Diff zur aktuellen Version"
                class="ml-auto"
              />
            </li>
          <% end %>
        </ul>
      </div>
    <% end %>
    """
  end

  def epos_diff(assigns) do
    current_md = (assigns.current && assigns.current["content_md"]) || ""

    target =
      Enum.find(assigns.history, fn h -> h["seq"] == assigns.target_seq end)

    target_md = (target && target["content_md"]) || ""

    diff =
      List.myers_difference(
        String.split(target_md, "\n"),
        String.split(current_md, "\n")
      )

    assigns = assign(assigns, diff: diff, target: target)

    ~H"""
    <div class="space-y-3">
      <div class="flex items-baseline justify-between">
        <h3 class="font-display text-sm tracking-wide">
          Diff: #{(@target && @target["seq"]) || "?"} → current
        </h3>
        <.ls_icon_btn_compat kind={:cancel} size={:sm} phx-click="epos_diff_close" title="Zurück zur Epos-Ansicht" />
      </div>
      <div class="text-xs font-mono bg-bg-0 border border-bg-3 rounded p-3 overflow-x-auto whitespace-pre">
        <%= for {op, lines} <- @diff, line <- lines do %>
          <div class={diff_line_class(op)}>{diff_prefix(op)}{line}</div>
        <% end %>
      </div>
    </div>
    """
  end

  def diff_line_class(:eq), do: "text-fg-muted"
  def diff_line_class(:del), do: "text-danger bg-danger/10"
  def diff_line_class(:ins), do: "text-success bg-success/10"

  def diff_prefix(:eq), do: "  "
  def diff_prefix(:del), do: "- "
  def diff_prefix(:ins), do: "+ "

  def source_pill("manual"), do: "pill-archived"
  def source_pill("llm"), do: "pill-new"
  def source_pill(_), do: ""

  # ─── Faithfulness (Issue #11 Phase 2) ─────────────────────────
  # Score-Map nach session_id für O(1)-Lookup im Template.
  def faithfulness_index(list) when is_list(list) do
    Enum.into(list, %{}, fn entry -> {entry["session_id"], entry} end)
  end

  def faithfulness_index(_), do: %{}

  def faithfulness_label(score) when is_number(score) do
    pct = round(score * 100)
    "📊 #{pct}%"
  end

  def faithfulness_label(_), do: "📊 –"

  def faithfulness_pill_class(score) when is_number(score) and score >= 0.8,
    do: "bg-success/20 text-success border border-success/40"

  def faithfulness_pill_class(score) when is_number(score) and score >= 0.5,
    do: "bg-warning/20 text-warning border border-warning/40"

  def faithfulness_pill_class(score) when is_number(score),
    do: "bg-danger/20 text-danger border border-danger/40"

  def faithfulness_pill_class(_), do: "bg-surface-2/40 text-fg-muted"

  def faithfulness_claim_dot("entailment"), do: "bg-success"
  def faithfulness_claim_dot("contradiction"), do: "bg-danger"
  def faithfulness_claim_dot(_), do: "bg-warning"

  # ─── Helpers ──────────────────────────────────────────────────

  def rec_state(nil), do: :idle
  def rec_state(%{status: status}), do: status

  def elapsed(%{started_at: started}) when not is_nil(started) do
    started_dt =
      case started do
        s when is_binary(s) ->
          case DateTime.from_iso8601(s) do
            {:ok, dt, _} -> dt
            _ -> nil
          end

        %DateTime{} = dt ->
          dt
      end

    case started_dt do
      nil ->
        "00:00:00"

      dt ->
        secs = DateTime.diff(DateTime.utc_now(), dt)
        h = div(secs, 3600)
        m = rem(div(secs, 60), 60)
        s = rem(secs, 60)

        :io_lib.format("~2..0B:~2..0B:~2..0B", [h, m, s])
        |> IO.iodata_to_binary()
    end
  end

  def elapsed(_), do: "00:00:00"

  def format_ts(nil), do: "--:--:--"

  def format_ts(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> Calendar.strftime(dt, "%H:%M:%S")
      _ -> iso
    end
  end

  def protokoll_subtitle(nil), do: "Transkript"
  def protokoll_subtitle(%{number: n}), do: "Session #{n} · Transkript"

  # Issue #8: ein Toggle ist erlaubt wenn die Spalte schon zu ist (Aufklappen
  # geht immer) oder wenn nach dem Einklappen noch mind. eine andere offen
  # bleibt.
  def can_collapse?(collapsed_cols, name) do
    MapSet.member?(collapsed_cols, name) or
      MapSet.size(collapsed_cols) < length(@col_names) - 1
  end

  # Returns [{session_label, [utterance, ...]}, ...] preserving the order in
  # which session_ids first appear in `utterances` (i.e. chronological).
  def group_by_session(utterances, sessions) do
    sess_by_id =
      Enum.into(sessions || [], %{}, fn s -> {s["id"], s} end)

    utterances
    |> Enum.chunk_by(& &1["session_id"])
    |> Enum.map(fn group ->
      sid = List.first(group)["session_id"]
      {session_label(sess_by_id[sid], sid), group}
    end)
  end

  def session_label(nil, sid), do: "Session ?? · #{String.slice(sid || "", 0, 8)}"

  def session_label(%{"number" => n, "name" => name}, _sid) when is_binary(name) and name != "",
    do: "Session #{n} · #{name}"

  def session_label(%{"number" => n}, _sid), do: "Session #{n}"

  def highest_session(sessions) do
    sessions
    |> Enum.reject(&is_nil(&1["number"]))
    |> Enum.max_by(& &1["number"], fn -> nil end)
  end

  attr(:name, :string, required: true)
  attr(:title, :string, required: true)
  attr(:subtitle, :string, default: "")
  attr(:busy?, :boolean, default: false)
  attr(:collapsed?, :boolean, default: false)
  attr(:can_collapse?, :boolean, default: true)
  slot(:inner_block, required: true)

  def column(assigns) do
    ~H"""
    <%= if @collapsed? do %>
      <.collapsed_strip name={@name} title={@title} busy?={@busy?} />
    <% else %>
      <div class="bg-bg-1 flex flex-col min-h-0 flex-1 min-w-0 transition-all duration-200">
        <div class="col-header">
          <span class="flex items-center gap-2">
            {@title}
            <.busy_dot show?={@busy?} />
          </span>
          <span class="flex items-center gap-2">
            <%= if @subtitle != "" do %>
              <span class="text-ink-2 text-[10px] font-sans normal-case tracking-normal">
                {@subtitle}
              </span>
            <% end %>
            <.collapse_chevron name={@name} can_collapse?={@can_collapse?} direction={:close} />
          </span>
        </div>
        <div class="flex-1 overflow-y-auto p-4 scroll-smooth" data-col={@name}>
          <%!-- Issue #370: 40vh Top/Bottom-Padding damit das erste/letzte
               Item bis in die Container-Mitte gescrollt werden kann
               (Sync-Anker greift auf Center-Y). --%>
          <div class="h-[40vh]" aria-hidden="true"></div>
          {render_slot(@inner_block)}
          <div class="h-[40vh]" aria-hidden="true"></div>
        </div>
      </div>
    <% end %>
    """
  end

  # Schmaler vertikaler Strip für eingeklappte Spalten (Issue #8).
  attr(:name, :string, required: true)
  attr(:title, :string, required: true)
  attr(:busy?, :boolean, default: false)

  def collapsed_strip(assigns) do
    ~H"""
    <div class="bg-bg-1 flex flex-col items-center justify-between py-2 w-10 transition-all duration-200 border-l border-bg-3/40">
      <.ls_icon_btn_compat
        kind={:expand}
        size={:sm}
        phx-click="col_toggle"
        phx-value-col={@name}
        title="Spalte aufklappen"
      />
      <span class="flex-1 flex items-center justify-center">
        <span
          class="text-ink-1 text-xs uppercase tracking-widest font-display"
          style="writing-mode: vertical-rl; transform: rotate(180deg);"
        >
          {@title}
        </span>
      </span>
      <.busy_dot show?={@busy?} />
    </div>
    """
  end

  attr(:name, :string, required: true)
  attr(:can_collapse?, :boolean, default: true)
  attr(:direction, :atom, values: [:close, :open], default: :close)

  def collapse_chevron(assigns) do
    ~H"""
    <.ls_icon_btn_compat
      kind={if @direction == :close, do: :collapse, else: :expand}
      size={:sm}
      phx-click="col_toggle"
      phx-value-col={@name}
      disabled={not @can_collapse?}
      title={if @direction == :close, do: "Spalte einklappen", else: "Spalte aufklappen"}
    />
    """
  end

  attr(:show?, :boolean, default: false)

  def busy_dot(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center gap-1 text-[10px] font-sans uppercase tracking-wide transition-opacity",
      not @show? && "opacity-0"
    ]}>
      <span class="relative flex h-2 w-2">
        <span class="animate-ping absolute inline-flex h-full w-full rounded-full bg-accent opacity-75"></span>
        <span class="relative inline-flex rounded-full h-2 w-2 bg-accent"></span>
      </span>
      <span class="text-accent">LLM</span>
    </span>
    """
  end

  def empty_col(assigns) do
    ~H"""
    <p class="text-ink-2 text-sm italic">{@text}</p>
    """
  end

  # ─── Issue #379/#381: Utterance-Status + ASR-Confidence-Helpers ───
  # Public defs damit Tests sie reflexiv aufrufen können.

  @uncertainty_threshold 0.5
  @low_token_fraction_threshold 0.2

  @doc """
  Issue #379/#381: flaggt eine Utterance als ASR-unsicher.

  ## Vier-Fälle-Matrix (Status × Confidence-Format × Origin)

  | Fall              | Confidence-Map                    | Schutzmechanismus          |
  |-------------------|-----------------------------------|----------------------------|
  | neu-real          | `low_token_fraction>0.2, n>0`     | Primary feuert             |
  | neu-Platzhalter   | `low_token_fraction=0, n=0`       | `n > 0`-Guard im Primary   |
  | alt-real          | nur `mean_p`+`min_p`, `min_p<0.5` | Fallback feuert via `p≠m`  |
  | alt-Platzhalter   | `mean_p == min_p`, kein neues Fld | Fallback `p != m` greift   |

  Drei verschiedene Schutzmechanismen — nicht zu einem vereinfachen,
  sonst kippt einer der vier Fälle. Status-Gate (`confirmed`/`live`)
  liegt unabhängig davon vor beiden Pfaden.

  ## Caveats

  - **Kurzes-Ende-Bias (v1):** bei sehr kleinem `token_count` (n<8) ist
    `low_token_fraction` grob (z.B. N=2 → nur 0/0.5/1.0 möglich) und
    über-sensitiv für Clip-Rand-Tokens. Adressierbar später via
    `n >= N_min`-Guard, sobald Real-Data zeigt wie oft das auftritt.
  - **Eingefrorenes Aggregat:** das Worker-Setting
    `:confidence_low_token_threshold` wird zur Transkriptionszeit
    eingelesen. Späteres Drehen wirkt nur auf neue Utterances.
  - **Zwei-dimensionales Tuning:** Per-Token (Worker, 0.5) × Fraction
    (Hub, 0.2) — beide im Blick haben beim Tunen.
  """
  @spec asr_uncertain?(map()) :: boolean

  # Primary: neue längen-normalisierte Metrik (Issue #381)
  def asr_uncertain?(%{
        "status" => s,
        "confidence" => %{"low_token_fraction" => f, "token_count" => n}
      })
      when s in ["confirmed", "live"] and is_number(f) and is_integer(n) and n > 0 do
    f > @low_token_fraction_threshold
  end

  # Fallback: alte Utts ohne low_token_fraction-Feld (vor #381)
  def asr_uncertain?(%{
        "status" => s,
        "confidence" => %{"min_p" => p, "mean_p" => m} = c
      })
      when s in ["confirmed", "live"] and is_number(p) and is_number(m) do
    not Map.has_key?(c, "low_token_fraction") and p < @uncertainty_threshold and p != m
  end

  def asr_uncertain?(_), do: false

  @doc """
  Tooltip-Text für den ASR-Unsicherheits-Flag. Framt bewusst als
  „Modell-Unsicherheit" (nicht „Fehler"), weil low-confidence-Tokens
  häufig seltene-aber-korrekte Eigennamen oder Schnitt-Ränder sind
  (siehe #376-Review-Diskussion). Zwei Varianten — Fraction-basiert
  (Issue #381) und Fallback (min_p, mit Längen-Bias-Caveat).
  """
  @spec uncertainty_tooltip(map()) :: String.t()

  # Issue #381: Fraction-basiert. Kurz-Ende-Caveat bei n<8.
  def uncertainty_tooltip(%{"confidence" => %{"low_token_fraction" => f, "token_count" => n}})
      when is_number(f) and is_integer(n) and n > 0 do
    short_caveat =
      if n < 8,
        do:
          " Hinweis: kurze Utterances (n<8) sind anfällig für Clip-Rand-Tokens — Fraction-Aussage hier grob.",
        else: ""

    "ASR-Unsicherheit — #{round(f * 100)}% der #{n} Tokens unter Konfidenz-Schwelle. " <>
      "Häufig bei seltenen Eigennamen, Schnitträndern oder leiser Sprache — kein Fehler-Marker." <>
      short_caveat
  end

  # Fallback (alte Utts ohne neue Felder): min_p mit Längen-Bias-Hinweis.
  def uncertainty_tooltip(%{"confidence" => %{"min_p" => p, "mean_p" => m}})
      when is_number(p) and is_number(m) do
    "ASR-Unsicherheit — niedrigste Token-Konfidenz #{Float.round(p, 2)} (mean #{Float.round(m, 2)}). " <>
      "Hinweis: alte Aggregation, lange Utts flaggen statistisch häufiger."
  end

  def uncertainty_tooltip(_), do: "ASR-Unsicherheit"

  @doc """
  Tooltip-Label pro Utterance-Status. Default-Fallback für unbekannte
  Status macht das Quadrat sichtbar grau statt stillem Verschwinden.
  """
  @spec status_label(String.t() | nil) :: String.t()
  def status_label("confirmed"), do: "bestätigt"
  def status_label("live"), do: "live (Transkription läuft)"
  def status_label("edited"), do: "editiert"
  def status_label("manual"), do: "manuell hinzugefügt"
  def status_label(nil), do: "bestätigt"
  def status_label(other), do: "unbekannter Status: #{inspect(other)}"

  @doc """
  Theme-Token-Klasse für das Status-Quadrat. `deleted` returnt `nil`
  → Render-Logik filtert die Utterance ohnehin raus.
  """
  @spec status_dot_class(String.t() | nil) :: String.t() | nil
  def status_dot_class("confirmed"), do: "bg-success"
  def status_dot_class("live"), do: "bg-accent animate-pulse"
  def status_dot_class("edited"), do: "bg-warning"
  def status_dot_class("manual"), do: "bg-accent-soft"
  def status_dot_class("deleted"), do: nil
  def status_dot_class(nil), do: "bg-success"
  def status_dot_class(_), do: "bg-ink-2"
end
