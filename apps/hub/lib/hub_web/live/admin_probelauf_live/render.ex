defmodule HubWeb.AdminProbelaufLive.Render do
  @moduledoc """
  Issue #573: Render-Template + Presentation-Helpers aus
  `HubWeb.AdminProbelaufLive`. Die LV delegiert `render/1` an dieses Modul,
  alle Formatter/Color/Status-Helper leben hier (sie sind pure Presentation-
  Logik ohne LV-State).
  """

  use HubWeb, :html

  alias HubWeb.AdminProbelaufLive.SweepForm
  alias HubWeb.Probelauf.SweepAggregator

  def render(assigns) do
    ~H"""
    <div class="px-8 py-6 max-w-5xl">
      <header class="mb-6">
        <h1 class="font-display text-2xl tracking-wide">Admin — LLM-Probelauf</h1>
        <p class="text-ink-2 text-sm mt-1">
          Smoke-Test der Pipeline mit aktueller Worker-Config. Issue #74.
        </p>
      </header>

      <%= if @no_worker? do %>
        <div class="panel p-8 text-center text-ink-2">
          Kein Worker connected — Probelauf nicht möglich.
        </div>
      <% else %>
        <div class="space-y-6">
          <div class="panel p-4 flex items-center justify-between">
            <div>
              <%= if @running do %>
                <p class="text-ink-0">
                  <span class="inline-block w-2 h-2 rounded-full bg-warning animate-pulse mr-2">
                  </span>
                  Probelauf läuft (run_id: <code class="text-xs">{@running["run_id"]}</code>)
                </p>
                <p class="text-xs text-ink-2 mt-1">
                  Gestartet: {format_iso(@running["started_at"])} — Worker arbeitet 3 Sessions
                  sequentiell durch (~2–8 min je nach Hardware).
                </p>
                <p class="text-xs text-ink-2 mt-1">
                  Aktuell laufende GPU-Stage:
                  <.link navigate={~p"/admin/jobs"} class="text-accent hover:underline">/admin/jobs</.link>
                </p>
              <% else %>
                <p class="text-ink-0">Bereit für Probelauf.</p>
                <p class="text-xs text-ink-2 mt-1">
                  Seed 3 Sessions (10/30/100 Utterances) + Pipeline-Run + Cleanup.
                </p>
              <% end %>
            </div>
            <.btn
              variant="primary"
              icon="player-play"
              phx-click="start_probelauf"
              disabled={@running != nil}
            >
              Probelauf starten
            </.btn>
          </div>

          <%= if @running do %>
            <div class="panel p-4">
              <h3 class="text-sm uppercase tracking-widest text-ink-2 mb-3">Live-Status</h3>
              <%= if map_size(@live_stages) == 0 do %>
                <p class="text-ink-2 text-sm">
                  Warte auf erste Stage-Events vom Worker …
                </p>
              <% else %>
                <%= for {cid, stages} <- @live_stages do %>
                  <div class="mb-3">
                    <p class="text-xs text-ink-2">Campaign: <code>{cid}</code></p>
                    <div class="flex gap-2 mt-1 flex-wrap">
                      <%= for stage <- @stages do %>
                        <% cell = stages[stage] %>
                        <span class={"px-2 py-1 rounded text-xs " <> outcome_color(stage_state(cell && cell.status))}>
                          {stage}: {if(cell, do: cell.status, else: "—")}
                        </span>
                      <% end %>
                    </div>
                    <%= for stage <- @stages, cell = stages[stage], cell && cell.error do %>
                      <p class="mt-1 text-xs text-rose-300">
                        ✗ {stage}: {cell.error}
                      </p>
                    <% end %>
                  </div>
                <% end %>
              <% end %>
            </div>
          <% end %>

          <%= if @last_run do %>
            <div class="panel p-4">
              <h3 class="text-sm uppercase tracking-widest text-ink-2 mb-3">
                Letzter Probelauf
                <span class="text-ink-2/70 normal-case font-normal ml-2">
                  ({format_iso(@last_run["finished_at"])})
                </span>
              </h3>

              <div class="overflow-x-auto">
                <table class="w-full text-sm">
                  <thead class="text-ink-2 text-xs uppercase tracking-widest border-b border-bg-3/60">
                    <tr>
                      <th class="text-left px-3 py-2">Session</th>
                      <th class="text-left px-3 py-2">Utterances</th>
                      <%= for s <- @stages do %>
                        <th class="text-left px-3 py-2">{s}</th>
                      <% end %>
                    </tr>
                  </thead>
                  <tbody>
                    <%= for sess <- @last_run["sessions"] || [] do %>
                      <tr class="border-b border-bg-3/30 last:border-0">
                        <td class="px-3 py-2 text-ink-0">#{sess["number"]}</td>
                        <td class="px-3 py-2 text-ink-2">{sess["utterance_count"]}</td>
                        <%= for stage <- @stages do %>
                          <td class="px-3 py-2">
                            <span class={"px-2 py-1 rounded text-xs " <> outcome_color(get_in(sess, ["stages", stage, "outcome"]))}>
                              {format_ms(get_in(sess, ["stages", stage, "duration_ms"]))} · {get_in(sess, ["stages", stage, "outcome"]) || "—"}
                            </span>
                          </td>
                        <% end %>
                      </tr>
                    <% end %>
                  </tbody>
                </table>
              </div>

              <div class="mt-4 panel p-4 bg-bg-1/50">
                <h4 class="text-sm uppercase tracking-widest text-ink-2 mb-2">Empfehlung</h4>
                <%= if @recommendation_text do %>
                  <div class="text-sm text-ink-0 whitespace-pre-line">
                    {@recommendation_text}
                  </div>
                  <div class="mt-3">
                    <.btn
                      variant="secondary"
                      icon="check"
                      phx-click="apply_recommendation"
                      disabled={@recommendation_kv == %{}}
                    >
                      Empfehlung übernehmen
                    </.btn>
                    <span class="text-xs text-ink-2 ml-2">
                      Setzt: <code>{inspect(@recommendation_kv)}</code>
                    </span>
                  </div>
                <% else %>
                  <p class="text-ink-2 text-sm italic">Keine Empfehlung verfügbar.</p>
                <% end %>
              </div>

              <details class="mt-4 text-xs">
                <summary class="cursor-pointer text-ink-2 hover:text-accent uppercase tracking-widest">
                  Settings-Snapshot zum Lauf
                </summary>
                <pre class="mt-2 panel p-3 text-ink-2 overflow-x-auto"><%= inspect(@last_run["settings_snapshot"], pretty: true) %></pre>
              </details>
            </div>
          <% end %>

          <div class="panel p-4">
            <h3 class="text-sm uppercase tracking-widest text-ink-2 mb-3">
              Sweep — Modell-Vergleich pro Stage (Phase 2a)
            </h3>
            <p class="text-xs text-ink-2 mb-4">
              Variiert genau eine Stage durch mehrere Modelle. Die anderen zwei Stages bleiben auf dem aktuellen Default — nur die ausgewählte Stage wird gemessen. Dauer ≈ <code>Anzahl-Modelle × Single-Probelauf-Dauer</code>.
            </p>
            <form phx-submit="start_sweep" phx-change="sweep_form_change" class="space-y-4">
              <div>
                <p class="text-xs uppercase tracking-widest text-ink-2 mb-2">Sweep-Modus</p>
                <div class="flex gap-4">
                  <label class="flex items-center gap-2 text-sm text-ink-0">
                    <input
                      type="radio"
                      name="mode"
                      value="full"
                      checked={@sweep_form.mode == "full"}
                      class="accent-accent"
                    />
                    Voll-Pipeline
                    <span class="text-ink-2/70 text-xs">(alle Stages laufen, Default-Modus)</span>
                  </label>
                  <label class="flex items-center gap-2 text-sm text-ink-0">
                    <input
                      type="radio"
                      name="mode"
                      value="isolated"
                      checked={@sweep_form.mode == "isolated"}
                      class="accent-accent"
                    />
                    Stage-Isoliert
                    <span class="text-ink-2/70 text-xs">
                      (#262 — nur Ziel-Stage gegen Goldstandard, ~3-5× schneller)
                    </span>
                  </label>
                </div>
              </div>

              <div>
                <p class="text-xs uppercase tracking-widest text-ink-2 mb-2">Stage</p>
                <div class="flex gap-4">
                  <%= for s <- [2, 3, 4] do %>
                    <label class="flex items-center gap-2 text-sm text-ink-0">
                      <input
                        type="radio"
                        name="stage"
                        value={s}
                        checked={@sweep_form.stage == s}
                        class="accent-accent"
                      />
                      Stage {s}
                      <span class="text-ink-2/70">
                        ({case s do
                          2 -> "Resümee"
                          3 -> "Epos"
                          4 -> "Chronik"
                        end})
                      </span>
                    </label>
                  <% end %>
                </div>
              </div>

              <div>
                <p class="text-xs uppercase tracking-widest text-ink-2 mb-2">
                  Eval-Sessions (#284 / #286)
                </p>
                <div class="flex gap-4 flex-wrap">
                  <%= for {tag, label, utts} <- [
                        {"short", "kurz", "10"},
                        {"medium", "medium", "30"},
                        {"long", "lang", "100"},
                        {"real", "real", "~800"}
                      ] do %>
                    <label class="flex items-center gap-2 text-sm text-ink-0">
                      <input
                        type="checkbox"
                        name="session_set[]"
                        value={tag}
                        checked={MapSet.member?(@sweep_form.session_set, tag)}
                        class="accent-accent"
                      />
                      {label}
                      <span class="text-ink-2/70 text-xs">({utts} utts)</span>
                    </label>
                  <% end %>
                </div>
              </div>

              <div>
                <p class="text-xs uppercase tracking-widest text-ink-2 mb-2">
                  Modelle ({length(@available_models)} verfügbar)
                </p>
                <%= if @available_models == [] do %>
                  <p class="text-sm text-ink-2 italic">
                    Worker hat keine Modelle gemeldet — Ollama läuft? <code>ollama list</code> prüfen.
                  </p>
                <% else %>
                  <div class="grid grid-cols-2 gap-2">
                    <%= for m <- @available_models do %>
                      <label class="flex items-center gap-2 text-sm text-ink-0">
                        <input
                          type="checkbox"
                          name="models[]"
                          value={m}
                          checked={MapSet.member?(@sweep_form.models, m)}
                          class="accent-accent"
                        />
                        <code class="text-xs">{m}</code>
                      </label>
                    <% end %>
                  </div>
                <% end %>
              </div>

              <.btn
                variant="primary"
                icon="player-play"
                type="submit"
                disabled={@running != nil or @available_models == []}
              >
                Sweep starten
              </.btn>
            </form>

            <%= if @running && @running["type"] == "sweep" do %>
              <div class="mt-4 panel p-3 bg-bg-1/50">
                <p class="text-xs text-ink-2">
                  Sweep läuft: sweep_id <code>{@running["sweep_id"]}</code>, Stage {@running["stage"]}, {length(@running["models"] || [])} Modelle.
                </p>
                <%= if @running["current_model"] do %>
                  <p class="text-sm text-ink-0 mt-1">
                    Aktuell: <code>{@running["current_model"]}</code>
                    <%= if @running["completed"] && @running["total"] do %>
                      <span class="text-xs text-ink-2 ml-2">
                        ({@running["completed"] + 1}/{@running["total"]})
                      </span>
                    <% end %>
                  </p>
                <% end %>
              </div>
            <% end %>
          </div>

          <div class="panel p-4">
            <h3 class="text-sm uppercase tracking-widest text-ink-2 mb-3">
              Multi-Stage-Sweep (Phase 2b)
            </h3>
            <p class="text-xs text-ink-2 mb-4">
              Pro Stage eine eigene Modell-Liste ankreuzen — die LV feuert die Sweeps sequentiell ab, je ein Sweep pro Stage mit nicht-leerer Auswahl.
              <span class="text-ink-2/70">Modus + Eval-Sessions gelten für alle Stages gleich.</span>
            </p>
            <form phx-submit="start_sweep_multi" phx-change="sweep_form_change" class="space-y-4">
              <div>
                <p class="text-xs uppercase tracking-widest text-ink-2 mb-2">Sweep-Modus</p>
                <div class="flex gap-4">
                  <label class="flex items-center gap-2 text-sm text-ink-0">
                    <input
                      type="radio"
                      name="mode"
                      value="full"
                      checked={@sweep_form.mode == "full"}
                      class="accent-accent"
                    />
                    Voll-Pipeline
                  </label>
                  <label class="flex items-center gap-2 text-sm text-ink-0">
                    <input
                      type="radio"
                      name="mode"
                      value="isolated"
                      checked={@sweep_form.mode == "isolated"}
                      class="accent-accent"
                    />
                    Stage-Isoliert
                  </label>
                </div>
              </div>

              <div>
                <p class="text-xs uppercase tracking-widest text-ink-2 mb-2">
                  Eval-Sessions
                </p>
                <div class="flex gap-4 flex-wrap">
                  <%= for {tag, label, utts} <- [
                        {"short", "kurz", "10"},
                        {"medium", "medium", "30"},
                        {"long", "lang", "100"},
                        {"real", "real", "~800"}
                      ] do %>
                    <label class="flex items-center gap-2 text-sm text-ink-0">
                      <input
                        type="checkbox"
                        name="session_set[]"
                        value={tag}
                        checked={MapSet.member?(@sweep_form.session_set, tag)}
                        class="accent-accent"
                      />
                      {label}
                      <span class="text-ink-2/70 text-xs">({utts} utts)</span>
                    </label>
                  <% end %>
                </div>
              </div>

              <%= for s <- [2, 3, 4] do %>
                <div>
                  <p class="text-xs uppercase tracking-widest text-ink-2 mb-2">
                    Stage {s} — <%= case s do
                      2 -> "Resümee"
                      3 -> "Epos"
                      4 -> "Chronik"
                    end %>
                    <span class="text-ink-2/70 normal-case font-normal ml-2">
                      ({MapSet.size(@sweep_form.stage_models[s])} angekreuzt)
                    </span>
                  </p>
                  <%= if @available_models == [] do %>
                    <p class="text-sm text-ink-2 italic">Keine Modelle verfügbar.</p>
                  <% else %>
                    <div class="grid grid-cols-2 gap-2">
                      <%= for m <- @available_models do %>
                        <label class="flex items-center gap-2 text-sm text-ink-0">
                          <input
                            type="checkbox"
                            name={"stage_models[#{s}][]"}
                            value={m}
                            checked={MapSet.member?(@sweep_form.stage_models[s], m)}
                            class="accent-accent"
                          />
                          <code class="text-xs">{m}</code>
                        </label>
                      <% end %>
                    </div>
                  <% end %>
                </div>
              <% end %>

              <.btn
                variant="primary"
                icon="player-play"
                type="submit"
                disabled={@running != nil or @available_models == []}
              >
                Multi-Stage-Sweep starten
              </.btn>

              <%= if @pending_sweep_queue != [] do %>
                <p class="text-xs text-ink-2 mt-2">
                  Queue: noch {length(@pending_sweep_queue)} Stages wartend ({@pending_sweep_queue |> Enum.map(& "Stage #{&1.stage}") |> Enum.join(", ")}).
                </p>
              <% end %>
            </form>

            <% multi_kv = SweepForm.multi_stage_winners(@sweep_summaries || []) %>
            <%= if multi_kv != %{} do %>
              <div class="mt-4 panel p-3 bg-bg-1/50">
                <h4 class="text-sm uppercase tracking-widest text-ink-2 mb-2">
                  Beste Multi-Stage-Empfehlung (Phase 2c)
                </h4>
                <p class="text-xs text-ink-2 mb-3">
                  Aus den letzten <%= length(@sweep_summaries || []) %> Sweeps abgeleitet — pro Stage der Top-Treffer (Quality-Gate: success_rate ≥ 50%).
                </p>
                <ul class="text-sm text-ink-0 mb-3 space-y-1">
                  <%= for {key, model} <- Enum.sort(multi_kv) do %>
                    <li>
                      <code class="text-xs">{key}</code> → <code class="text-xs">{model}</code>
                    </li>
                  <% end %>
                </ul>
                <.btn
                  variant="secondary"
                  icon="check"
                  phx-click="apply_multi_recommendation"
                  disabled={@running != nil}
                >
                  Multi-Stage-Empfehlung übernehmen
                </.btn>
                <p class="mt-2 text-xs text-ink-2/70 italic">
                  Schreibt {map_size(multi_kv)} Settings via <code>Worker.Settings.put_many/1</code>. Worker-Restart greift erst danach.
                </p>
              </div>
            <% end %>
          </div>

          <%!-- Issue #289 Phase 4: Param-Sweep (Temperature-Varianten). --%>
          <div class="panel p-4">
            <h3 class="text-sm uppercase tracking-widest text-ink-2 mb-3">
              Param-Sweep (Temperature)
            </h3>
            <p class="text-xs text-ink-2 mb-3">
              Variiert <code>temperature_stageN</code> über eine feste Werte-Liste
              bei aktuellem Default-Modell. Pro Temperatur eine Variante in der
              Sweep-Tabelle unten. Werte: <code>0.05, 0.10, 0.15, 0.20</code>
              (hardcoded für #289 Phase 4 — Settings-API folgt falls gewünscht).
            </p>
            <form phx-submit="start_sweep_param" class="space-y-3">
              <div class="flex items-center gap-3">
                <label class="text-sm text-ink-0">Stage:</label>
                <select name="stage" class="px-2 py-1 bg-bg-2 border border-bg-3 rounded text-sm">
                  <option value="2">Stage 2 (Resümee)</option>
                  <option value="3">Stage 3 (Epos)</option>
                  <option value="4" selected>Stage 4 (Chronik)</option>
                </select>
              </div>
              <.btn
                variant="primary"
                icon="adjustments"
                type="submit"
                disabled={@running != nil}
              >
                Param-Sweep starten (4 Temperaturen)
              </.btn>
            </form>
          </div>

          <% display = displayed_sweep_summary(assigns) %>
          <%= if display do %>
            <div class="panel p-4">
              <h3 class="text-sm uppercase tracking-widest text-ink-2 mb-3">
                <%= if display.in_progress? do %>
                  Sweep läuft — Stage {display.stage}
                  <span class="text-ink-2/70 normal-case font-normal ml-2">
                    ({length(display.rows)}/{display.total_models} bewertet)
                  </span>
                <% else %>
                  Letzter Sweep — Stage {display.stage}
                  <span class="text-ink-2/70 normal-case font-normal ml-2">
                    ({format_iso(display.finished_at)})
                  </span>
                <% end %>
                <%= if display[:session_set] && display.session_set != [] do %>
                  <span class="text-ink-2/70 normal-case font-normal ml-2">
                    — Sessions: {format_session_set(display.session_set)}
                  </span>
                <% end %>
              </h3>
              <p class="text-xs text-ink-2 mb-3">
                Default-Modell (vor Sweep): <code>{display.default_model}</code>.
                Sortiert nach Qualität ↓, Success-Rate ↓, Median-Dauer ↑ — beste Wahl oben.
              </p>

              <div class="overflow-x-auto">
                <table class="w-full text-sm">
                  <thead class="text-ink-2 text-xs uppercase tracking-widest border-b border-bg-3/60">
                    <tr>
                      <th class="text-left px-3 py-2 w-6"></th>
                      <th class="text-left px-3 py-2">Modell</th>
                      <th class="text-left px-3 py-2">Qualität</th>
                      <th class="text-left px-3 py-2">Median-Dauer (Stage {display.stage})</th>
                      <th class="text-left px-3 py-2">Success-Rate</th>
                      <th class="text-left px-3 py-2">Format</th>
                      <th class="text-left px-3 py-2">Timeout</th>
                      <th class="text-left px-3 py-2">Sessions</th>
                    </tr>
                  </thead>
                  <tbody>
                    <%= for row <- display.rows do %>
                      <tr class="border-b border-bg-3/30 last:border-0">
                        <td class="px-3 py-2">
                          <span class={"inline-block w-2.5 h-2.5 rounded-full " <> status_dot_class(row[:status])} title={status_dot_label(row[:status])}></span>
                        </td>
                        <td class="px-3 py-2 text-ink-0">
                          <code class="text-xs">{row.model}</code>
                          <%= if row.model == display.default_model do %>
                            <span class="ml-2 text-xs text-ink-2/70">(Default)</span>
                          <% end %>
                        </td>
                        <td class="px-3 py-2">
                          <%= if row[:faithfulness_avg] do %>
                            <span class={"px-2 py-1 rounded text-xs " <> faithfulness_color(row.faithfulness_avg)}>
                              {Float.round(row.faithfulness_avg * 100, 0) |> trunc()}%
                            </span>
                          <% else %>
                            <span class="text-ink-2/50">—</span>
                          <% end %>
                        </td>
                        <td class="px-3 py-2 text-ink-0">{format_ms(row.median_ms)}</td>
                        <td class="px-3 py-2">
                          <%= if row[:session_count] && row.session_count > 0 do %>
                            <span class={"px-2 py-1 rounded text-xs " <> success_rate_color(row.success_rate)}>
                              {Float.round(row.success_rate * 100, 0) |> trunc()}%
                            </span>
                          <% else %>
                            <span class="text-ink-2/50">—</span>
                          <% end %>
                        </td>
                        <td class="px-3 py-2">
                          <%= cond do %>
                            <% row[:session_count] == nil or row.session_count == 0 -> %>
                              <span class="text-ink-2/50">—</span>
                            <% is_nil(row[:format_issue]) -> %>
                              <span class="text-success text-xs">ok</span>
                            <% true -> %>
                              <span class="px-2 py-1 rounded text-xs bg-warning/20 text-warning" title={row.format_issue}>
                                {row.format_issue}
                              </span>
                          <% end %>
                        </td>
                        <td class="px-3 py-2">
                          <%= cond do %>
                            <% row[:session_count] == nil or row.session_count == 0 -> %>
                              <span class="text-ink-2/50">—</span>
                            <% row[:has_timeout] -> %>
                              <span class="px-2 py-1 rounded text-xs bg-danger/20 text-danger">ja</span>
                            <% true -> %>
                              <span class="text-ink-2 text-xs">nein</span>
                          <% end %>
                        </td>
                        <td class="px-3 py-2 text-ink-2">{row.session_count}</td>
                      </tr>
                    <% end %>
                  </tbody>
                </table>
              </div>

              <p class="mt-3 text-xs text-ink-2 italic">
                Auto-Apply (das beste Modell mit einem Klick übernehmen) kommt in Phase 2c (#88).
                Manuell setzen via <code>/settings</code>.
              </p>
            </div>
          <% end %>

          <% history = Enum.drop(@sweep_summaries || [], 1) |> Enum.reject(&is_nil/1) %>
          <%= if history != [] do %>
            <div class="panel p-4">
              <h3 class="text-sm uppercase tracking-widest text-ink-2 mb-3">
                Sweep-Verlauf (Multi-Stage)
                <span class="text-ink-2/70 normal-case font-normal ml-2">
                  ({length(history)} zurückliegend)
                </span>
              </h3>
              <p class="text-xs text-ink-2 mb-3">
                Bei Multi-Stage-Sweeps zeigt der Verlauf die per-Stage-Tabellen aus den vorherigen Stages des aktuellen Multi-Stage-Laufs.
              </p>
              <%= for s <- history do %>
                <div class="mb-4 panel p-3 bg-bg-1/50">
                  <p class="text-xs text-ink-2 mb-2">
                    Stage {s.stage}
                    <span class="ml-2">({format_iso(s.finished_at)})</span>
                    — Default: <code>{s.default_model}</code>
                  </p>
                  <div class="overflow-x-auto">
                    <table class="w-full text-sm">
                      <thead class="text-ink-2 text-xs uppercase tracking-widest border-b border-bg-3/60">
                        <tr>
                          <th class="text-left px-3 py-2">Modell</th>
                          <th class="text-left px-3 py-2">Qualität</th>
                          <th class="text-left px-3 py-2">Median</th>
                          <th class="text-left px-3 py-2">Success</th>
                        </tr>
                      </thead>
                      <tbody>
                        <%= for row <- s.rows do %>
                          <tr class="border-b border-bg-3/30 last:border-0">
                            <td class="px-3 py-2 text-ink-0">
                              <code class="text-xs">{row.model}</code>
                              <%= if row.model == s.default_model do %>
                                <span class="ml-2 text-xs text-ink-2/70">(Default)</span>
                              <% end %>
                            </td>
                            <td class="px-3 py-2">
                              <%= if row[:faithfulness_avg] do %>
                                <span class={"px-2 py-1 rounded text-xs " <> faithfulness_color(row.faithfulness_avg)}>
                                  {Float.round(row.faithfulness_avg * 100, 0) |> trunc()}%
                                </span>
                              <% else %>
                                <span class="text-ink-2/50">—</span>
                              <% end %>
                            </td>
                            <td class="px-3 py-2 text-ink-0">{format_ms(row.median_ms)}</td>
                            <td class="px-3 py-2">
                              <span class={"px-2 py-1 rounded text-xs " <> success_rate_color(row.success_rate)}>
                                {Float.round(row.success_rate * 100, 0) |> trunc()}%
                              </span>
                            </td>
                          </tr>
                        <% end %>
                      </tbody>
                    </table>
                  </div>
                </div>
              <% end %>
            </div>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  # ─── Presentation Helpers ────────────────────────────────────────

  def format_ms(nil), do: "—"
  def format_ms(ms) when is_number(ms) and ms < 1000, do: "#{round(ms)} ms"
  def format_ms(ms) when is_number(ms), do: "#{Float.round(ms / 1000, 1)} s"

  def outcome_color("ok"), do: "bg-success/20 text-success"
  def outcome_color("timeout"), do: "bg-danger/20 text-danger"
  def outcome_color("empty_output"), do: "bg-warning/20 text-warning"
  def outcome_color("parse_error"), do: "bg-warning/20 text-warning"
  def outcome_color(_), do: "bg-surface-2/40 text-fg-muted"

  def success_rate_color(rate) when rate >= 1.0, do: "bg-success/20 text-success"
  def success_rate_color(rate) when rate >= 0.5, do: "bg-warning/20 text-warning"
  def success_rate_color(_), do: "bg-danger/20 text-danger"

  # Issue #288: Status-Dot pro Row.
  def status_dot_class(:pending), do: "bg-warning animate-pulse"
  def status_dot_class(:running), do: "bg-accent animate-pulse"
  def status_dot_class(:done_ok), do: "bg-success"
  def status_dot_class(:done_err), do: "bg-danger"
  def status_dot_class(_), do: "bg-bg-3"

  def status_dot_label(:pending), do: "wartet"
  def status_dot_label(:running), do: "läuft"
  def status_dot_label(:done_ok), do: "fertig (ok)"
  def status_dot_label(:done_err), do: "fertig (Fehler)"
  def status_dot_label(_), do: ""

  # Issue #284: macht aus ["short", "long"] → "kurz + lang"
  def format_session_set(tags) when is_list(tags) do
    tags
    |> Enum.map(fn
      "short" -> "kurz"
      "medium" -> "medium"
      "long" -> "lang"
      other -> other
    end)
    |> Enum.join(" + ")
  end

  def format_session_set(_), do: ""

  def faithfulness_color(score) when is_number(score) and score >= 0.8,
    do: "bg-success/20 text-success"

  def faithfulness_color(score) when is_number(score) and score >= 0.5,
    do: "bg-warning/20 text-warning"

  def faithfulness_color(_), do: "bg-danger/20 text-danger"

  # Issue #281b: liefert die im UI angezeigte Sweep-Summary. Während ein
  # isolated Sweep läuft (running != nil + live_sweep_variants gefüllt) wird
  # die Tabelle live aus den per-Variant-Pushes aufgebaut; danach kommt das
  # finale @sweep_summary aus dem Worker-Snapshot.
  # Issue #288: Tabelle erscheint jetzt SOFORT beim Sweep-Start (auch wenn
  # noch keine Variant fertig ist) — Modelle als :pending-Rows angelegt.
  # Zusätzlich Status pro Row für Dots in der UI.
  def displayed_sweep_summary(%{
        running: running,
        live_sweep_variants: live_variants
      } = assigns)
      when not is_nil(running) do
    total_models = running["models"] || []

    base =
      SweepAggregator.aggregate(%{
        "sweep_id" => running["sweep_id"],
        "stage" => running["stage"],
        "default_model" => running["default_model"],
        "started_at" => running["started_at"],
        "finished_at" => nil,
        "variants" => live_variants
      })

    rows =
      cond do
        # Sweep gerade gestartet — keine Variant fertig — alle Modelle als
        # :pending darstellen.
        base == nil ->
          Enum.map(total_models, &pending_row/1)

        true ->
          # Done-Rows + Pending-Rows für noch ausstehende Modelle mergen.
          done_models = MapSet.new(base.rows, & &1.model)

          pending_rows =
            total_models
            |> Enum.reject(&MapSet.member?(done_models, &1))
            |> Enum.map(&pending_row/1)

          base.rows ++ pending_rows
      end

    rows_with_status = Enum.map(rows, &with_row_status(&1, running))

    base_map =
      case base do
        nil ->
          %{
            sweep_id: running["sweep_id"],
            stage: running["stage"],
            stage_key: "stage#{running["stage"]}",
            default_model: running["default_model"],
            started_at: running["started_at"],
            finished_at: nil,
            session_set: []
          }

        m ->
          m
      end

    _ = assigns

    base_map
    |> Map.put(:rows, rows_with_status)
    |> Map.put(:in_progress?, true)
    |> Map.put(:total_models, length(total_models))
  end

  def displayed_sweep_summary(%{sweep_summary: nil}), do: nil

  def displayed_sweep_summary(%{sweep_summary: persisted}) do
    rows_with_status = Enum.map(persisted.rows || [], &with_row_status(&1, nil))

    persisted
    |> Map.put(:rows, rows_with_status)
    |> Map.put(:in_progress?, false)
    |> Map.put(:total_models, length(persisted.rows || []))
  end

  # Issue #288: Row-Skelett für noch nicht gemessene Modelle.
  defp pending_row(model) do
    %{
      model: model,
      median_ms: nil,
      success_rate: 0.0,
      faithfulness_avg: nil,
      run_count: 0,
      session_count: 0,
      format_issue: nil,
      has_timeout: false
    }
  end

  # Issue #288: leitet den Row-Status aus der Sweep-Progress + Row-Daten ab.
  # Reihenfolge der Klauseln matters — `:running` kommt vor `:done_*`.
  # Map.get statt Dot-Access wo Felder optional sind (alte persistierte
  # Sweeps vor #288 haben kein :has_timeout/:format_issue).
  defp with_row_status(row, running) do
    has_timeout = Map.get(row, :has_timeout, false)
    success_rate = Map.get(row, :success_rate, 0.0)
    session_count = Map.get(row, :session_count, 0)
    model = Map.get(row, :model)

    status =
      cond do
        running && model == running["current_model"] && session_count == 0 ->
          :running

        session_count == 0 && running != nil ->
          :pending

        has_timeout || (success_rate < 0.5 && session_count > 0) ->
          :done_err

        session_count > 0 ->
          :done_ok

        true ->
          :pending
      end

    Map.put(row, :status, status)
  end

  def stage_state(nil), do: nil
  def stage_state("started"), do: nil
  def stage_state("ended"), do: "ok"
  def stage_state("failed"), do: "timeout"
  def stage_state(other), do: other

  def format_iso(nil), do: "—"
  def format_iso(s) when is_binary(s), do: s
  def format_iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  def format_iso(_), do: "—"
end
