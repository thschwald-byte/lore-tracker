defmodule Worker.Jack.Abzug do
  @moduledoc """
  Eine Prod-Sitzung als Arbeitsmaterial für Jack: aufbereiten, ablegen, laden.
  Die Abfrage selbst macht `mix lore.jack.abzug` (lesend per RPC aus
  `worker_prod`); dieses Modul ist der reine Teil davon, ohne Prod testbar.

  Tom, 2026-09-10: „testdaten müssen für tests aus prod gezogen werden“ und
  „außerhalb des repos“. Ein Abzug enthält den Mitschnitt der echten Runde
  und liegt deshalb nie im Repo, Default ist
  `~/.local/share/lore-jack/testdaten/<name>`. Tests darauf tragen den Tag
  `:jack_prod` und laufen weder im Standardlauf noch in der CI.

  Abgelegt werden:

    * `bloecke.json` — die geglätteten Blöcke in Mitschnittreihenfolge, je
      Nummer, Block-ID, Sprecher (Figurenname), Text, `hat_luecke`,
      `asr_unsicher`, Quell-Utterances;
    * `cast.json` — der Roster der Kampagne (`Worker.Repo.character_roster_for/1`),
      auf Figurennamen abgebildet;
    * `straenge.json` — die kanonischen Namen der Stränge der Kampagne;
    * `fakten.json` — die Fakten der Sitzung, wie die Pipeline sie hat, zum
      Vergleich;
    * `meta.json` — Kampagne, Sitzung, Regelversion der Glättung, Zeitpunkte.

  **Keine Discord-ID und kein Handle erreicht Jack.** Prod-Blöcke tragen die
  Discord-ID des Sprechers, und in Prod hat meist nur ein Teil der Figuren
  einen Namen hinterlegt. Der Roster erntet NPC-Namen aus
  `character_alias` der Fakten und enthält dort, wo die Extraktion den Handle
  statt der Figur schrieb, echte Handles (das Alias-Durcheinander aus #976).
  Deshalb bildet der Abzug beides über eine lokale Namensdatei ab (wie
  `namen.map` im Spike, siehe `namen_aus_text/1`) und bricht ab, statt
  durchzulassen:

    * ein Sprecher ohne Namen — aus der Namensdatei, aus Prod, sonst der
      Spielleiter der Kampagne — ist ein Fehler;
    * ein Roster-Eintrag, der wie ein Handle aussieht (klein geschrieben,
      ohne Leerzeichen) und in der Namensdatei nicht vorkommt, ist ein
      Fehler;
    * in den Strangnamen wird jeder Handle aus der Namensdatei durch den
      Figurennamen ersetzt (`handles_ersetzen/2`). Anlass: an seattleV4
      trugen zwei Stränge einen Handle im Namen („<Handle>s Beruf“) — die
      Prüfung galt bis dahin nur dem Roster, und Jack sah sie über
      `straenge()` (#1205).

  **Ehrliche Grenze:** Die Handle-Erkennung ist eine Heuristik. Ein Handle mit
  Großbuchstaben oder Leerzeichen sähe aus wie ein Figurenname und käme
  durch. `fakten.json` bleibt, wie Prod es hat (auch mit Handles in
  `character`), weil kein Werkzeug Jacks es liest.
  """

  alias Worker.Jack.Stand

  @dateien ~w(bloecke cast straenge fakten meta)
  @discord_id ~r/^\d{15,20}$/
  @handle ~r/^[\p{Ll}\d._]+$/u

  @doc """
  Die Namensdatei lesen: je Zeile `schluessel<TAB>figurenname`, der Schlüssel
  eine Discord-ID oder ein Handle; Zeilen mit `#` am Anfang und Leerzeilen
  zählen nicht.
  """
  @spec namen_aus_text(String.t()) :: {:ok, %{String.t() => String.t()}} | {:error, term()}
  def namen_aus_text(text) do
    text
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reject(fn {z, _} -> String.trim(z) == "" or String.starts_with?(z, "#") end)
    |> Enum.reduce_while({:ok, %{}}, fn {z, n}, {:ok, acc} ->
      case String.split(z, "\t") |> Enum.map(&String.trim/1) do
        [k, name] when k != "" and name != "" -> {:cont, {:ok, Map.put(acc, k, name)}}
        _ -> {:halt, {:error, {:namenszeile, n}}}
      end
    end)
  end

  @doc """
  Aufbereiten, was aus Prod kam. `roh` hat `:bloecke` (die Blöcke aus
  `get_smoothed_blocks/1`), `:spielleiter` (Discord-ID), `:figuren`
  (`character_names_for/1`), `:roster`, `:straenge`, `:fakten`, `:meta`.
  """
  @spec aufbereiten(map(), %{String.t() => String.t()}) :: {:ok, map()} | {:error, term()}
  def aufbereiten(roh, namen) do
    wer = sprecher_namen(roh, namen)

    ohne =
      roh.bloecke
      |> Enum.map(& &1["speaker_discord_id"])
      |> Enum.uniq()
      |> Enum.reject(&Map.has_key?(wer, &1))

    with [] <- ohne,
         {:ok, cast} <- cast(roh.roster, namen) do
      bloecke =
        roh.bloecke
        |> Enum.with_index()
        |> Enum.map(fn {b, i} ->
          %{
            "nummer" => i,
            "block_id" => b["id"],
            "sprecher" => Map.fetch!(wer, b["speaker_discord_id"]),
            "text" => b["text"] || "",
            "hat_luecke" => b["hat_luecke"] == true,
            "asr_unsicher" => b["asr_unsicher"] == true,
            "quell_utterance_ids" => b["quell_utterance_ids"] || []
          }
        end)

      {:ok,
       %{
         "bloecke" => bloecke,
         "cast" => cast,
         "straenge" =>
           roh.straenge
           |> Enum.reject(&(&1 in [nil, ""]))
           |> Enum.map(&handles_ersetzen(&1, namen))
           |> Enum.uniq(),
         "fakten" => roh.fakten,
         "meta" =>
           Map.merge(roh.meta, %{
             "bloecke" => length(bloecke),
             "sprecher" => bloecke |> Enum.map(& &1["sprecher"]) |> Enum.uniq()
           })
       }}
    else
      [_ | _] = ohne -> {:error, {:sprecher_ohne_namen, ohne}}
      fehler -> fehler
    end
  end

  # Die Namensdatei geht vor, dann die Figurennamen aus Prod, dann der
  # Spielleiter der Kampagne.
  defp sprecher_namen(roh, namen) do
    spielleiter = if roh.spielleiter, do: %{roh.spielleiter => "Spielleiter"}, else: %{}

    spielleiter
    |> Map.merge(roh.figuren || %{})
    |> Map.merge(namen)
  end

  defp cast(roster, namen) do
    {cast, handles} =
      Enum.reduce(roster, {[], []}, fn eintrag, {cast, handles} ->
        cond do
          Map.has_key?(namen, eintrag) -> {cast ++ [namen[eintrag]], handles}
          Regex.match?(@handle, eintrag) -> {cast, handles ++ [eintrag]}
          true -> {cast ++ [eintrag], handles}
        end
      end)

    if handles == [], do: {:ok, Enum.uniq(cast)}, else: {:error, {:roster_handles, handles}}
  end

  @doc """
  Ersetzt in einem Text jeden Handle aus der Namensdatei durch den
  Figurennamen, ohne Rücksicht auf Groß- und Kleinschreibung. Anlass sind
  Strangnamen wie „<Handle>s Beruf“: das Clustering hat sie aus Fakt-Labels
  gebildet, in denen die Extraktion den Handle statt der Figur schrieb
  (#1205). Discord-IDs aus der Namensdatei bleiben außen vor.
  """
  @spec handles_ersetzen(String.t(), %{String.t() => String.t()}) :: String.t()
  def handles_ersetzen(text, namen) do
    namen
    |> Enum.reject(fn {k, _} -> Regex.match?(@discord_id, k) end)
    |> Enum.sort_by(fn {k, _} -> -String.length(k) end)
    |> Enum.reduce(text, fn {k, name}, t ->
      String.replace(t, Regex.compile!(Regex.escape(k), "iu"), name)
    end)
  end

  @doc "Den Abzug ablegen: Verzeichnis nur für den Besitzer (0700), Dateien 0600."
  @spec schreiben(Path.t(), map()) :: :ok
  def schreiben(dir, daten) do
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)

    Enum.each(@dateien, fn name ->
      pfad = Path.join(dir, name <> ".json")
      File.write!(pfad, Jason.encode_to_iodata!(Map.fetch!(daten, name), pretty: true))
      File.chmod!(pfad, 0o600)
    end)
  end

  @doc """
  Einen Abzug laden. Prüft, dass kein Sprecher eine Discord-ID ist — die darf
  nie in einer Werkzeugantwort stehen.
  """
  @spec laden(Path.t()) :: {:ok, map()} | {:error, term()}
  def laden(dir) do
    with {:ok, d} <- dateien_lesen(dir),
         :ok <- ohne_ids(d["bloecke"]) do
      {:ok,
       %{
         bloecke:
           Enum.map(d["bloecke"], fn b ->
             %{text: b["text"], sprecher: b["sprecher"], block_id: b["block_id"]}
           end),
         cast: d["cast"],
         straenge: d["straenge"],
         fakten: d["fakten"],
         meta: d["meta"]
       }}
    end
  end

  @doc """
  Die Eingabe des Spikes laden: `bloecke.tsv` (`idx`, `sprecher`, `text`),
  `cast.txt` und `straenge.txt` aus `sharp-solution/daten`. Für J3, damit
  Port und Spike auf demselben Text laufen (Toms Entscheidung, 10.09.) —
  der Prod-Abzug trug in 228 Lückenblöcken den Rohtext statt des wirksamen.
  Liefert dieselbe Form wie `laden/1`.

  Wie beim Abzug erreicht kein Handle Jack: die Stränge laufen durch
  `handles_ersetzen/2`, der Cast durch dieselbe Prüfung wie der Roster, und
  ein Sprecher, der eine Discord-ID ist, lässt das Laden scheitern. Die TSV
  wird an Tabulatoren zerlegt, nie mit einem CSV-Leser (ein `"` im Text
  kostete dort 8 % der Zeilen), und jede Zeile muss ihre Nummer tragen.
  """
  @spec spike_laden(Path.t(), %{String.t() => String.t()}) :: {:ok, map()} | {:error, term()}
  def spike_laden(dir, namen) do
    with {:ok, tsv} <- lesen(Path.join(dir, "bloecke.tsv")),
         {:ok, bloecke} <- tsv_bloecke(tsv),
         :ok <- ohne_ids(Enum.map(bloecke, &%{"sprecher" => &1.sprecher})),
         {:ok, roster} <- zeilen(Path.join(dir, "cast.txt")),
         {:ok, cast} <- cast(roster, namen),
         {:ok, straenge} <- zeilen(Path.join(dir, "straenge.txt")) do
      {:ok,
       %{
         bloecke: bloecke,
         cast: cast,
         straenge: straenge |> Enum.map(&handles_ersetzen(&1, namen)) |> Enum.uniq(),
         fakten: [],
         meta: %{"quelle" => "spike", "verzeichnis" => dir, "bloecke" => length(bloecke)}
       }}
    end
  end

  defp lesen(pfad) do
    case File.read(pfad) do
      {:ok, text} -> {:ok, text}
      {:error, _} -> {:error, {:spike_datei_fehlt, pfad}}
    end
  end

  defp zeilen(pfad) do
    with {:ok, text} <- lesen(pfad) do
      {:ok, text |> String.split("\n") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))}
    end
  end

  defp tsv_bloecke(tsv) do
    [_kopf | zeilen] = String.split(tsv, "\n")

    zeilen
    |> Enum.reject(&(String.trim(&1) == ""))
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {z, i}, {:ok, acc} ->
      nr = Integer.to_string(i)

      case String.split(z, "\t", parts: 3) do
        [^nr, sprecher, text] ->
          {:cont, {:ok, [%{text: text, sprecher: sprecher, block_id: "spike_#{i}"} | acc]}}

        _ ->
          {:halt, {:error, {:tsv_zeile, i + 2}}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      fehler -> fehler
    end
  end

  @doc "Ein neuer Stand über einem Abzug; `opts` wie bei `Worker.Jack.Stand.neu/1`."
  @spec stand(map(), keyword()) :: Stand.t()
  def stand(abzug, opts \\ []) do
    Stand.neu(
      Keyword.merge([bloecke: abzug.bloecke, cast: abzug.cast, straenge: abzug.straenge], opts)
    )
  end

  defp dateien_lesen(dir) do
    Enum.reduce_while(@dateien, {:ok, %{}}, fn name, {:ok, acc} ->
      pfad = Path.join(dir, name <> ".json")

      with {:ok, text} <- File.read(pfad),
           {:ok, inhalt} <- Jason.decode(text) do
        {:cont, {:ok, Map.put(acc, name, inhalt)}}
      else
        _ -> {:halt, {:error, {:abzug_unvollstaendig, pfad}}}
      end
    end)
  end

  defp ohne_ids(bloecke) do
    case Enum.count(bloecke, &Regex.match?(@discord_id, to_string(&1["sprecher"]))) do
      0 -> :ok
      n -> {:error, {:discord_id_als_sprecher, n}}
    end
  end
end
