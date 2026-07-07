defmodule Worker.EvalBootstrap do
  @moduledoc """
  Geteilte Bootstrap-/Materialisierungs-/Baseline-Helfer für die **dev-only**
  Eval-Mix-Tasks (`mix lore.eval.summary` #647, `mix lore.eval.verify` #675).

  Bootet eine frische Worker-Mnesia ohne laufenden Hub/Worker-Daemon,
  materialisiert ein JSONL-Fixture (`apps/hub/priv/seeds/<campaign>/`) per
  Local-Apply und liest/schreibt die (nicht eingecheckten, modell-/maschinen-
  spezifischen) Baseline-Dateien.

  **Mix-frei**: gibt Daten zurück bzw. `raise`'t plain `RuntimeError` — die Tasks
  erledigen Shell-Output + Mix-Fehlerübersetzung. So bleibt die Logik an EINER
  Stelle (kein Drift zwischen den Eval-Tasks).
  """

  alias Worker.{Repo, Settings}

  @doc """
  Bootet Mnesia + startet die `:worker`-App mit Fake-Pairing (damit der
  Materializer/Pipeline-Supervisor-Baum hochkommt; HubClient-WS scheitert
  graceful, `Intents.publish` hat den Local-Apply-Fallback).
  """
  @spec bootstrap_worker!() :: :ok
  def bootstrap_worker! do
    # Issue #678-Folge (Sidecar-Leak): die Eval-Tasks brauchen die autostartenden
    # Sidecars NIE — `:nli`-Eval zeigt via `--sidecar-url` auf einen externen
    # Sidecar, `:llm_judge` nutzt Ollama, `summary`/`multisource` brauchen keinen.
    # Der autostartete Sidecar verwaiste aber beim BEAM-Exit (uvicorn-Kind wird
    # nicht gekillt) → über viele Eval-Läufe füllt sich die GPU. Hier hart aus,
    # bis Worker.Sidecar die Kinder beim Shutdown selbst killt (eigenes Ticket).
    System.put_env("LORE_SIDECAR_DISABLE", "1")
    System.put_env("LORE_DIARIZATION_SIDECAR_DISABLE", "1")

    :ok = Shared.Mnesia.ensure_started!()
    :ok = Worker.Schema.Mnesia.bootstrap!()

    if Repo.get_state(:hub_token) == nil,
      do: Repo.put_state(:hub_token, "eval-fake-token-#{System.unique_integer([:positive])}")

    if Repo.get_state(:worker_id) == nil,
      do: Repo.put_state(:worker_id, "eval-worker-#{System.unique_integer([:positive])}")

    if Repo.get_state(:hub_base_url) == nil,
      do: Repo.put_state(:hub_base_url, "http://127.0.0.1:1")

    Application.put_env(:worker, :no_browser, true)
    {:ok, _} = Application.ensure_all_started(:worker)
    :ok
  end

  @doc "Liest `fact-key.json` aus dem Seed-Verzeichnis (raise wenn fehlend)."
  @spec load_fact_key!(String.t()) :: map()
  def load_fact_key!(seed_dir) do
    path = Path.join(seed_dir, "fact-key.json")

    case File.read(path) do
      {:ok, raw} -> Jason.decode!(raw)
      {:error, _} -> raise "Fact-Key nicht gefunden: #{path}"
    end
  end

  @doc """
  Materialisiert alle `*.jsonl` aus `seed_dir` (sortiert) per Local-Apply.
  Gibt die Anzahl applizierter Events zurück; raise wenn keine Files.
  """
  @spec materialize_fixture!(String.t()) :: non_neg_integer()
  def materialize_fixture!(seed_dir) do
    files =
      seed_dir
      |> Path.join("*.jsonl")
      |> Path.wildcard()
      |> Enum.sort()

    if files == [], do: raise("Keine *.jsonl im Fixture: #{seed_dir}")

    files
    |> Enum.flat_map(&read_jsonl/1)
    |> Enum.reduce(0, fn payload, acc ->
      apply_local!(payload)
      acc + 1
    end)
  end

  @doc "Local-Apply eines CampaignDeleted für `campaign_id` (Pre-Reset)."
  @spec reset_campaign(String.t()) :: :ok
  def reset_campaign(campaign_id) do
    apply_local!(%{
      "kind" => Shared.Events.campaign_deleted(),
      "id" => campaign_id,
      "campaign_id" => campaign_id
    })

    :ok
  end

  @doc """
  Pinnt `backend_stage2` auf `:local` + optional ein explizites `model_stage2`.
  Gibt `{backup, label}` zurück; `restore_stage2_model!/1` setzt zurück.
  """
  @spec apply_stage2_model!(String.t() | nil) :: {map(), String.t()}
  def apply_stage2_model!(model_override) do
    # #451 Track C: der gewinnende Key für backend=:local ist der
    # pro-Backend-Key — ein Write auf den Legacy-Key würde von einem
    # persistierten `model_stage2_local` verdeckt.
    model_key = Settings.model_key(2, :local)

    backup = %{
      backend_stage2: Settings.get(:backend_stage2, :local),
      model_stage2: Settings.model_for(2, :local)
    }

    Settings.put(:backend_stage2, :local)

    label =
      case model_override do
        nil ->
          Settings.model_for(2, :local) || "default"

        m ->
          Settings.put(model_key, m)
          m
      end

    {backup, label}
  end

  @spec restore_stage2_model!(map()) :: :ok
  def restore_stage2_model!(backup) do
    Settings.put(:backend_stage2, backup.backend_stage2)
    if backup.model_stage2, do: Settings.put(Settings.model_key(2, :local), backup.model_stage2)
    :ok
  end

  @doc "Liest die Baseline-JSON (leere Map wenn nicht vorhanden)."
  @spec read_baselines(String.t()) :: map()
  def read_baselines(path) do
    case File.read(path) do
      {:ok, raw} -> Jason.decode!(raw)
      {:error, :enoent} -> %{}
    end
  end

  @doc "Schreibt `entry` unter den verschachtelten `keys`-Pfad in die Baseline-Datei."
  @spec write_baseline!(String.t(), [String.t()], map()) :: :ok
  def write_baseline!(path, keys, entry) do
    updated = put_in_safe(read_baselines(path), keys, entry)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(updated, pretty: true) <> "\n")
    :ok
  end

  # ─── intern ──────────────────────────────────────────────────────────

  defp read_jsonl(path) do
    path
    |> File.stream!()
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&Jason.decode!/1)
  end

  defp apply_local!(payload) when is_map(payload) do
    ts =
      payload["timestamp"] || payload["started_at"] || payload["ended_at"] ||
        payload["scheduled_for"] || DateTime.to_iso8601(DateTime.utc_now())

    :ok =
      Worker.Materializer.apply_local(%{
        "event_id" => UUIDv7.generate(),
        "payload" => payload,
        "ts" => ts,
        "author_worker_id" => nil
      })
  end

  defp put_in_safe(map, [k], v), do: Map.put(map, k, v)

  defp put_in_safe(map, [k | rest], v) do
    Map.put(map, k, put_in_safe(Map.get(map, k, %{}), rest, v))
  end
end
