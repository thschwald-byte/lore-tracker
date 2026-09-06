defmodule HubWeb.EinstellungenLive.GapFillPanel do
  @moduledoc """
  Issue #1135: die Gap-Fill-Einstellungen aus `/settings`, als eigenes Modul.

  **Warum ausgelagert.** `einstellungen_live.ex` steht auf einer Credo-Ratsche
  (#1097) — sie darf ihren Stand halten, aber nicht wachsen. Das neue Feld
  `ctx_gapfill` hätte sie gerissen. Denselben Fall gab es bei #1062, und die
  Antwort dort steht als Präzedenz im Kommentar der `.credo.exs`: *statt die
  Zeile zu verstecken oder die Ratsche anzuheben* wandert ein Block heraus, der
  für sich steht. Die Gap-Fill-Optionen sind so ein Block — sie gehören zu
  EINER Stufe und zu EINEM Modell, unabhängig von den übrigen Stage-Slots.

  **Was hier NICHT hingehört:** `merge_gap_seconds`. Das ist zwar auch Stage
  1.1, betrifft aber die Glättung selbst (den Sprecher-Merge) und nicht den
  Vorschlag — und es trägt die Kurations-Warnung, die einen zusätzlichen Assign
  braucht. Es bleibt im Hauptmodul.
  """

  use HubWeb, :html

  attr(:settings, :map, required: true)
  # Speist die datalist der Modellvorschläge. Ohne diese Deklaration wirft die
  # Komponente zur Laufzeit einen KeyError statt beim Kompilieren zu meckern —
  # attr/3 prüft nur, was deklariert IST.
  attr(:available_models, :list, required: true)

  @doc "Die Gap-Fill-Felder: Modell, Endpoint, Thinking-Level, Kontextfenster."
  def panel(assigns) do
    ~H"""
        <label class="block mt-3">
          <span class="text-sm text-ink-1">Gap-Fill-Modell (lokal)</span>
          <input
            type="text"
            name="settings[gapfill_model]"
            value={@settings["gapfill_model"]}
            placeholder="z.B. gemma3n:e4b — leer = Feature aus"
            list="gapfill-model-options"
            class="mt-1 block w-full bg-bg-0 border border-bg-3 rounded-md px-3 py-2 text-ink-0 font-mono text-sm focus:border-accent focus:ring-0"
          />
          <datalist id="gapfill-model-options">
            <option :for={m <- @available_models} value={m}>{m}</option>
          </datalist>
        </label>
        <p class="text-xs text-ink-2">
          Kleines lokales Modell für Lücken-Füll-Vorschläge (nur Vorschlag — Fakten an
          uncurierten Lücken bleiben bis zur menschlichen Bestätigung unverifiziert).
          Leer lassen schaltet die Vorschlags-Generierung ab.
        </p>

        <fieldset class="mt-3 space-y-1">
          <legend class="text-xs uppercase tracking-widest text-ink-2">
            Gap-Fill: Ollama-Endpoint
          </legend>
          <label
            :for={{ep, hint} <- [{"generate", "Standard"}, {"chat", "für Reasoning-Modelle"}]}
            class="flex items-baseline gap-2 cursor-pointer"
          >
            <input
              type="radio"
              name="settings[gapfill_local_endpoint]"
              value={ep}
              checked={gapfill_choice(@settings["gapfill_local_endpoint"], ~w(chat), "generate") == ep}
              class="accent-accent cursor-pointer"
            />
            <span class="text-xs text-ink-0">
              <code>/api/{ep}</code> <span class="text-ink-2">({hint})</span>
            </span>
          </label>
        </fieldset>
        <fieldset class="mt-3 space-y-1">
          <legend class="text-xs uppercase tracking-widest text-ink-2">
            Gap-Fill: Thinking-Level
          </legend>
          <label
            :for={level <- ~w(auto low medium high)}
            class="flex items-baseline gap-2 cursor-pointer"
          >
            <input
              type="radio"
              name="settings[gapfill_think]"
              value={level}
              checked={gapfill_choice(@settings["gapfill_think"], ~w(low medium high), "auto") == level}
              class="accent-accent cursor-pointer"
            />
            <span class="text-xs text-ink-0">
              {String.capitalize(level)}
              <span :if={level == "auto"} class="text-ink-2">(Standard)</span>
              <span :if={level == "medium"} class="text-ink-2">(Empfehlung für gpt-oss)</span>
            </span>
          </label>
        </fieldset>
        <label class="block mt-3">
          <span class="text-sm text-ink-1">Gap-Fill: Kontextfenster (Tokens)</span>
          <input
            type="number"
            min="1024"
            step="1024"
            name="settings[ctx_gapfill]"
            value={@settings["ctx_gapfill"]}
            class="input mt-1 w-full"
          />
          <span class="block text-[10px] text-ink-2/70 mt-1">
            Ohne eigenen Wert liefe die Stufe mit Ollamas Servervorgabe — eine
            Einstellung am Dienst (<code>OLLAMA_CONTEXT_LENGTH</code>) würde sie
            still umkonfigurieren. Gap-Fill arbeitet pro Block; der längste
            gemessene Block liegt bei rund 1800 Tokens, <code>8192</code> deckt
            Eingabe und Neuformulierung mit Abstand — <b>solange das
            Thinking-Level oben auf <code>auto</code> steht</b> (dann läuft die
            Stufe ohne Denkphase). Wer es auf <code>medium</code> oder
            <code>high</code> dreht, braucht hier mehr Platz. Ein Wert gleich
            <code>ctx_stage2</code> spart den Modell-Reload zwischen den Stufen,
            kostet aber dessen VRAM-Aufräumeffekt.
          </span>
        </label>
        <p class="text-[10px] text-ink-2/70 mt-2">
          Für Reasoning-Modelle mit nicht abschaltbarem Thinking (gpt-oss) als
          Gap-Fill-Modell: Endpoint <code>chat</code> + Level setzen, sonst liefert
          jeder Vorschlag <code>parse_failed</code>.
        </p>
    """
  end

  # Issue #874: Radio-Vorauswahl. Settings können als Atom (Default) ODER als
  # String (nach einem UI-Save) vorliegen — beide müssen dieselbe Auswahl
  # markieren, sonst springt die Anzeige nach dem Speichern auf den Default
  # zurück, ohne dass der Wert sich geändert hätte.
  defp gapfill_choice(v, allowed, default) do
    s = if is_atom(v) and not is_nil(v), do: Atom.to_string(v), else: v
    if s in allowed, do: s, else: default
  end
end
