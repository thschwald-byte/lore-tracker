defmodule Worker.Teststage do
  @moduledoc """
  Der Teststage-Default als Ereignis-Abzug (#1260).

  Der Default einer Teststage ist seit dem 26.09.2026 **seattleV5** — eine
  Kampagne mit vier Sitzungen, tausenden Protokollzeilen und echten Artefakten.
  Nur an ihr zeigen sich die Dinge, um die es seit Monaten geht: Speicherspitzen
  (#1087 ff.), Fenster, Jack-Läufe, der Trichter der Chronik. Die Romeo-Demo ist
  dafür zu klein.

  **Sie darf nicht ins Repo.** Der Mitschnitt trägt die echten Namen, Handles
  und Gespräche der Runde; das Repo ist öffentlich. Deshalb liegt der Abzug
  außerhalb (`standard_verzeichnis/0`), und `pfad_erlaubt?/2` weist einen Pfad
  im Arbeitsbaum ab.

  **Ereignisse, nicht Mnesia.** Ein Mnesia-Archiv hängt am Knotennamen: Ein
  Abzug von Port 4005 lässt sich auf 4001 nicht starten, und genau daran ist
  der Versuch am 26.09. gescheitert. Ereignisse sind die kanonische Quelle und
  auf jedem Worker einspielbar — der Weg, auf dem seattleV4 und V5 überhaupt
  auf die Teststages kamen.

  **Eine Zeile je Ereignis, vier Schlüssel**: `event_id`, `hub_seq`, `payload`,
  `ts`. Die Form ist die von `Worker.Materializer.do_apply/1` — **String-Keys,
  und `ts` gehört dazu**: Mit Atom-Keys wirft der Materializer
  `FunctionClauseError` und reisst den Worker um (am 25.09. genau so passiert),
  und ohne `ts` greift der Auffangzweig und das Ereignis wird **still**
  verworfen.

  **Sortiert wird über alle Dateien zusammen, nach `ts`.** Die Dateien sind je
  Tabelle getrennt (`worker_events_global`, `worker_campaign_events_<id>`) und
  überlappen nicht, aber die Kausalität läuft quer: Eine Glättung liegt global,
  die Fakten dazu in der Kampagnentabelle. Datei für Datei einzuspielen hiesse,
  Fakten vor ihrer Glättung anzuwenden.

  **`seq: nil` ist richtig** und kein Versehen: Das ist der dokumentierte Weg
  für ein Ereignis, das von einem anderen Worker kommt und keinen Hub-Cursor
  hat (`Worker.Materializer`).
  """

  @standard "~/.local/share/lore-jack/teststage"

  @doc """
  Das Verzeichnis, in dem der Default-Abzug liegt. **Außerhalb des Repos** und
  ohne Datum im Namen: Ein datierter Pfad ist kein kanonischer Ort — man müsste
  wissen, welcher der richtige ist, und genau das hat am 26.09. eine Stunde
  gekostet.
  """
  @spec standard_verzeichnis() :: Path.t()
  def standard_verzeichnis, do: Path.expand(@standard)

  @doc """
  Die Wurzel des Arbeitsbaums — **nicht** `File.cwd!()`.

  Der Unterschied ist der Riegel: Die Tasks laufen aus `apps/worker` (so ruft
  sie `mix cmd --app worker` und so ruft sie `lore.pr_test`), und gegen `cwd`
  geprüft galt `<repo>/priv/abzug` als „außerhalb". Am 26.09.2026 beim Prüfen
  des Riegels aufgefallen: Er ließ genau das Ziel durch, gegen das er gebaut
  ist.

  `Mix.Project.deps_path/0` zeigt im Umbrella auf `<wurzel>/deps`, auch wenn
  der Task in einer App läuft.
  """
  @spec arbeitsbaum() :: Path.t()
  def arbeitsbaum, do: Mix.Project.deps_path() |> Path.dirname() |> Path.expand()

  @doc """
  `false`, wenn der Pfad im Arbeitsbaum liegt — der Abzug trägt echte Namen und
  darf nicht einchecken können. Geprüft wird nach `Path.expand/1`, damit
  `../lore_tracker/…` nicht durchrutscht.
  """
  @spec pfad_erlaubt?(Path.t(), Path.t()) :: boolean()
  def pfad_erlaubt?(pfad, repo_wurzel) do
    p = Path.expand(pfad)
    r = Path.expand(repo_wurzel)
    not (p == r or String.starts_with?(p, r <> "/"))
  end

  @doc """
  `true`, wenn der Knotenname nach einem Produktions-Worker aussieht.
  Einspielen dorthin ist verboten: Der Abzug ist ein Teststand, und seine
  Ereignisse würden sich in Prod mit den echten mischen.
  """
  @spec prod_knoten?(atom() | String.t()) :: boolean()
  def prod_knoten?(knoten), do: String.contains?(to_string(knoten), "worker_prod")

  @doc """
  Die JSONL-Dateien eines Abzugs, alphabetisch. `{:error, :kein_abzug}`, wenn
  das Verzeichnis fehlt oder keine enthält — ein leerer Abzug, der als Erfolg
  durchgeht, wäre die stille Variante des Fehlers.
  """
  @spec dateien(Path.t()) :: {:ok, [Path.t()]} | {:error, :kein_abzug}
  def dateien(verzeichnis) do
    case File.ls(verzeichnis) do
      {:ok, namen} ->
        namen
        |> Enum.filter(&String.ends_with?(&1, ".jsonl"))
        |> Enum.sort()
        |> Enum.map(&Path.join(verzeichnis, &1))
        |> case do
          [] -> {:error, :kein_abzug}
          liste -> {:ok, liste}
        end

      {:error, _} ->
        {:error, :kein_abzug}
    end
  end

  @doc """
  Liest die Ereignisse eines Abzugs: alle Dateien zusammen, nach `ts` sortiert,
  doppelte `event_id` entfernt.

  **Das Entdoppeln ist kein Luxus.** Am 25.09. entstand ein Abzug, in dem jedes
  Ereignis zweimal stand (26 MB statt 3); er trägt die Warnung im Namen, aber
  ein Werkzeug, das sich darauf verlässt, hat keine.
  """
  @spec ereignisse(Path.t()) :: {:ok, [map()]} | {:error, term()}
  def ereignisse(verzeichnis) do
    with {:ok, dateien} <- dateien(verzeichnis) do
      dateien
      |> Enum.flat_map(&zeilen/1)
      |> Enum.uniq_by(& &1["event_id"])
      |> Enum.sort_by(& &1["ts"])
      |> case do
        [] -> {:error, :kein_abzug}
        liste -> {:ok, liste}
      end
    end
  end

  defp zeilen(datei) do
    datei
    |> File.stream!()
    |> Stream.map(&String.trim/1)
    |> Stream.reject(&(&1 == ""))
    |> Enum.map(&Jason.decode!/1)
  end

  @doc """
  Bringt ein gelesenes Ereignis in die Form, die `Worker.Materializer` erwartet.

  `seq` ist `nil` (kein Hub-Cursor), `hub_seq` aus dem Abzug fällt weg — es ist
  der Cursor des Workers, von dem der Abzug stammt, und am Ziel bedeutet er
  nichts.
  """
  @spec zum_anwenden(map()) :: map()
  def zum_anwenden(%{"event_id" => id, "payload" => payload, "ts" => ts}),
    do: %{"event_id" => id, "seq" => nil, "payload" => payload, "ts" => ts}

  @doc "Die Ereignis-Arten eines Abzugs, häufigste zuerst — für die Ausgabe."
  @spec arten([map()]) :: [{String.t(), pos_integer()}]
  def arten(ereignisse) do
    ereignisse
    |> Enum.frequencies_by(&get_in(&1, ["payload", "kind"]))
    |> Enum.sort_by(&(-elem(&1, 1)))
  end
end
