defmodule HubWeb.EinstellungenLive.JackBlock do
  @moduledoc """
  J4 (#1207): der Block „Jack: Extract/verify“ in `/settings` — Stufe 2 der
  Pipeline. Jack ist immer lokal; es gibt kein Backend-Radio wie bei Stufe 4/5
  (`HubWeb.EinstellungenLive.StageStack` rendert für Stufe 2 diesen Block).

  Felder, alle Keys aus `Worker.Settings`:

    * Modell `model_stage2_local` — live_select mit der Ollama-Liste, wie in
      den lokalen Boxen der anderen Stufen (Event `live_select_change` der
      LiveView erkennt das Feld am Namen).
    * `jack_temperature`, `jack_top_p`, `jack_frequency_penalty`,
      `jack_max_tokens` — Defaults sind die Werte der Messreihe C.
    * `ctx_jack` — Jacks Kompaktierungsfenster, mit Hilfetext: es setzt NICHT
      das Fenster des Ollama-Servers (`Worker.Agent.Modell.Ollama` spricht
      `/v1/chat/completions`) und muss zu dem passen, womit Ollama das Modell
      lädt.
    * `resuemee_jack_model` (J5, #1209) — das Modell des Resümee-Jack, der das
      Resümee jeder Sitzung schreibt. Ein Textfeld mit Vorschlägen aus der
      Ollama-Liste statt eines zweiten live_select (dessen Event verarbeitet
      die LiveView); **leer = Jacks Modell**. Damit das Leeren ankommt, lässt
      `Options.normalize_settings_params/1` den Leerstring durch. Leser:
      `Worker.Jack.Resuemee.Pipeline.modell_name/0`. Endpunkt, Regler und
      Kontextfenster teilt der Resümee-Jack mit Jack.

  Eine eigene Form mit dem generischen `save`-Event der LiveView (sendet an
  den gewählten Worker, lädt danach neu). Die numerischen Keys stehen in den
  Parse-Listen von `HubWeb.EinstellungenLive.Options`; dass alle Feldnamen in
  der Schreib-Whitelist stehen, hält `Worker.SettingsUiDriftTest` fest.

  **`local_endpoint` wird hier nur angezeigt.** Der Endpunkt gilt global (auch
  für Stufe 4/5 lokal und den Gap-Fill) und hat sein Eingabefeld weiter unten
  („Local-Endpoint URL“). Ein zweites Feld mit demselben Namen wäre ein
  zweiter Ort zum Ändern, dessen Wert nach dem Speichern der anderen Form
  veraltet dasteht — also eine Stelle zum Ändern, eine zum Lesen.
  """

  use Phoenix.Component

  import LiveSelect

  alias HubWeb.EinstellungenLive.{Options, StageStack}

  attr(:title, :string, required: true)
  attr(:hint, :string, required: true)
  attr(:settings, :map, default: %{})
  attr(:available_models, :list, default: [])
  attr(:worker_aggregate, :map, default: %{total: 0, counts: %{}})

  def block(assigns) do
    model = Options.display_model(assigns.settings, 2, "local")
    form = to_form(%{"model_stage2_local" => model}, as: "settings")

    assigns =
      assigns
      |> assign(:model, model)
      |> assign(:model_field, form[:model_stage2_local])
      |> assign(:endpunkt, endpunkt(assigns.settings))

    ~H"""
    <fieldset class="panel p-4">
      <legend class="text-xs uppercase tracking-widest text-ink-2 px-2">Stage 2</legend>
      <h3 class="font-display text-base text-ink-0">{@title}</h3>
      <p class="text-xs text-ink-2 mb-3">{@hint}</p>

      <.form for={nil} as={nil} id="jack-form" phx-submit="save" class="space-y-4">
        <div class="block">
          <span class="text-xs text-ink-2">Modell (<code>model_stage2_local</code>)</span>
          <.live_select
            field={@model_field}
            options={Options.model_options(@available_models, @worker_aggregate)}
            mode={:single}
            user_defined_options={true}
            keep_options_on_select={true}
            update_min_len={0}
            debounce={150}
            placeholder="z.B. qwen3.8:27b — klicken für alle Modelle"
            container_class="mt-1 relative"
            text_input_class="block w-full bg-bg-0 border border-bg-3 rounded-md px-3 py-2 text-ink-0 font-mono text-sm focus:border-accent focus:ring-0"
            dropdown_class="absolute z-50 mt-1 max-h-64 overflow-y-auto bg-bg-0 border border-bg-3 rounded-md shadow-lg left-0 right-0"
            option_class="px-3 py-2 text-ink-0 text-sm font-mono cursor-pointer hover:bg-bg-1"
            active_option_class="bg-bg-1"
          />
          <p
            :if={@model && @available_models != [] && @model not in @available_models}
            class="text-[10px] text-rose-400 mt-1"
          >
            ⚠ <code>{@model}</code> ist auf diesem Worker nicht installiert.
            <code>ollama pull {@model}</code> oder anderes Modell wählen.
          </p>
        </div>

        <div class="block">
          <label for="resuemee-jack-model" class="text-xs text-ink-2">
            Modell des Resümee-Jack (<code>resuemee_jack_model</code>)
          </label>
          <input
            id="resuemee-jack-model"
            type="text"
            name="settings[resuemee_jack_model]"
            value={@settings["resuemee_jack_model"] || ""}
            list="resuemee-jack-modelle"
            placeholder="leer = Jacks Modell"
            class="mt-1 block w-full bg-bg-0 border border-bg-3 rounded-md px-3 py-2 text-ink-0 font-mono text-sm focus:border-accent focus:ring-0"
          />
          <datalist id="resuemee-jack-modelle">
            <option :for={m <- @available_models} value={m} />
          </datalist>
          <p class="text-[10px] text-ink-2/70 mt-1">
            Leer = Jacks Modell (<code>model_stage2_local</code>). Der Resümee-Jack schreibt das
            Resümee jeder Sitzung in drei Läufen (Überblick, Schreiben, Durchsicht); Endpunkt,
            Regler und Kontextfenster teilt er mit Jack.
          </p>
        </div>

        <p class="text-xs text-ink-2">
          Endpunkt: <code class="font-mono">{@endpunkt}</code>
          — einstellbar unter „Local-Endpoint URL“ weiter unten; der Wert gilt für alle
          lokalen Stufen. Jack spricht dort <code>/v1/chat/completions</code>.
        </p>

        <div class="grid gap-3 grid-cols-2 md:grid-cols-4">
          <StageStack.num_input
            name="settings[jack_temperature]"
            label="temperature"
            hint="Default 0.7"
            value={@settings["jack_temperature"]}
            step="0.05"
          />
          <StageStack.num_input
            name="settings[jack_top_p]"
            label="top_p"
            hint="Default 0.8"
            value={@settings["jack_top_p"]}
            step="0.05"
          />
          <StageStack.num_input
            name="settings[jack_frequency_penalty]"
            label="frequency_penalty"
            hint="Default 0.4"
            value={@settings["jack_frequency_penalty"]}
            step="0.05"
          />
          <StageStack.num_input
            name="settings[jack_max_tokens]"
            label="max_tokens"
            hint="Ausgabe-Deckel je Antwort, Default 60 000"
            value={@settings["jack_max_tokens"]}
            step="1"
          />
        </div>

        <div class="max-w-xs">
          <StageStack.num_input
            name="settings[ctx_jack]"
            label="Kontextfenster (ctx_jack)"
            hint="Token, Default 98 304"
            value={@settings["ctx_jack"]}
            step="1024"
          />
        </div>
        <p class="text-[10px] text-ink-2/70">
          Jacks eigenes Kompaktierungsfenster: kurz vor dieser Grenze fasst Jack seinen
          Verlauf zusammen. Es setzt <b>nicht</b> das Kontextfenster des Ollama-Servers —
          Jack spricht <code>/v1/chat/completions</code>, dort gibt es kein
          <code>num_ctx</code>. Der Wert muss zu dem passen, womit Ollama das Modell lädt
          (Modelfile <code>num_ctx</code> bzw. <code>OLLAMA_CONTEXT_LENGTH</code>); liegt er
          darüber, wird der Verlauf am Server zu lang, bevor Jack zusammenfasst. Ein zu
          kleiner Wert hält Jack an, sichtbar unter <code>/admin/errors</code>.
        </p>

        <p class="text-[10px] text-ink-2/70">
          Auch die Figuren- und Strang-Zuordnung nutzt dieses Modell (dort mit dem
          Kontextfenster als <code>num_ctx</code> und Temperatur 0). Die Defaults sind die
          Werte der Messreihe C — wer sie ändert, fährt Jack anders als gemessen.
        </p>

        <div class="flex justify-end">
          <button
            type="submit"
            class="text-xs px-3 py-1.5 rounded-md bg-accent/20 text-accent border border-accent/40 hover:bg-accent/30"
          >
            Jack speichern
          </button>
        </div>
      </.form>
    </fieldset>
    """
  end

  # Snapshot liefert nil für einen ungesetzten `:no_default`-Key; die UI kann
  # nach einem Save auch "" gesehen haben.
  defp endpunkt(settings) do
    case settings["local_endpoint"] do
      ep when is_binary(ep) and ep != "" -> ep
      _ -> "(nicht konfiguriert)"
    end
  end
end
