defmodule Worker.HubClient.Rpc do
  @moduledoc """
  Issue #585: Sync-RPC-Topic-Bündel aus `Worker.HubClient` — Hub fragt etwas
  ab + wartet auf ein Response-Frame zurück.

  - `snapshot_request` — Hub holt Worker.Repo.snapshot/1 (LiveView-Mount-Pfad)
  - `preview_request` — Prompt-Vorschau für Stil-Editor (Issue #313/#320)
  - `update_settings` — Worker-Settings setzen (mit Secret-Redaction Issue #510)
  - `gpu_job_action` — GpuQueue-Management vom /admin/jobs-LV (Issue #292)
  """

  require Logger

  alias Worker.HubClient

  def on_snapshot(%{"request_id" => rid, "scope" => scope}, socket) do
    payload = scope |> Worker.Repo.snapshot() |> maybe_add_mic_streamers()
    HubClient.push_event(socket, "snapshot_response", %{request_id: rid, payload: payload})
    {:ok, socket}
  end

  # Issue #313: Prompt-Vorschau-Segmente für den Stil-Editor bauen. Tuples aus
  # Pipeline.preview_prompt/2 → JSON-Maps, da der Socket-Serializer keine
  # Tuples kann.
  def on_preview(
        %{"request_id" => rid, "campaign_id" => cid, "stage" => stage} = msg,
        socket
      ) do
    # Issue #320: die Hub-Live-Vorschau schickt die aktuellen Entwürfe (noch
    # nicht gespeichert) als `overrides` mit — der Worker baut den echten Prompt
    # mit DIESEN Werten, damit man beim Tippen sieht wie der Prompt sich ändert
    # (inkl. einer neu getippten Überschrift, die im gespeicherten Stand fehlt).
    overrides = Map.get(msg, "overrides", %{})

    segments =
      with true <- stage in ["summary", "epos", "chronik"],
           campaign when is_map(campaign) <- Worker.Repo.get_campaign(cid) do
        campaign
        |> merge_preview_overrides(stage, overrides)
        |> then(&Worker.Recording.Pipeline.preview_prompt(stage, &1))
        |> Enum.map(&serialize_preview_segment/1)
      else
        _ -> []
      end

    HubClient.push_event(socket, "preview_response", %{request_id: rid, segments: segments})
    {:ok, socket}
  end

  def on_update_settings(%{"settings" => kv}, socket) do
    known_keys = Worker.Settings.defaults() |> Map.keys() |> MapSet.new()

    coerced =
      Enum.reduce(kv, %{}, fn {k, v}, acc ->
        case parse_setting_key(k, known_keys) do
          {:ok, key} ->
            Map.put(acc, key, coerce_setting_value(v))

          :error ->
            Logger.warning("HubClient: dropping unknown setting key=#{inspect(k)}")
            acc
        end
      end)

    coerced = remap_legacy_model_keys(coerced)

    :ok = Worker.Settings.put_many(coerced)

    # Issue #510: secret-Keys NIE im Log durchreichen. Settings können API-Keys
    # enthalten (anthropic_api_key / openai_api_key / gemini_api_key) — den
    # Wert maskieren, nur den Schlüssel-Namen + Länge loggen.
    Logger.info("HubClient: settings updated: #{inspect(redact_secrets(coerced))}")
    {:ok, socket}
  end

  # #451 Track C: Legacy-`model_stage{n}`-Writes (Probelauf-Heuristik
  # „Empfehlung übernehmen", alte Scripts) zusätzlich auf den GEWINNENDEN
  # pro-Backend-Key des aktiven Backends spiegeln — sonst würde ein bereits
  # persistierter pro-Backend-Key den Legacy-Write verdecken
  # (`Settings.model_for`-Kette). Ein `backend_stage{n}` aus demselben Batch
  # gewinnt vor dem persistierten Setting. Der Legacy-Key wird zusätzlich
  # weiter geschrieben (Alias-Write, kein Datenverlust für Alt-Leser).
  @doc false
  def remap_legacy_model_keys(kv) when is_map(kv) do
    Enum.reduce(2..4, kv, fn n, acc ->
      case Map.get(acc, :"model_stage#{n}") do
        nil ->
          acc

        model ->
          backend =
            Map.get(acc, :"backend_stage#{n}") || Worker.Settings.get(:"backend_stage#{n}")

          Map.put(acc, Worker.Settings.model_key(n, backend), model)
      end
    end)
  end

  # Issue #292: GpuQueue-Job-Verwaltung vom /admin/jobs-LV.
  def on_gpu_job_action(%{"action" => action, "job_id" => job_id}, socket)
      when is_binary(action) and is_binary(job_id) do
    result =
      case action do
        "move_up" -> Worker.GpuQueue.move_up(job_id)
        "move_down" -> Worker.GpuQueue.move_down(job_id)
        "cancel" -> Worker.GpuQueue.cancel(job_id)
        _ -> {:error, :unknown_action}
      end

    case result do
      :ok ->
        Logger.info("HubClient: gpu_job_action #{action} ok job_id=#{job_id}")

      {:error, reason} ->
        Logger.warning(
          "HubClient: gpu_job_action #{action} failed job_id=#{job_id} reason=#{inspect(reason)}"
        )
    end

    {:ok, socket}
  end

  # Issue #392: Streamer-Liste aus dem Live-Recording-State (AudioBuffer) in den
  # Snapshot mergen — frisch gemountete CampaignLive weiß sofort wer streamt.
  defp maybe_add_mic_streamers(%{"active_session" => %{"id" => sid}} = payload)
       when is_binary(sid) do
    Map.put(payload, "mic_streamers", Worker.Recording.AudioBuffer.streamers(sid))
  end

  defp maybe_add_mic_streamers(payload), do: payload

  # Entwurfs-Overrides (string-keyed vom Hub) in die Campaign mergen. vorgaben-
  # Inner-Keys als Atome (:name/:darstellungsform).
  defp merge_preview_overrides(campaign, stage, overrides)
       when is_map(overrides) and overrides != %{} do
    flavors = Map.merge(campaign[:flavors] || %{}, Map.get(overrides, "flavors", %{}) || %{})

    vorgaben =
      case Map.get(overrides, "vorgaben", %{}) |> Map.get(stage) do
        %{} = v ->
          inner = %{
            name: Map.get(v, "name", ""),
            darstellungsform: Map.get(v, "darstellungsform", "fliesstext")
          }

          Map.put(campaign[:vorgaben] || %{}, stage, inner)

        _ ->
          campaign[:vorgaben] || %{}
      end

    campaign |> Map.put(:flavors, flavors) |> Map.put(:vorgaben, vorgaben)
  end

  defp merge_preview_overrides(campaign, _stage, _), do: campaign

  # Issue #608: die folgenden vier Helfer sind `@doc false` public (statt defp),
  # damit der Wire-Shape-Drift-Guard (rpc_parse_test.exs) sie direkt testen kann.
  # Sie kodieren das Wire-Vokabular der Hub→Worker-RPCs (Preview-Segment-Shape,
  # Settings-Key/Value-Coercion, Secret-Redaction) — genau die Stellen, an denen
  # ein stiller Drift Hub und Worker entkoppeln würde.

  @doc false
  def serialize_preview_segment({:locked, text}),
    do: %{kind: "locked", text: to_string(text)}

  # Issue #320: Rahmen-Text um die Überschrift — der Hub blendet ihn nur ein,
  # wenn die Überschrift gesetzt ist (deckungsgleich mit heading_directive/1).
  def serialize_preview_segment({:heading_frame, text}),
    do: %{kind: "heading_frame", text: to_string(text)}

  def serialize_preview_segment({:editable, slot, text}),
    do: %{kind: "editable", slot: to_string(slot), text: to_string(text)}

  @doc false
  def parse_setting_key(k, known_keys) when is_binary(k) do
    atom = String.to_existing_atom(k)
    if MapSet.member?(known_keys, atom), do: {:ok, atom}, else: :error
  rescue
    ArgumentError -> :error
  end

  def parse_setting_key(_k, _known_keys), do: :error

  @doc false
  def coerce_setting_value(v) when is_binary(v) do
    case v do
      "local" -> :local
      "bundled" -> :bundled
      "anthropic" -> :anthropic
      # #451: "openai"/"google" fehlten hier — ein backend_stage{n}="openai"
      # blieb String, `Worker.LLM.module_for/1` fand kein Modul und fiel STILL
      # auf :local zurück (OpenAI/Google-Backend lief unbemerkt als Ollama).
      "openai" -> :openai
      "google" -> :google
      "batch" -> :batch
      other -> other
    end
  end

  def coerce_setting_value(v), do: v

  # Issue #510: API-Key-Werte vor Logger.info maskieren — Settings können
  # secret-Keys enthalten (anthropic_api_key / openai_api_key /
  # gemini_api_key). redact_secrets/1 ersetzt den Wert durch eine Längen-
  # Notiz; der Schlüssel-Name bleibt für die Diagnose sichtbar.
  @secret_keys ~w(anthropic_api_key openai_api_key gemini_api_key)a

  @doc false
  def redact_secrets(map) when is_map(map) do
    Enum.into(map, %{}, fn
      {k, v} when k in @secret_keys and is_binary(v) ->
        {k, "<redacted #{String.length(v)} chars>"}

      kv ->
        kv
    end)
  end
end
