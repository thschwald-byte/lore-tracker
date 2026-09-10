defmodule Worker.Jack.Fortsetzung do
  @moduledoc """
  Was ein Durchgang dem nächsten übergibt, und das Laden daraus — das
  Gegenstück zu `bestandLaden()` im Spike. Ohne das kennt jeder Lauf nur seine
  eigenen Einträge und trägt alles noch einmal ein: über vier gemessene Läufe
  waren 56 % der gefundenen Blöcke Wiederholung. Jack bekommt den Bestand
  dabei nicht zu sehen; er meldet sich nur, wenn eine neue Aussage mit einer
  bestehenden kollidiert (Toms Entscheidung, #1196).

  Die Ablage eines Durchgangs (`Worker.Jack.Abbild.schreiben/2`) enthält
  `aussagen.jsonl` (der Bestand) und `fortsetzung.json` (`daten/1`):
  Gedächtnis, Kollisionen und die Position von `weiter`. `laden/2` baut
  daraus den Stand für den nächsten Durchgang. Ein `"ordnung"`-Schlüssel aus
  Ablagen mit Phase 3 (vor dem 10.09.) wird übergangen.

  Wie im Spike:

    * Der Durchgang wird aus dem Bestand abgeleitet, nicht von außen gesetzt:
      höchstes `_iter` plus eins; ein Bestand ohne `_iter` war trotzdem ein
      Durchgang.
    * ABLAUF-Einträge, deren Schlüssel kein Blockbereich ist, werden
      übergangen: eine Selbstauskunft über den Arbeitsstand kam sonst als
      „fertig“ beim nächsten Durchgang an.

  **Abweichungen vom Spike:**

    * Eine Zeile in `aussagen.jsonl`, die kein JSON ist, ist ein Fehler; der
      Spike übersprang sie still und lief mit einem Bestand weiter, dem eine
      Aussage fehlte.
    * Das Gedächtnis kommt strukturiert aus `fortsetzung.json`, nicht
      zurückgelesen aus `notizen.txt`.
    * Die Position von `weiter` gilt je Phase; abgelegt wird nur die der
      Phase, die gerade lief.

  Nicht übernommen, wie im Spike: offene GUIDs (sie gelten nur für den
  nächsten Aufruf), Versuchszähler, Lesefortschritt.
  """

  alias Worker.Jack.{Gedaechtnis, Stand}

  @doc "Was der nächste Durchgang übernimmt, JSON-fähig."
  @spec daten(Stand.t()) :: map()
  def daten(%Stand{} = s) do
    %{
      "register" => s.register,
      "kollisionen" => Map.new(s.kollisionen, fn {nr, n} -> {to_string(nr), n} end),
      "beppo_pos" => %{to_string(s.phase) => s.beppo_pos}
    }
  end

  @doc """
  Der Stand für einen neuen Durchgang: `Stand.neu(opts)`, dazu, was im
  Verzeichnis `dir` abgelegt ist. Fehlen die Dateien, ist es der erste
  Durchgang. Fehlt das Verzeichnis oder ist eine Datei kaputt, ist das ein
  Fehler — ein Bestand, der still unvollständig geladen wird, führt zu
  Dubletten, die niemand bemerkt.
  """
  @spec laden(Path.t(), keyword()) :: {:ok, Stand.t()} | {:error, term()}
  def laden(dir, opts) do
    with true <- File.dir?(dir) || {:error, {:keine_ablage, dir}},
         {:ok, aussagen} <- jsonl(Path.join(dir, "aussagen.jsonl")),
         {:ok, f} <- json(Path.join(dir, "fortsetzung.json")) do
      s = opts |> Stand.neu() |> bestand(aussagen) |> fortsetzen(f, opts)
      {:ok, s}
    end
  end

  defp jsonl(pfad) do
    if File.exists?(pfad) do
      pfad
      |> File.read!()
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.reject(fn {z, _} -> String.trim(z) == "" end)
      |> Enum.reduce_while({:ok, []}, &zeile(pfad, &1, &2))
      |> then(fn
        {:ok, acc} -> {:ok, Enum.reverse(acc)}
        fehler -> fehler
      end)
    else
      {:ok, []}
    end
  end

  defp zeile(pfad, {z, n}, {:ok, acc}) do
    case Jason.decode(z) do
      {:ok, %{} = d} -> {:cont, {:ok, [d | acc]}}
      _ -> {:halt, {:error, {:kaputte_zeile, pfad, n}}}
    end
  end

  defp json(pfad) do
    with true <- File.exists?(pfad) || {:ok, %{}},
         {:ok, %{} = d} <- pfad |> File.read!() |> Jason.decode() do
      {:ok, d}
    else
      {:ok, %{}} -> {:ok, %{}}
      _ -> {:error, {:kaputte_datei, pfad}}
    end
  end

  defp bestand(s, aussagen) do
    aussagen = Enum.filter(aussagen, &is_integer(&1["nummer"]))

    s =
      Enum.reduce(aussagen, s, fn a, s ->
        s
        |> Stand.eintragen(a)
        |> Stand.themen_merken(a["threads"] || [])
        |> Stand.belegte_merken(a["source_refs"] || [])
      end)

    iter = for(a <- aussagen, is_integer(a["_iter"]), do: a["_iter"]) |> Enum.max(fn -> 0 end)

    %{
      s
      | lfd: aussagen |> Enum.map(& &1["nummer"]) |> Enum.max(fn -> s.lfd end),
        durchgang: if(aussagen == [], do: s.durchgang, else: max(iter + 1, 2))
    }
  end

  defp fortsetzen(s, f, opts) do
    %{
      s
      | register: register(f["register"] || []),
        kollisionen: kollisionen(f["kollisionen"] || %{}),
        beppo_pos: Keyword.get_lazy(opts, :beppo_pos, fn -> beppo_pos(f, s.phase) end)
    }
  end

  defp kollisionen(map), do: Map.new(map, fn {nr, n} -> {String.to_integer(nr), n} end)

  defp beppo_pos(f, phase), do: (f["beppo_pos"] || %{})[to_string(phase)] || 0

  defp register(liste) do
    for %{"abschnitt" => a, "schluessel" => k, "zeile" => z} = r <- liste,
        a != "ABLAUF" or Gedaechtnis.bereich(k) != nil do
      %{abschnitt: a, schluessel: k, zeile: z, bloecke: r["bloecke"] || []}
    end
  end
end
