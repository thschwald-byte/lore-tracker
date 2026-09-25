defmodule HubWeb.CampaignLive.FragFenster do
  @moduledoc """
  Issue #850, erster Schnitt: das Fenster „Frag die Runde" — Oberfläche mit
  synthetischen Läufen (`FragFenster.Synthetisch`), ohne Agent dahinter.

  **Die Farben sind die des Hauses** (`panel`, `ink-*`) — neu ist allein ein
  dünner Rand in `primary`, dem Cyan des Türkis-Schemas aus #194, damit das
  Fenster über den Spalten auffällt.

  **Warum ein Fenster und kein Chat-Widget am Bildschirmrand.** Hinter dem
  üblichen Chatbot-Knopf liegt nichts, was man lesen müsste; hier liegt genau
  das, worum es geht. Ein Beleg zeigt auf eine Stelle in einer der sechs
  Spalten — also muss das Fenster **beweglich** sein, sonst verdeckt es
  entweder die Frage oder die Antwort (Maintainer, 25.09.2026).

  **Nicht modal**, und das ist mehr als der fehlende Backdrop:

  * `<dialog>` wird mit `.show()` geöffnet, nicht `.showModal()` — kein
    Backdrop, nichts wird `inert`, **Escape schließt nicht**. Alle drei sind
    natives Verhalten des nicht-modalen Dialogs, nicht nachgebaut.
  * **Kein `phx-click-away`.** Der erste Klick in eine Spalte — also genau
    das, wofür man das Fenster verschoben hat — würde es sonst zuklappen,
    mitsamt der halb getippten Antwort. Deshalb ist dies KEINE
    `lt_modal`-Instanz; wer sie davon ableitet, schleppt beides mit und macht
    das Fenster unbrauchbar.
  * In der Stapelordnung liegt es **unter** dem Modal (`z-40` gegen dessen
    `z-50`): Ein Modal ist eine Entscheidung, die man zuerst trifft.

  **`JS.ignore_attributes(["open", "style"])` ist Pflicht, nicht Kosmetik** —
  und **beide** Namen sind es. Der Hook öffnet den Dialog auf dem Client und
  setzt Position wie Größe über `style`; rendert der Server danach
  irgendetwas, diffte morphdom beides weg: Das Fenster schlösse sich bei der
  nächsten Antwort von selbst und spränge vorher in die Ecke, weil ohne
  `left`/`top` nur noch die Klassen gelten.

  `style` zu vergessen war genau dieser Fehler (gemeldet 25.09.2026: „das
  Fenster springt manchmal einfach in eine Ecke"), und er wurde **dauerhaft**:
  Der `ResizeObserver` im Hook feuert auf das zurückgesetzte Element und
  schreibt die falsche Position nach localStorage — beim nächsten Öffnen
  steht sie schon dort. Deshalb merkt der Hook nur noch, was aus einer
  Bewegung des Betrachters stammt.

  `phx-update="ignore"` wäre die falsche Abhilfe — es fröre den **Inhalt**
  ein, und die Antwort erschiene nie.

  **Der Verlauf ist flüchtig** (Maintainer, 25.09.2026): Spieler fragt,
  bekommt Antwort, fertig. Kein Ereignis, kein Speicher, kein `☰`. Was
  bleibt, sind **Befunde** (eigenes Objekt, #1243) und die Wirkungen von
  Werkzeugen — beides nicht Teil dieses Schnitts. Zuklappen verwirft das
  Gespräch; die Befunde stehen danach weiter in den Chips.

  Gemerkt wird allein Position und Größe, per Gerät in localStorage
  (`frag_fenster.js`, Muster `ViewModePersist`).
  """

  use Phoenix.Component

  alias HubWeb.CampaignLive.FragFenster.{Synthetisch, Warten}
  alias Phoenix.LiveView.JS

  @doc "Der Anfangszustand fürs Mount — eine Stelle, damit kein Feld vergessen wird (#1005)."
  @spec initial() :: map()
  def initial,
    do: %{offen?: false, verlauf: [], lauf: nil, frage: "", befunde: Synthetisch.befunde()}

  @doc """
  Der Befund an einer Fakt-Zeile, für das Zeichen in der Spalte. Fassade für
  das Template, das keine Aliase kennt.

  **Das Ziel des Klicks ist das Zeichen, nicht die Zeile.** Die Fakt-Zeile ist
  seit #916 bereits klickbar (claim, Figur, Strang, ausblenden); ein zweiter
  Klick-Sinn auf derselben Fläche wäre eine stille Kollision — man will
  kuratieren und bekommt ein Gesprächsfenster.
  """
  @spec befund_an_fakt(term()) :: String.t() | nil
  defdelegate befund_an_fakt(fakt_id), to: Synthetisch

  @doc "Zahl am Knopf: offene Befunde. Nicht die Länge des Gesprächs — das ist flüchtig."
  @spec offene(map()) :: non_neg_integer()
  def offene(%{befunde: b}), do: length(b)
  def offene(_), do: 0

  # ——— Ereignisse ———————————————————————————————————————————————

  @doc "Dispatch der `frag_*`-Events aus dem CampaignLive-handle_event."
  def event(socket, "frag_oeffnen", _params), do: {:noreply, auf(socket, true)}
  def event(socket, "frag_schliessen", _params), do: {:noreply, auf(socket, false)}

  def event(socket, "frag_senden", %{"frage" => frage}) do
    frage = String.trim(frage)
    if frage == "", do: {:noreply, socket}, else: {:noreply, starte(socket, frage)}
  end

  def event(socket, "frag_vorschlag", %{"text" => text}),
    do: {:noreply, starte(socket, text)}

  def event(socket, "frag_befund", %{"id" => id}) do
    frag = socket.assigns.frag

    cond do
      # Schon im Verlauf: nur aufmachen. Wer in der Spalte zwischen zwei
      # Zeichen hin und her klickt, soll den Befund nicht doppelt bekommen.
      Enum.any?(frag.verlauf, &(Map.get(&1, :befund_id) == id)) ->
        auf(socket, true) |> then(&{:noreply, &1})

      b = Enum.find(frag.befunde, &(&1.id == id)) ->
        eintrag = %{
          art: :befund,
          befund_id: b.id,
          titel: b.titel,
          text: b.text,
          belege: b.belege
        }

        {:noreply,
         Phoenix.Component.assign(socket, :frag, %{
           frag
           | offen?: true,
             verlauf: frag.verlauf ++ [eintrag]
         })}

      true ->
        {:noreply, socket}
    end
  end

  @doc """
  Ein Schritt der synthetischen Konsole. Läuft über `Process.send_after` an
  die LiveView — **die CampaignLive hat keinen `handle_info`-Auffangzweig**
  (#1149), die Klausel dort ist also Pflicht, nicht Kosmetik.
  """
  def schritt(socket, lauf_id) do
    frag = socket.assigns.frag

    case frag.lauf do
      %{id: ^lauf_id, rest: [s | rest]} = lauf ->
        timer =
          if rest != [], do: Process.send_after(self(), {:frag_schritt, lauf_id}, hd(rest).ms)

        lauf = %{lauf | rest: rest, zeilen: lauf.zeilen ++ [s], timer: timer}
        {:noreply, Phoenix.Component.assign(socket, :frag, %{frag | lauf: lauf})}

      %{id: ^lauf_id, rest: []} = lauf ->
        # Echte Belege, sobald die Fakten-Spalte geladen ist — der `↗` springt
        # dann an eine echte Stelle. Ohne sie bleiben die erfundenen.
        a =
          Synthetisch.antwort(
            lauf.art,
            Map.get(socket.assigns, :facts, []),
            Map.get(socket.assigns, :sessions, [])
          )

        eintrag = %{art: :antwort, text: a.text, belege: a.belege, zeilen: lauf.zeilen}

        {:noreply,
         Phoenix.Component.assign(socket, :frag, %{
           frag
           | lauf: nil,
             verlauf: frag.verlauf ++ [eintrag]
         })}

      _ ->
        {:noreply, socket}
    end
  end

  defp auf(socket, offen?),
    do: Phoenix.Component.update(socket, :frag, &%{&1 | offen?: offen?})

  defp starte(socket, frage) do
    frag = socket.assigns.frag
    brich_ab(frag.lauf)

    art = Synthetisch.lauf_fuer(frage)
    [erst | _] = schritte = Synthetisch.schritte(art)
    id = System.unique_integer([:positive])
    timer = Process.send_after(self(), {:frag_schritt, id}, erst.ms)

    Phoenix.Component.assign(socket, :frag, %{
      frag
      | frage: "",
        verlauf: frag.verlauf ++ [%{art: :frage, text: frage}],
        lauf: %{id: id, art: art, rest: schritte, zeilen: [], timer: timer}
    })
  end

  # Eine zweite Frage während eines laufenden Laufs bricht den ersten ab. Ohne
  # das feuerte sein Timer weiter — `schritt/2` verwürfe den Nachzügler zwar
  # (die id passt nicht mehr), aber ein Timer, den niemand abbestellt, ist die
  # Sorte Rest, die sich in einer langen Sitzung sammelt.
  defp brich_ab(%{timer: t}) when is_reference(t), do: Process.cancel_timer(t)
  defp brich_ab(_), do: :ok

  # ——— Markup ———————————————————————————————————————————————————

  attr(:frag, :map, required: true)
  attr(:campaign_id, :string, required: true)

  @doc """
  Sprechblase und Fenster. Beide liegen dauerhaft im DOM: Der Dialog wird
  **nicht** per `:if` ein- und ausgehängt, weil er sonst bei jedem Öffnen neu
  mountet und Position wie Größe verlöre. Geöffnet wird er vom Hook über
  `data-offen` — der Server sagt, was gelten soll, der Client führt es aus.
  """
  def fenster(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="frag_oeffnen"
      class={[
        "fixed bottom-6 right-6 z-40 h-14 w-14 rounded-full shadow-lg",
        "bg-accent text-bg-0 text-2xl leading-none",
        "hover:scale-105 transition-transform",
        @frag.offen? && "hidden"
      ]}
      aria-label="Frag die Runde öffnen"
      title="Frag die Runde"
    >
      💬
      <span
        :if={offene(@frag) > 0}
        class="absolute -top-1 -right-1 h-5 w-5 rounded-full bg-warning text-bg-0 text-[11px] flex items-center justify-center"
      >
        {offene(@frag)}
      </span>
    </button>

    <dialog
      id="frag-fenster"
      phx-hook="FragFenster"
      phx-mounted={JS.ignore_attributes(["open", "style"])}
      data-offen={to_string(@frag.offen?)}
      data-campaign-id={@campaign_id}
      aria-label="Frag die Runde"
      class={[
        # `panel` bleibt — Fläche und Radius wie bei jedem anderen Panel. Neu
        # ist allein die Randfarbe: `border-primary` überschreibt dessen
        # `border-border`, damit das Fenster auffällt (Maintainer, 25.09.2026:
        # „nur eine zusätzliche dünne Umrandung in Cyan"). Sonst ändert sich
        # an den Farben nichts.
        "panel border-primary z-40 p-0 m-0 fixed shadow-2xl",
        "w-[420px] h-[560px] min-w-[300px] min-h-[240px]",
        "max-w-[92vw] max-h-[85vh] resize overflow-hidden flex-col",
        "backdrop:bg-transparent open:flex"
      ]}
    >
      <div
        data-frag-griff
        class="flex items-center gap-2 px-3 py-2 border-b border-ink-2/20 cursor-move select-none shrink-0"
      >
        <span class="text-ink-2/40 text-xs">⣿</span>
        <span class="font-display text-sm text-ink-0 grow">Frag die Runde</span>
        <button
          type="button"
          phx-click="frag_schliessen"
          class="text-ink-2/60 hover:text-ink-0 px-1"
          aria-label="Fenster schließen"
          title="Schließen — das Gespräch wird verworfen"
        >
          ✕
        </button>
      </div>

      <div class="grow overflow-y-auto overscroll-contain px-3 py-2 space-y-3 text-sm">
        <div :if={@frag.verlauf == []} class="space-y-3">
          <p :if={@frag.befunde != []} class="text-[11px] uppercase tracking-widest text-warning/80">
            ⚠ {length(@frag.befunde)} offene Befunde
          </p>
          <button
            :for={b <- @frag.befunde}
            type="button"
            phx-click="frag_befund"
            phx-value-id={b.id}
            class="w-full text-left rounded-lg border border-warning/40 bg-warning/5 px-3 py-2 hover:bg-warning/10"
          >
            <span class="block text-ink-0">{b.titel}</span>
            <span class="block text-ink-2/70 text-xs mt-0.5">{b.text}</span>
          </button>

          <p class="text-[11px] uppercase tracking-widest text-ink-2/50 pt-2">Oder frag etwas</p>
          <button
            :for={v <- Synthetisch.vorschlaege()}
            type="button"
            phx-click="frag_vorschlag"
            phx-value-text={v}
            class="w-full text-left rounded-lg border border-ink-2/20 px-3 py-1.5 text-ink-1 hover:border-accent/50"
          >
            {v}
          </button>
        </div>

        <div :for={e <- @frag.verlauf}>
          <.eintrag eintrag={e} />
        </div>

        <.konsole :if={@frag.lauf} lauf={@frag.lauf} />
      </div>

      <form phx-submit="frag_senden" class="shrink-0 border-t border-ink-2/20 p-2">
        <div class="flex gap-2">
          <input
            type="text"
            name="frage"
            placeholder="Deine Frage…"
            autocomplete="off"
            class="grow bg-bg-0 border border-ink-2/25 rounded-lg px-3 py-1.5 text-sm text-ink-0 placeholder:text-ink-2/40"
          />
          <button type="submit" class="text-accent px-2" aria-label="Frage abschicken">➤</button>
        </div>
        <p class="text-[10px] text-ink-2/50 mt-1.5 leading-snug">
          Antworten stammen nur aus den geprüften Fakten, mit Beleg — und sagen es,
          wenn nichts in den Aufzeichnungen steht.
        </p>
      </form>
    </dialog>
    """
  end

  attr(:eintrag, :map, required: true)

  defp eintrag(%{eintrag: %{art: :frage}} = assigns) do
    ~H"""
    <p class="text-right text-ink-0 bg-accent/10 rounded-lg px-3 py-1.5 ml-8">{@eintrag.text}</p>
    """
  end

  defp eintrag(%{eintrag: %{art: :befund}} = assigns) do
    ~H"""
    <div class="rounded-lg border border-warning/40 bg-warning/5 px-3 py-2">
      <p class="text-ink-0">{@eintrag.titel}</p>
      <p class="text-ink-2/70 text-xs mt-0.5">{@eintrag.text}</p>
      <.belege belege={@eintrag.belege} />
      <textarea
        placeholder="Deine Antwort…"
        rows="2"
        class="w-full mt-2 bg-bg-0 border border-ink-2/25 rounded px-2 py-1 text-xs text-ink-0 placeholder:text-ink-2/40"
      ></textarea>
    </div>
    """
  end

  defp eintrag(%{eintrag: %{art: :antwort}} = assigns) do
    ~H"""
    <div class="mr-8">
      <p class="text-ink-1 leading-relaxed">{@eintrag.text}</p>
      <.belege belege={@eintrag.belege} />
      <details :if={@eintrag.zeilen != []} class="mt-1.5">
        <summary class="text-[11px] text-ink-2/50 cursor-pointer">Weg zur Antwort</summary>
        <.zeilen zeilen={@eintrag.zeilen} />
      </details>
    </div>
    """
  end

  attr(:belege, :list, required: true)

  defp belege(assigns) do
    ~H"""
    <ul :if={@belege != []} class="mt-1.5 space-y-0.5">
      <li :for={b <- @belege} class="flex items-start gap-1.5 text-xs text-ink-2/70">
        <button
          type="button"
          phx-click={b[:utterance_id] && "focus_utterance"}
          phx-value-id={b[:utterance_id]}
          disabled={is_nil(b[:utterance_id])}
          class={[
            "shrink-0",
            if(b[:utterance_id],
              do: "text-accent/70 hover:text-accent",
              else: "text-ink-2/25 cursor-default"
            )
          ]}
          title={
            if b[:utterance_id],
              do: "Zur Stelle im Protokoll springen",
              else: "Kein Ziel — dieser Beleg ist erfunden (keine Fakten geladen)"
          }
        >
          ↗
        </button>
        <span class="font-mono text-[10px] text-ink-2/50 shrink-0">
          {b.sitzung}{if b.block != "", do: "·#{b.block}"}
        </span>
        <span class="truncate">{b.text}</span>
      </li>
    </ul>
    """
  end

  attr(:lauf, :map, required: true)

  defp konsole(assigns) do
    ~H"""
    <div class="mr-8 rounded-lg bg-bg-0/60 border border-ink-2/15 px-2 py-1.5">
      <.zeilen zeilen={@lauf.zeilen} />
      <p
        id="frag-warten"
        phx-hook="FragWarten"
        phx-update="ignore"
        data-sprueche={Jason.encode!(Warten.sprueche())}
        data-wechsel-ms={Warten.wechsel_ms()}
        class="text-[11px] text-ink-2/50 mt-1 flex items-center gap-1.5"
      >
        <span data-spinner class="font-mono text-primary">⠋</span>
        <span data-spruch>Wälze Folianten …</span>
      </p>
    </div>
    """
  end

  attr(:zeilen, :list, required: true)

  defp zeilen(assigns) do
    ~H"""
    <ul class="space-y-0.5 font-mono text-[11px]">
      <li :for={z <- @zeilen} class={z.art == :denken && "text-ink-2/50 italic font-sans" || "text-ink-1"}>
        <span :if={z.art == :werkzeug}>🔎 {z.text}</span>
        <span :if={z.art == :werkzeug and z.treffer} class="text-ink-2/50">→ {z.treffer}</span>
        <span :if={z.art == :denken}>💭 {z.text}</span>
        <span :if={z.art == :fertig}>✍ {z.text}</span>
      </li>
    </ul>
    """
  end
end
