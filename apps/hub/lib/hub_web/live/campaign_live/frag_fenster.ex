defmodule HubWeb.CampaignLive.FragFenster do
  @moduledoc """
  Issue #850, erster Schnitt: das Fenster „Frag die Runde" — Oberfläche mit
  echten Läufen des Frage-Jack im Worker (#850, S3).

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

  alias HubWeb.CampaignLive.{Core, FragFenster.Warten}
  alias Hub.Commands
  alias HubWeb.PipelineStatus
  alias Phoenix.LiveView.JS

  # Beispielfragen für das leere Fenster. Bewusst so gewählt, dass sie ohne
  # Kenntnis der Kampagne etwas liefern — die erste ist die billigste
  # Gegenprobe, ob überhaupt etwas ankommt.
  @vorschlaege [
    "Wer gehört zur Gruppe?",
    "Was ist in der letzten Sitzung passiert?",
    "Welche offenen Fäden gibt es?"
  ]

  @doc "Der Anfangszustand fürs Mount — eine Stelle, damit kein Feld vergessen wird (#1005)."
  @spec initial() :: map()
  def initial,
    do: %{offen?: false, verlauf: [], lauf: nil, frage: "", befunde: []}

  @doc "Beispielfragen fürs leere Fenster."
  @spec vorschlaege() :: [String.t()]
  def vorschlaege, do: @vorschlaege

  @doc """
  Der Befund an einer Fakt-Zeile, für das Zeichen in der Spalte. Fassade für
  das Template, das keine Aliase kennt.

  **Das Ziel des Klicks ist das Zeichen, nicht die Zeile.** Die Fakt-Zeile ist
  seit #916 bereits klickbar (claim, Figur, Strang, ausblenden); ein zweiter
  Klick-Sinn auf derselben Fläche wäre eine stille Kollision — man will
  kuratieren und bekommt ein Gesprächsfenster.
  """
  @spec befund_an_fakt(term()) :: String.t() | nil
  def befund_an_fakt(_fakt_id), do: nil

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

  # Der zweite Eingang: das Zeichen an einer Fakt-Zeile. Es stellt eine Frage
  # ZU DIESEM FAKT, statt eine leere Eingabe zu öffnen — wer das Objekt vor
  # sich hat, soll die Frage nicht abtippen müssen.
  #
  # Das Ziel des Klicks ist das ZEICHEN, nicht die Zeile: Die ist seit #916
  # bereits klickbar (claim, Figur, Strang, ausblenden), und ein zweiter
  # Klick-Sinn auf derselben Fläche wäre eine stille Kollision — man will
  # kuratieren und bekommt ein Gesprächsfenster.
  def event(socket, "frag_zu_fakt", %{"claim" => claim}) do
    case String.trim(claim || "") do
      "" -> {:noreply, auf(socket, true)}
      c -> {:noreply, socket |> auf(true) |> starte(frage_zu(c))}
    end
  end

  def event(socket, "frag_befund", _params), do: {:noreply, auf(socket, true)}

  # Der Claim wird gekürzt: Er geht als Nutzertext in den Auftrag, und ein
  # sehr langer Fakt machte die Frage unlesbar, ohne sie zu schärfen.
  defp frage_zu(claim) do
    kurz = if String.length(claim) > 200, do: String.slice(claim, 0, 200) <> " …", else: claim
    "Was wissen wir über: #{kurz}"
  end

  @doc """
  Nachzügler eines Wartetakts. **Die Klausel in der CampaignLive ist Pflicht**
  — sie hat keinen `handle_info`-Auffangzweig (#1149), jede unerwartete
  Nachricht bringt sie zum Absturz.

  Selbst getaktet wird hier nichts: Der Wartetext rotiert im Browser
  (`FragWarten`-Hook, `phx-update="ignore"`). Ein Server-Takt hätte für jede
  Sekunde Warten eine Nachricht und einen Diff erzeugt, ohne etwas zu leisten.
  """
  def schritt(socket, _lauf_id), do: {:noreply, socket}

  @doc """
  Die Antwort des Workers, über `HubWeb.PipelineStatus` auf dem Topic **dieses
  Laufs** — nicht auf dem der Kampagne: Fragt der Spielleiter „was plant der
  Schurke", läsen dort alle Spieler mit (#850).

  Eine Meldung zu einem Lauf, der nicht mehr der aktuelle ist, wird verworfen:
  Wer eine zweite Frage stellt, während die erste rechnet, will die zweite.
  """
  def antwort(socket, %{"kind" => "frage_strom", "frage_lauf_id" => id, "stuecke" => st}) do
    # **Der Strom geht per `push_event` an den Hook, NIE in die Assigns.**
    # Er wächst über den Lauf; in den Assigns würde er bei jedem Diff kopiert
    # und gehalten — die #1146-Klasse. Der Hook hängt an und deckelt selbst.
    case socket.assigns.frag.lauf do
      %{id: ^id} ->
        {:noreply, Phoenix.LiveView.push_event(socket, "frag_strom", %{lauf_id: id, stuecke: st})}

      _ ->
        {:noreply, socket}
    end
  end

  def antwort(socket, %{"frage_lauf_id" => id} = payload) do
    frag = socket.assigns.frag

    case frag.lauf do
      %{id: ^id} ->
        PipelineStatus.unsubscribe_frage(id)

        {:noreply,
         Phoenix.Component.assign(socket, :frag, %{
           frag
           | lauf: nil,
             verlauf: frag.verlauf ++ [eintrag_aus(payload, socket.assigns[:facts] || [])]
         })}

      _ ->
        {:noreply, socket}
    end
  end

  # `geprueft` reist mit, damit die Anzeige „gestützt" von „nur die IDs
  # geprüft" unterscheiden kann. Beide gleich zu zeigen wäre die stille
  # Behauptung von mehr Prüfung, als stattgefunden hat (#850, Messlauf).
  defp eintrag_aus(%{"kind" => "frage_antwort"} = p, fakten),
    do: %{
      art: :antwort,
      text: p["text"] || "",
      belege: belege_aus(p, fakten),
      geprueft: p["geprueft"],
      grund: p["grund"]
    }

  defp eintrag_aus(p, _fakten),
    do: %{art: :fehler, text: p["grund"] || "Der Lauf ist gescheitert."}

  # Der Beleg trägt die kurze ID für den Menschen (`S1-F12`) und eine
  # Utterance-ID fürs Springen. Die kommt aus den GELADENEN Fakten: Es gibt
  # kein `focus_fact`, nur `focus_utterance` (#114/#1095) — und ohne geladene
  # Fakten-Spalte gibt es kein Ziel. Dann bleibt der Knopf sichtbar inaktiv,
  # statt ins Leere zu führen.
  defp belege_aus(p, fakten) do
    nach_id = Map.new(fakten, &{&1["id"], &1})
    echte = p["fakt_ids"] || []

    (p["kurze_ids"] || [])
    |> Enum.with_index()
    |> Enum.map(fn {kurz, i} ->
      fakt_id = Enum.at(echte, i)
      %{kurz: kurz, fakt_id: fakt_id, utterance_id: erste_utterance(nach_id[fakt_id])}
    end)
  end

  defp erste_utterance(%{"quell_utterance_ids" => [u | _]}), do: u
  defp erste_utterance(_), do: nil

  defp auf(socket, offen?),
    do: Phoenix.Component.update(socket, :frag, &%{&1 | offen?: offen?})

  defp starte(socket, frage) do
    frag = socket.assigns.frag
    campaign = Core.perm_campaign(socket)
    snap = socket.assigns[:campaign] || %{}

    abbrechen(socket, frag.lauf)

    # Die Lauf-ID ist zugleich Adresse und Abbruch-Handle. Sie wird HIER
    # vergeben und HIER abonniert, **bevor** gefragt wird — sonst könnte die
    # Antwort vor dem Abonnement eintreffen und ins Leere laufen.
    id = UUIDv7.generate()
    PipelineStatus.subscribe_frage(id)
    # Frage → Denkstrom → Antwort, in dieser Reihenfolge (Maintainer,
    # 25.09.2026). Der Strom bekommt seinen Platz im Verlauf, BEVOR das erste
    # Stück kommt — sonst hätte der Hook, an den gepusht wird, kein Element.
    verlauf = frag.verlauf ++ [%{art: :frage, text: frage}, %{art: :strom, lauf_id: id}]

    case Commands.request_frage(snap["owner_discord_id"], campaign.id, frage, id) do
      0 ->
        PipelineStatus.unsubscribe_frage(id)

        Phoenix.Component.assign(socket, :frag, %{
          frag
          | frage: "",
            lauf: nil,
            verlauf:
              verlauf ++
                [
                  %{
                    art: :fehler,
                    text: "Gerade ist kein Worker verbunden — ohne ihn kann niemand antworten."
                  }
                ]
        })

      _ ->
        # Kein Leeren: Der Strom der vorigen Frage bleibt bei ihrer Antwort
        # stehen (Maintainer). Jeder Lauf hat sein eigenes Element, adressiert
        # über die Lauf-ID.
        Phoenix.Component.assign(socket, :frag, %{
          frag
          | frage: "",
            verlauf: verlauf,
            lauf: %{id: id}
        })
    end
  end

  # Ein laufender Lauf wird beim Worker ABGEBROCHEN, nicht nur vergessen: Er
  # hielte sonst die Grafikkarte für eine Antwort, die niemand mehr sehen will.
  defp abbrechen(_socket, nil), do: :ok

  defp abbrechen(socket, %{id: id}) do
    PipelineStatus.unsubscribe_frage(id)
    snap = socket.assigns[:campaign] || %{}
    Commands.abbrechen_frage(snap["owner_discord_id"], Core.perm_campaign(socket).id, id)
  end

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

      <div
        data-frag-verlauf
        class="grow overflow-y-auto overscroll-contain px-3 py-2 space-y-3 text-sm"
      >
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
            :for={v <- vorschlaege()}
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

        <.warten :if={@frag.lauf} />
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
      <.pruefung eintrag={@eintrag} />
    </div>
    """
  end

  defp eintrag(%{eintrag: %{art: :strom}} = assigns) do
    ~H"""
    <.strom lauf_id={@eintrag.lauf_id} />
    """
  end

  defp eintrag(%{eintrag: %{art: :fehler}} = assigns) do
    ~H"""
    <p class="mr-8 rounded-lg border border-warning/40 bg-warning/5 px-3 py-2 text-ink-1 text-xs">
      {@eintrag.text}
    </p>
    """
  end

  attr(:eintrag, :map, required: true)

  # Was die Prüfung ergeben hat — und zwar unterschieden. „belegt" und
  # „geprüft" sind nicht dasselbe: Das Werkzeug prüft, ob es die genannten
  # Fakten GIBT, die Stützungsprüfung, ob sie die Antwort TRAGEN. Am Messlauf
  # vom 25.09.2026 fiel beides auseinander — eine Antwort mit echten IDs,
  # deren Aussage dort nicht steht. Wo die Prüfung nicht zustande kam, sagt
  # die Plakette das, statt die Antwort als geprüft auszugeben.
  defp pruefung(%{eintrag: %{geprueft: "gestuetzt"}} = assigns) do
    ~H"""
    <p class="mt-1 text-[11px] text-success/80">✓ von den genannten Fakten getragen</p>
    """
  end

  defp pruefung(%{eintrag: %{geprueft: "nicht_gestuetzt"}} = assigns) do
    ~H"""
    <p class="mt-1 text-[11px] text-warning/90">
      ⚠ nicht vollständig belegt<span :if={@eintrag[:grund]}>: {@eintrag.grund}</span>
    </p>
    """
  end

  defp pruefung(%{eintrag: %{geprueft: "ohne_beleg"}} = assigns) do
    ~H"""
    <p class="mt-1 text-[11px] text-ink-2/50">ohne Beleg — die Antwort nennt keine Fakten</p>
    """
  end

  defp pruefung(%{eintrag: %{geprueft: "ungeprueft"}} = assigns) do
    ~H"""
    <p class="mt-1 text-[11px] text-ink-2/60" title="Das Prüfmodell hat nicht geantwortet">
      ○ nicht geprüft — nur die Fakt-IDs sind bestätigt
    </p>
    """
  end

  defp pruefung(assigns), do: ~H""

  attr(:belege, :list, required: true)

  # Die Fakten, auf die sich die Antwort stützt. Der Sprung geht über
  # `focus_fact` an die Fakten-Spalte — sie trägt seit #1095 `data-anchor-id`
  # und läuft im Scroll-Sync mit.
  defp belege(assigns) do
    ~H"""
    <ul :if={@belege != []} class="mt-1.5 flex flex-wrap gap-1">
      <li :for={b <- @belege}>
        <button
          type="button"
          phx-click={b[:utterance_id] && "focus_utterance"}
          phx-value-id={b[:utterance_id]}
          disabled={is_nil(b[:utterance_id])}
          class={[
            "font-mono text-[10px] rounded px-1.5 py-0.5 border",
            if(b[:utterance_id],
              do: "border-accent/40 text-accent/80 hover:border-accent hover:text-accent",
              else: "border-ink-2/20 text-ink-2/40 cursor-default"
            )
          ]}
          title={
            if(b[:utterance_id],
              do: "Zur Stelle im Protokoll springen",
              else: "Kein Ziel — die Fakten-Spalte ist nicht geladen"
            )
          }
        >
          {b.kurz}
        </button>
      </li>
    </ul>
    """
  end

  attr(:lauf_id, :string, required: true)

  # Der Denkstrom EINES Laufs, adressiert über seine Lauf-ID. Der Hook füllt
  # ihn per push_event — hier steht bewusst nichts aus den Assigns, sonst
  # wüchse er in den Socket (#1146). `phx-update="ignore"` schützt ihn davor,
  # dass morphdom ihn beim nächsten Diff leert; deshalb überlebt er die
  # Antwort und bleibt auch stehen, wenn die nächste Frage kommt.
  #
  # **Kein Scrollbalken und kein Deckel** (Maintainer, 25.09.2026): Er wächst
  # mit. Gescrollt wird im Fenster, nicht im Strom — ein Kasten mit eigenem
  # Balken verbirgt genau das, was man lesen will.
  defp strom(assigns) do
    ~H"""
    <div
      id={"frag-strom-#{@lauf_id}"}
      data-lauf-id={@lauf_id}
      phx-hook="FragStrom"
      phx-update="ignore"
      class="mr-8 rounded-lg bg-bg-0/60 px-2 py-1.5 space-y-0.5 font-mono text-[10px] leading-snug empty:hidden empty:p-0"
    >
    </div>
    """
  end

  # Der Wartetext dreht im Browser und verschwindet mit dem Lauf — er sagt
  # „es läuft noch", und das stimmt danach nicht mehr.
  defp warten(assigns) do
    ~H"""
    <p
      id="frag-warten"
      phx-hook="FragWarten"
      phx-update="ignore"
      data-sprueche={Jason.encode!(Warten.sprueche())}
      data-wechsel-ms={Warten.wechsel_ms()}
      class="mr-8 text-[11px] text-ink-2/50 flex items-center gap-1.5 px-2"
    >
      <span data-spinner class="font-mono text-primary">⠋</span>
      <span data-spruch>Wälze Folianten …</span>
    </p>
    """
  end
end
