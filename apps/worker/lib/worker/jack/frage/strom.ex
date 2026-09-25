defmodule Worker.Jack.Frage.Strom do
  @moduledoc """
  Sammelt den Denkstrom eines Frage-Laufs und gibt ihn **gedrosselt** weiter
  (#850, Maintainer: „der Denkstrom soll in das Chatfenster").

  **Warum ein eigener Prozess.** `Worker.Agent` schickt jede Protokollzeile an
  einen Beobachter — eine pid. Der Task, der den Lauf fährt, kann das nicht
  sein: Er hängt in `GpuQueue.run_frei/2` und käme nie dazu, seine Mailbox zu
  leeren.

  **Warum gedrosselt.** Beim Denken kommt ein `delta` je Token — bei einem Lauf
  mit 12 Runden sind das Tausende Nachrichten. Einzeln durch Hub und PubSub
  wäre das dieselbe Klasse wie die 50 Diffs je Wartetext, gegen die #1200 den
  Server-Takt abgeschafft hat. Gesammelt wird deshalb bis `@takt_ms`, dann geht
  ein Stück.

  **Was NICHT durchgereicht wird: die Werkzeug-Ergebnisse.** Ein `fakten(1,
  100)` liefert Kilobytes, und die stehen ohnehin schon in der Kampagne — sie
  durch den Hub zu schicken, hieße den Snapshot ein zweites Mal zu übertragen
  (#1146). Der Strom trägt das **Denken** und **welches Werkzeug mit welchen
  Argumenten** gerufen wurde; was zurückkam, nur als Zahl.

  **Ehrliche Grenze:** Das Denken ist Modellausgabe und kann alles enthalten,
  auch Namen aus dem Mitschnitt. Es geht an den Fragenden — denselben, der die
  Antwort bekommt —, nicht an die Kampagne; über den Lauf-Topic (#850, S2).
  """

  @takt_ms 600

  @doc """
  Startet den Sammler. `melden` bekommt `{:frage_strom, lauf_id, stuecke}` mit
  einer Liste von Karten (`%{art:, text:}`).

  Der Prozess endet, wenn der Lauf endet (`beenden/1`) — oder mit dem Task,
  der ihn gestartet hat (`spawn_link`).
  """
  @spec starten(String.t(), (term() -> any())) :: pid()
  def starten(lauf_id, melden) do
    spawn_link(fn -> schleife(%{lauf_id: lauf_id, melden: melden, puffer: [], denken: ""}) end)
  end

  @doc "Beendet den Sammler und schickt, was noch im Puffer liegt."
  @spec beenden(pid()) :: :ok
  def beenden(pid) when is_pid(pid) do
    send(pid, :beenden)
    :ok
  end

  # ─── Schleife ─────────────────────────────────────────────────────────

  defp schleife(z) do
    receive do
      {:agent, daten} -> z |> aufnehmen(daten) |> schleife()
      :beenden -> senden(z)
    after
      @takt_ms -> z |> senden() |> schleife()
    end
  end

  # Das Denken kommt Token für Token und wird zusammengeklebt, bis es rausgeht
  # — ein Stück je Token wäre im Fenster ein Flackern, kein Text.
  defp aufnehmen(z, %{"ereignis" => "delta", "art" => "denken", "text" => t}),
    do: %{z | denken: z.denken <> t}

  defp aufnehmen(z, %{"ereignis" => "antwort", "aufrufe" => aufrufe}) when aufrufe != [],
    do: %{z | puffer: z.puffer ++ Enum.map(aufrufe, &werkzeug_stueck/1)}

  defp aufnehmen(z, %{"ereignis" => "ergebnis"} = d),
    do: %{z | puffer: z.puffer ++ [%{art: "ergebnis", text: ergebnis_text(d)}]}

  defp aufnehmen(z, _andere), do: z

  defp werkzeug_stueck(a) do
    name = a["name"] || "?"
    args = a["argumente"] || a["arguments"] || %{}
    %{art: "werkzeug", text: "#{name}(#{kurz_args(args)})"}
  end

  # Die Argumente kurz: Ein `notiz`-Aufruf kann Kilobytes tragen, und im
  # Fenster interessiert, WAS gefragt wurde, nicht der ganze Rumpf.
  defp kurz_args(args) when is_map(args) do
    args
    |> Enum.map(fn {k, v} -> "#{k}: #{kurz(v)}" end)
    |> Enum.join(", ")
    |> kurz()
  end

  defp kurz_args(_), do: ""

  defp kurz(v) when is_binary(v) do
    if String.length(v) > 60, do: String.slice(v, 0, 60) <> "…", else: v
  end

  defp kurz(v) when is_list(v), do: "[#{length(v)}]"
  defp kurz(v), do: to_string(v)

  # Vom Ergebnis nur die Größe: Der Inhalt steht schon in der Kampagne.
  defp ergebnis_text(d) do
    case d["ergebnis"] || d["text"] do
      t when is_binary(t) -> "#{zeilen(t)} Zeilen"
      _ -> "ok"
    end
  end

  defp zeilen(t), do: t |> String.split("\n") |> length()

  defp senden(%{puffer: [], denken: ""} = z), do: z

  defp senden(z) do
    stuecke =
      if z.denken == "",
        do: z.puffer,
        else: z.puffer ++ [%{art: "denken", text: z.denken}]

    z.melden.({:frage_strom, z.lauf_id, stuecke})
    %{z | puffer: [], denken: ""}
  end
end
