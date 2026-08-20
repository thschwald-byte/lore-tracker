defmodule HubWeb.CampaignLive.Laufband do
  @moduledoc """
  Issue #1122: das Laufband — was die Pipeline gerade tut und was noch aussteht.

  Es trägt die Spalten der Ansicht in deren Reihenfolge und läuft **von rechts
  nach links**, die Richtung, in der die Daten durch die Spalten wandern
  (Protokoll → Geglättet → Fakten → Resümee → Epos/Chronik). Dafür haben
  Geglättet und Fakten in #1122 die Plätze getauscht; vorher wäre der
  Fortschrittspunkt zwischen den beiden einmal rückwärts gesprungen.

  Sichtbar nur, solange ein Lauf aktiv ist. Die Zahlen (`4/7`) bedeuten **vier
  sind fertig**, nicht „bei Nummer vier" — bei später auf mehrere Worker
  verteilten Batches kann Chunk 5 vor Chunk 2 fertig werden.

  Stufen ohne zählbare Einheiten (Resümee, Chronik, Epos sind je ein einzelner
  Aufruf) zeigen bewusst **keine** Zahl statt eines wertlosen `1/1`.
  """

  use Phoenix.Component

  alias Shared.PipelineStufen

  # Ab wann ein Lauf verdächtig still ist. Der Worker-Zustand lebt im
  # Arbeitsspeicher: stirbt der Prozess mitten im Lauf, bleibt die letzte Stufe
  # als „läuft" stehen. Genau diese Verwechslung ließ eine frühere
  # Replay-Anzeige einen längst toten Lauf als aktiv zeigen — das Band sagt
  # deshalb „ohne Regung seit …", statt Fortschritt zu behaupten.
  @still_ms 10 * 60 * 1000

  attr(:lauf, :map, default: nil)
  attr(:sessions, :list, default: [])
  attr(:replay, :map, default: nil)
  attr(:admin?, :boolean, default: false)

  def pipeline_band(assigns) do
    ~H"""
    <div
      :if={sichtbar?(@lauf, @replay)}
      class="px-4 py-3 border-b border-bg-3/60 bg-bg-1/40"
      aria-live="polite"
    >
      <div :if={@lauf} class="flex items-baseline gap-2 mb-2 text-[11px]">
        <span class="text-sm" aria-hidden="true">⚙</span>
        <span class="text-ink-1 font-medium">{session_label(@lauf, @sessions)}</span>
        <span class="text-ink-2/70">
          Schritt {schritt(@lauf)} von {PipelineStufen.anzahl()} · seit {dauer(@lauf["gestartet_vor_ms"])}
        </span>
        <span :if={still?(@lauf)} class="text-warning">
          · ohne Regung seit {dauer(@lauf["still_seit_ms"])}
        </span>
      </div>

      <%!-- Rechts nach links: dieselbe Ordnung wie die Spalten darunter.
           flex-row-reverse statt einer umgedrehten Liste, damit die
           Lesereihenfolge im DOM die LAUF-Reihenfolge bleibt — für
           Screenreader ist „Glättung, Extraktion, …" die sinnvolle Folge. --%>
      <ol :if={@lauf} class="flex flex-row-reverse justify-end items-start gap-0">
        <li :for={stufe <- @lauf["stufen"]} class="flex flex-row-reverse items-center">
          <div class="flex flex-col items-center px-2 min-w-[4.5rem]">
            <span class={["text-[13px] leading-none", punkt_klasse(stufe)]} aria-hidden="true">
              {punkt(stufe)}
            </span>
            <span class={["text-[10px] mt-1 text-center", titel_klasse(stufe)]}>
              {stufe["titel"]}
            </span>
            <span :if={zahl(stufe)} class="text-[10px] text-ink-2/70 font-medium tabular-nums">
              {zahl(stufe)}
            </span>
            <span class="sr-only">{vorlese_text(stufe)}</span>
          </div>
          <span
            :if={not erste?(stufe, @lauf)}
            class={["h-px w-6 mt-[6px]", strich_klasse(stufe)]}
            aria-hidden="true"
          />
        </li>
      </ol>

      <%!-- Zweite Zeile: der Lauf ÜBER die Sessions. Sie ersetzt den früheren
           eigenen Replay-Banner — zwei Anzeigen für dieselbe Sache hätten
           auseinanderlaufen können. Der State trägt Atom-Keys. --%>
      <div
        :if={@replay}
        class={[
          "text-[11px] text-ink-2/80 flex items-center gap-3",
          @lauf && "mt-2 pt-2 border-t border-bg-3/40"
        ]}
      >
        <span class="inline-block w-2 h-2 rounded-full bg-warning animate-pulse" aria-hidden="true" />
        <span>
          Replay: Session {@replay[:current] || "?"} von {@replay[:total] || "?"}
          <span :if={@replay[:session_number]} class="text-ink-2/60">
            (Nr. {@replay[:session_number]})
          </span>
          · Resümee, Epos und Chronik werden dabei überschrieben
        </span>
        <.link
          :if={@admin?}
          navigate="/admin/jobs"
          class="ml-auto text-[10px] text-accent hover:underline"
        >
          GPU-Queue
        </.link>
      </div>
    </div>
    """
  end

  # ─── Ableitungen (public für Tests) ────────────────────────────────

  @doc """
  Das Band steht, solange etwas läuft — ein Einzellauf ODER ein Replay.

  Der Replay-Teil ist wichtig: zwischen zwei Sessions gibt es kurz keinen
  aktiven Einzellauf, und ohne diese Bedingung flackerte die Anzeige bei jedem
  Sessionwechsel weg.
  """
  def sichtbar?(lauf, replay), do: (lauf && lauf["aktiv"] == true) || replay != nil

  @doc "Nummer der Stufe, die gerade läuft — sonst die zuletzt erledigte."
  def schritt(%{"stufen" => stufen}) do
    laufend = Enum.find_index(stufen, &(&1["status"] == "laeuft"))

    fertig =
      stufen
      |> Enum.with_index()
      |> Enum.filter(fn {s, _} -> s["status"] in ["fertig", "fehler"] end)
      |> List.last()

    cond do
      laufend -> laufend + 1
      fertig -> elem(fertig, 1) + 1
      true -> 1
    end
  end

  def schritt(_), do: 1

  @doc """
  Die Zahl an der Stufe — `nil`, wo es nichts zu zählen gibt.

  Auch `nil`, solange die Gesamtzahl unbekannt ist: die Extraktion weiß erst
  nach dem Chunking, wie viele Chunks es sind, und „3/?" wäre keine Auskunft.
  """
  def zahl(%{"gesamt" => nil}), do: nil
  def zahl(%{"gesamt" => 0}), do: nil
  def zahl(%{"fertig" => f, "gesamt" => g}), do: "#{f}/#{g}"
  def zahl(_), do: nil

  @doc "Läuft der Lauf, ohne sich zu regen? Dann ist „läuft\" kein Beweis mehr."
  def still?(%{"still_seit_ms" => ms}) when is_integer(ms), do: ms > @still_ms
  def still?(_), do: false

  defp punkt(%{"status" => "fertig"}), do: "✓"
  defp punkt(%{"status" => "fehler"}), do: "✕"
  defp punkt(%{"status" => "laeuft"}), do: "◍"
  defp punkt(_), do: "○"

  defp punkt_klasse(%{"status" => "fertig"}), do: "text-success"
  defp punkt_klasse(%{"status" => "fehler"}), do: "text-danger"
  defp punkt_klasse(%{"status" => "laeuft"}), do: "text-accent animate-pulse"
  defp punkt_klasse(_), do: "text-ink-2/40"

  defp titel_klasse(%{"status" => "laeuft"}), do: "text-accent font-medium"
  defp titel_klasse(%{"status" => "offen"}), do: "text-ink-2/40"
  defp titel_klasse(_), do: "text-ink-2/80"

  defp strich_klasse(%{"status" => "offen"}), do: "bg-bg-3"
  defp strich_klasse(_), do: "bg-success/50"

  defp erste?(stufe, %{"stufen" => [erste | _]}), do: stufe["name"] == erste["name"]
  defp erste?(_, _), do: false

  # Farbe und Symbol tragen die Aussage doppelt — ein Screenreader liest hier
  # den Klartext (A11y-Basis, #67-Vorarbeit).
  defp vorlese_text(%{"titel" => t, "status" => status} = stufe) do
    zusatz = if zahl(stufe), do: ", #{zahl(stufe)} erledigt", else: ""
    "#{t}: #{lesbar(status)}#{zusatz}"
  end

  defp lesbar("fertig"), do: "fertig"
  defp lesbar("fehler"), do: "fehlgeschlagen"
  defp lesbar("laeuft"), do: "läuft gerade"
  defp lesbar(_), do: "steht noch aus"

  defp session_label(%{"session_id" => sid}, sessions) do
    case Enum.find(sessions, &(&1["id"] == sid)) do
      %{"number" => n} when not is_nil(n) -> "Session #{n}"
      _ -> "Session"
    end
  end

  defp session_label(_, _), do: "Session"

  defp dauer(ms) when is_integer(ms) and ms >= 0 do
    s = div(ms, 1000)

    cond do
      s < 60 -> "#{s}s"
      s < 3600 -> "#{div(s, 60)}:#{pad(rem(s, 60))}"
      true -> "#{div(s, 3600)}:#{pad(div(rem(s, 3600), 60))}:#{pad(rem(s, 60))}"
    end
  end

  defp dauer(_), do: "—"

  defp pad(n), do: String.pad_leading("#{n}", 2, "0")
end
