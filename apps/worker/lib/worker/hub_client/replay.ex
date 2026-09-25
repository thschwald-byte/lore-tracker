defmodule Worker.HubClient.Replay do
  @moduledoc """
  Issue #585: Pipeline-Replay-Topic-Bündel aus `Worker.HubClient`.

  - `start_session_regenerate` — eine Session erneut durch die LLM-Pipeline jagen
    (Stage 2/3/4); Owner-Check macht die Pipeline selbst (Issue #121).
  - `start_jack_iterationen` — „noch N Iterationen“: Jack setzt auf seinem
    abgelegten Stand auf, danach Registries und Render (J4, #1207).
  - `start_campaign_replay` — sequenzieller Replay aller Sessions einer Campaign
    (Worker.Recording.CampaignReplay).
  - `start_thread_recluster` — Voll-Re-Cluster der Handlungsstrang-Registry
    (Issue #842, seltener/expliziter Gegenpart zum automatischen
    inkrementellen Pfad, der bei jeder Session mitläuft).
  """

  require Logger

  def on_session_regenerate(
        %{"discord_id" => did, "campaign_id" => cid, "session_id" => sid},
        socket
      ) do
    Task.Supervisor.start_child(Worker.TaskSupervisor, fn ->
      # Owner-Check macht die Pipeline selbst (maybe_run filtert nach
      # campaign.owner_discord_id == admin_discord_id). Wir leiten den Trigger
      # einfach weiter — der Hub hat schon den Owner-Worker gepickt.
      Logger.info(
        "HubClient: UI-triggered session-regenerate by=#{did} campaign=#{cid} session=#{sid}"
      )

      :ok = Worker.Recording.Pipeline.run_for_session(sid)
    end)

    {:ok, socket}
  end

  # J4 (#1207): „noch N Iterationen“ — wie der Regenerate, mit Jacks Option
  # für die Pipeline. Der Deckel (8) sitzt auch hier: ein Worker verlässt sich
  # nicht darauf, dass die Oberfläche ihn einhält.
  def on_jack_iterationen(
        %{"discord_id" => did, "campaign_id" => cid, "session_id" => sid, "iterationen" => n},
        socket
      )
      when is_integer(n) and n > 0 do
    Task.Supervisor.start_child(Worker.TaskSupervisor, fn ->
      Logger.info(
        "HubClient: UI-triggered jack-iterationen n=#{n} by=#{did} campaign=#{cid} session=#{sid}"
      )

      :ok = Worker.Recording.Pipeline.run_for_session(sid, jack_weiter: min(n, 8))
    end)

    {:ok, socket}
  end

  def on_jack_iterationen(payload, socket) do
    Logger.warning("HubClient: start_jack_iterationen ohne gültige Angaben: #{inspect(payload)}")
    {:ok, socket}
  end

  @doc """
  Issue #850: eine Frage an die Kampagne. Der Lauf startet sofort und meldet
  sein Ergebnis über `publish_status` zurück — mit der **Lauf-ID**, an der der
  Hub erkennt, wem die Antwort gehört (`HubWeb.PipelineStatus` routet darauf
  auf einen eigenen Topic statt auf den der Kampagne; sonst läse die ganze
  Runde mit, was einer gefragt hat).
  """
  def on_frage(
        %{"lauf_id" => lauf_id, "campaign_id" => cid, "frage" => frage} = p,
        socket
      )
      when is_binary(lauf_id) and is_binary(cid) and is_binary(frage) do
    Logger.info("HubClient: Frage lauf=#{lauf_id} campaign=#{cid} by=#{p["discord_id"]}")

    # `gespraech_id` ist optional: Ohne sie ist die Frage ein Lauf für sich
    # (Modus „Frage"), mit ihr setzt sie das Gespräch fort (Modus „Chat").
    opts =
      case p["gespraech_id"] do
        g when is_binary(g) and g != "" -> [gespraech_id: g]
        _ -> []
      end

    Worker.Jack.Frage.Dienst.starten(lauf_id, cid, frage, &melde_frage(cid, &1), opts)

    {:ok, socket}
  end

  def on_frage(payload, socket) do
    Logger.warning("HubClient: start_frage ohne gültige Angaben: #{inspect(payload)}")
    {:ok, socket}
  end

  @doc "Issue #850: Abbruch eines laufenden Frage-Laufs."
  def on_frage_abbruch(%{"lauf_id" => lauf_id}, socket) when is_binary(lauf_id) do
    Worker.Jack.Frage.Dienst.abbrechen(lauf_id)
    {:ok, socket}
  end

  def on_frage_abbruch(payload, socket) do
    Logger.warning("HubClient: abbrechen_frage ohne lauf_id: #{inspect(payload)}")
    {:ok, socket}
  end

  # Die Meldung trägt `campaign_id` mit, damit der Hub sie ohne eigenen
  # Zustand zuordnen kann, und `frage_lauf_id` als das, worauf er routet.
  defp melde_frage(cid, {:frage_fertig, lauf_id, antwort}) do
    Worker.HubClient.publish_status(%{
      "kind" => "frage_antwort",
      "campaign_id" => cid,
      "frage_lauf_id" => lauf_id,
      "text" => antwort.text,
      "fakt_ids" => antwort.fakt_ids,
      "kurze_ids" => antwort.kurze_ids,
      "geprueft" => to_string(antwort.geprueft),
      "grund" => Map.get(antwort, :grund),
      "runden" => Map.get(antwort, :runden),
      "gespraech_weiter?" => Map.get(antwort, :gespraech_weiter?, false)
    })
  end

  # Der Denkstrom, gedrosselt (`Worker.Jack.Frage.Strom`). Fire-and-forget: Er
  # ist Begleitung, nicht Ergebnis — geht ein Stück verloren, fehlt eine Zeile
  # im Fenster, nie die Antwort.
  defp melde_frage(cid, {:frage_strom, lauf_id, stuecke}) do
    Worker.HubClient.publish_status(%{
      "kind" => "frage_strom",
      "campaign_id" => cid,
      "frage_lauf_id" => lauf_id,
      "stuecke" => Enum.map(stuecke, &%{"art" => &1.art, "text" => &1.text})
    })
  end

  defp melde_frage(cid, {:frage_fehler, lauf_id, grund}) do
    Worker.HubClient.publish_status(%{
      "kind" => "frage_fehler",
      "campaign_id" => cid,
      "frage_lauf_id" => lauf_id,
      "grund" => grund_text(grund)
    })
  end

  defp grund_text({:belegt, label}),
    do: "Der Worker rechnet gerade an etwas anderem (#{label}). Versuch es gleich noch einmal."

  defp grund_text(:keine_sitzung), do: "Diese Kampagne hat noch keine aufgezeichnete Sitzung."
  defp grund_text(:keine_fakten), do: "Zu dieser Kampagne gibt es noch keine geprüften Fakten."
  defp grund_text(:laeuft_schon), do: "Diese Frage läuft bereits."

  defp grund_text({:frage_ohne_abschluss, _}),
    do: "Der Lauf hat keine Antwort abgeliefert — versuch es noch einmal."

  defp grund_text(anderes), do: "Der Lauf ist gescheitert: #{inspect(anderes)}"

  def on_campaign_replay(%{"discord_id" => did, "campaign_id" => cid}, socket) do
    Task.Supervisor.start_child(Worker.TaskSupervisor, fn ->
      case Worker.Recording.CampaignReplay.start(cid, did) do
        {:ok, run_id} ->
          Logger.info(
            "HubClient: UI-triggered campaign_replay started campaign=#{cid} run_id=#{run_id}"
          )

        {:error, {:already_running, existing}} ->
          Logger.warning(
            "HubClient: UI start_campaign_replay rejected — already running #{existing}"
          )

        {:error, :no_sessions_with_utterances} ->
          Logger.warning("HubClient: UI start_campaign_replay for empty campaign=#{cid}")

        {:error, reason} ->
          Logger.warning("HubClient: UI start_campaign_replay failed: #{inspect(reason)}")
      end
    end)

    {:ok, socket}
  end

  def on_thread_recluster(%{"discord_id" => did, "campaign_id" => cid}, socket) do
    Task.Supervisor.start_child(Worker.TaskSupervisor, fn ->
      Logger.info("HubClient: UI-triggered thread-recluster by=#{did} campaign=#{cid}")

      case Worker.Recording.Pipeline.ThreadRegistry.full_recluster_campaign_threads(cid) do
        {:ok, _registry} ->
          Logger.info("HubClient: UI thread-recluster done campaign=#{cid}")

        {:error, reason} ->
          Logger.warning(
            "HubClient: UI thread-recluster failed campaign=#{cid}: #{inspect(reason)}"
          )
      end
    end)

    {:ok, socket}
  end
end
