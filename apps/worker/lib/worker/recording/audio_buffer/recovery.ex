defmodule Worker.Recording.AudioBuffer.Recovery do
  @moduledoc """
  Issue #466 / #1055: liegengebliebenes Rohaudio wieder aufgreifen.

  Der `audio_dir` **ist** der persistente Auftrag. Die Warteschlange davor
  (`Worker.GpuQueue`) ist es nicht — sie hält Closures und übersteht keinen
  BEAM-Neustart. Statt die Queue persistierbar zu machen (ein Umbau aller drei
  Aufrufer), schaut dieser Scan regelmässig nach, was auf der Platte liegt und
  niemanden mehr hat.

  ## Warum periodisch (#1055)

  Der Scan lief bis #1055 ausschliesslich beim Hochfahren. Für den Neustart
  reichte das — die Aufträge gehen dabei zwar verloren, der Bootpfad greift sie
  aber wieder auf. Ein Auftrag kann jedoch auch **ohne** Neustart verschwinden:
  stirbt der `GpuQueue`-GenServer, stirbt der wartende `run/2`-Aufruf im
  Transcribe-Task mit, und der `DOWN`-Zweig des `AudioBuffer` verspricht
  seitdem ein „Crash-Recovery-Retry", das es nur beim nächsten Boot gab. Real
  passiert am 13.08.2026.

  ## Was der Scan NICHT anfassen darf

  Beim Boot war das keine Frage: `state.sessions` ist leer, alles im
  `audio_dir` ist verwaist. Periodisch liegt dort auch die **laufende**
  Aufnahme. `plan/4` trennt das — siehe dort für die Reihenfolge der Zweige.

  ## Aufgabenteilung

  Dieses Modul entscheidet, meldet und holt `SessionEnded` nach; den
  Transcribe-Task startet der `AudioBuffer` (er hält `pending_transcribes` und
  die Monitore). `run/2` liefert deshalb die Übergabeliste zurück, statt sie
  selbst abzuarbeiten.
  """

  require Logger

  # Issue #1055: Versuchsdeckel je Sitzung und Worker-Lauf. Betrifft nur den
  # Fall, dass die Transkription CRASHT — ein regulär fehlgeschlagener Lauf
  # wandert über `AudioBuffer.archive_session_audio/1` ins Archiv und taucht im
  # Scan nie wieder auf. Nach dem Deckel wird EINMAL laut aufgegeben
  # (/admin/errors), danach still übersprungen.
  #
  # Ehrliche Grenze: Zähler und Deckel leben im Arbeitsspeicher. Ein Neustart
  # setzt beide zurück, eine dauerhaft abstürzende Sitzung bekommt danach
  # erneut drei Anläufe. Das entspricht dem bisherigen Verhalten (der Bootpfad
  # versuchte es immer erneut) und ist damit keine Verschlechterung.
  @max_attempts 3

  @doc "Der Versuchsdeckel je Sitzung und Worker-Lauf."
  @spec max_attempts() :: pos_integer()
  def max_attempts, do: @max_attempts

  @doc """
  Einen Scan-Durchlauf fahren.

  Liefert den fortgeschriebenen State (Versuchszähler, Melde-Set) und die
  Übergabeliste `[{session_id, files}]` für `start_transcribe_task/3`.
  """
  @spec run(map(), String.t()) :: {map(), [{String.t(), [{String.t(), String.t()}]}]}
  def run(state, audio_dir) do
    case File.ls(audio_dir) do
      {:ok, entries} ->
        plan =
          entries
          |> Enum.filter(&File.dir?(Path.join(audio_dir, &1)))
          |> Enum.map(fn sid -> {sid, count_webms(Path.join(audio_dir, sid))} end)
          |> plan(
            Map.keys(state.sessions),
            Map.values(state.pending_transcribes),
            state.recover_attempts
          )

        state = report_abandoned(state, plan.aufgegeben, audio_dir)

        Enum.reduce(plan.recover, {state, []}, fn sid, {st, handoffs} ->
          # Versuch zählen, DANN übergeben. Andersherum bliebe ein Absturz
          # während der Übergabe ungezählt und der Deckel wirkungslos.
          st = %{st | recover_attempts: Map.update(st.recover_attempts, sid, 1, &(&1 + 1))}

          case handoff(sid, audio_dir) do
            {:ok, files} -> {st, handoffs ++ [{sid, files}]}
            :skip -> {st, handoffs}
          end
        end)

      {:error, _} ->
        {state, []}
    end
  end

  @doc """
  Welche Session-Verzeichnisse ein Scan anfassen darf. Pur, damit die
  Reihenfolge der Zweige ohne Dateisystem und GenServer prüfbar ist — sie ist
  die eigentliche Aussage:

  1. **aktiv** schlägt alles. Offene Sitzungen (inkl. des Late-Append-Fensters
     aus #949) und solche, deren Transcribe-Task lebt — `GpuQueue.run/2`
     blockiert, der Task deckt damit „wartet in der Queue" UND „läuft gerade"
     ab. Ohne diesen Zweig bekäme eine laufende Aufnahme mitten im Betrieb ein
     nachgeholtes `SessionEnded` und liefe ein zweites Mal durch Whisper.
  2. **leer** — kein `.webm`, nichts zu retten. Eigene Klasse, damit ein
     Restverzeichnis nicht über den Versuchsdeckel als Fehlschlag in
     /admin/errors landet.
  3. **aufgegeben** — Deckel erreicht.
  4. sonst **recover**.
  """
  @spec plan(
          [{String.t(), non_neg_integer()}],
          [String.t()],
          [String.t()],
          %{optional(String.t()) => non_neg_integer()}
        ) :: %{
          recover: [String.t()],
          aktiv: [String.t()],
          leer: [String.t()],
          aufgegeben: [String.t()]
        }
  def plan(dirs, open_ids, pending_ids, attempts) do
    aktiv = MapSet.union(MapSet.new(open_ids), MapSet.new(pending_ids))

    dirs
    |> Enum.reduce(%{recover: [], aktiv: [], leer: [], aufgegeben: []}, fn {sid, webms}, acc ->
      cond do
        MapSet.member?(aktiv, sid) ->
          Map.update!(acc, :aktiv, &[sid | &1])

        webms == 0 ->
          Map.update!(acc, :leer, &[sid | &1])

        Map.get(attempts, sid, 0) >= @max_attempts ->
          Map.update!(acc, :aufgegeben, &[sid | &1])

        true ->
          Map.update!(acc, :recover, &[sid | &1])
      end
    end)
    |> Map.new(fn {k, v} -> {k, Enum.reverse(v)} end)
  end

  @doc """
  Datei-Liste aus dem Dir-Inhalt rekonstruieren — je `.webm` ein `{key, path}`,
  key = Basename (numerische discord_id, `multi_<id>` oder das alte
  `single_source`). Das Routing (per-Spieler vs. diarisiert) macht
  `AudioBuffer.start_transcribe_task/3` anhand des key-Prefix (Issue #642).
  """
  @spec recover_files(String.t(), [String.t()]) ::
          {:ok, [{String.t(), String.t()}]} | {:skip, String.t()}
  def recover_files(_sdir, []), do: {:skip, "keine .webm-Dateien"}

  def recover_files(sdir, webms) do
    files = Enum.map(webms, fn f -> {Path.basename(f, ".webm"), Path.join(sdir, f)} end)
    {:ok, files}
  end

  # ─── Internal ─────────────────────────────────────────────────────

  defp handoff(session_id, audio_dir) do
    sdir = Path.join(audio_dir, session_id)
    webms = sdir |> File.ls!() |> Enum.filter(&String.ends_with?(&1, ".webm"))

    case recover_files(sdir, webms) do
      {:skip, reason} ->
        # Kann nur noch als Rennen auftreten (`plan/4` sortiert leere
        # Verzeichnisse vorher aus) — die Dateien können zwischen Zählung und
        # Lesen verschwinden.
        Logger.warning(
          "AudioBuffer: recovery — überspringe verwaistes Dir #{session_id} (#{reason})"
        )

        :skip

      {:ok, files} ->
        Logger.warning(
          "AudioBuffer: recovery — re-transkribiere verwaiste session=#{session_id} " <>
            "files=#{length(files)} (Worker-Crash während der Aufnahme)"
        )

        # SessionEnded nachholen — ein mid-recording-Crash hat finalize/1 (das
        # es sonst publisht) nie erreicht. Idempotent genug (Status → :ended).
        # Issue #571: Return matchen (siehe finalize/1).
        {:ok, _} =
          Worker.Intents.publish(%{"kind" => Shared.Events.session_ended(), "id" => session_id})

        {:ok, files}
    end
  end

  defp count_webms(sdir) do
    case File.ls(sdir) do
      {:ok, entries} -> Enum.count(entries, &String.ends_with?(&1, ".webm"))
      {:error, _} -> 0
    end
  end

  # Issue #1055: Aufgeben ist ein Befund, kein Schweigen — genau der fehlende
  # „Anhaltspunkt, warum" aus dem Ticket. Einmal pro Sitzung und Worker-Lauf,
  # sonst stünde alle 15 Minuten dieselbe Zeile in /admin/errors.
  defp report_abandoned(state, session_ids, audio_dir) do
    Enum.reduce(session_ids, state, fn sid, acc ->
      if MapSet.member?(acc.recover_reported, sid) do
        acc
      else
        pfad = Path.join(audio_dir, sid)

        Logger.error(
          "AudioBuffer: recovery aufgegeben session=#{sid} nach #{@max_attempts} " <>
            "Versuchen — das Audio bleibt in #{pfad} liegen"
        )

        publish_abandoned(sid, pfad)
        %{acc | recover_reported: MapSet.put(acc.recover_reported, sid)}
      end
    end)
  end

  defp publish_abandoned(session_id, pfad) do
    campaign_id =
      case Worker.Repo.get_session(session_id) do
        %{campaign_id: cid} -> cid
        _ -> nil
      end

    payload = %{
      "kind" => Shared.Events.pipeline_error_logged(),
      "error_id" => UUIDv7.generate(),
      "session_id" => session_id,
      "campaign_id" => campaign_id,
      "stage" => "stage1",
      "error_type" => "recovery_abandoned",
      "message" =>
        "Transkription nach #{@max_attempts} Anläufen aufgegeben. Das Audio ist " <>
          "vollständig und liegt weiterhin in #{pfad}.",
      "context" => %{"versuche" => @max_attempts, "audio_dir" => pfad},
      "occurred_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    # Issue #430: Intents.publish/1 liefert immer {:ok, _} (kein toter
    # {:error, _}-Zweig).
    {:ok, _} = Worker.Intents.publish(payload)
    :ok
  end
end
