defmodule Worker.Recording.Diarize do
  @moduledoc """
  Speaker diarization for single-source recordings (Issue #19).

  Calls the pyannote sidecar (apps/worker/priv/sidecar/diarization_sidecar.py)
  with the path to a 16 kHz Mono WAV and gets back speaker turns:

      [%{speaker_label: "SPEAKER_00", start_ms: 0, end_ms: 5230}, ...]

  The sidecar reads the WAV from disk by absolute path — it runs as the same
  OS user as the worker, so any path under `:audio_dir` is readable.

  Graceful fallback: if `:diarization_sidecar_url` is not configured or the
  sidecar is unreachable, returns `{:error, :sidecar_offline}`. The caller
  (`Transcribe.run_single_source/2`) treats that as a hard failure for the
  session — without diarization there are no speaker segments to transcribe.
  """

  require Logger

  @type segment :: %{
          speaker_label: String.t(),
          start_ms: non_neg_integer(),
          end_ms: non_neg_integer()
        }

  @doc """
  Diarize the WAV at `wav_path`. `opts[:num_speakers]` (or
  `:min_speakers`/`:max_speakers`) hints pyannote's clustering.

  Returns `{:ok, [segment]}` sorted by `start_ms`, or `{:error, reason}`.
  """
  @spec run(String.t(), keyword()) :: {:ok, [segment()]} | {:error, term()}
  def run(wav_path, opts \\ []) do
    case Worker.Settings.get(:diarization_sidecar_url) do
      nil ->
        {:error, :sidecar_offline}

      url ->
        call_sidecar(url, wav_path, opts)
    end
  end

  defp call_sidecar(base_url, wav_path, opts) do
    url = String.to_charlist("#{base_url}/diarize")
    headers = [{~c"content-type", ~c"application/json"}]

    body =
      %{wav_path: wav_path}
      |> maybe_put(:num_speakers, opts[:num_speakers])
      |> maybe_put(:min_speakers, opts[:min_speakers])
      |> maybe_put(:max_speakers, opts[:max_speakers])
      |> Jason.encode!()

    request = {url, headers, ~c"application/json", body}
    timeout = Worker.Settings.get(:diarization_timeout_ms, 600_000)
    http_opts = [timeout: timeout, connect_timeout: 5_000]

    case :httpc.request(:post, request, http_opts, []) do
      {:ok, {{_, 200, _}, _resp_headers, resp_body}} ->
        parse_segments(resp_body)

      {:ok, {{_, status, _}, _, resp_body}} ->
        Logger.warning("Diarize sidecar returned #{status}: #{resp_body}")
        {:error, {:sidecar_error, status}}

      {:error, {:failed_connect, _}} ->
        {:error, :sidecar_offline}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_segments(resp_body) do
    case Jason.decode(resp_body) do
      {:ok, segments} when is_list(segments) ->
        parsed =
          segments
          |> Enum.map(fn s ->
            %{
              speaker_label: s["speaker_label"],
              start_ms: s["start_ms"],
              end_ms: s["end_ms"]
            }
          end)
          |> Enum.sort_by(& &1.start_ms)

        {:ok, parsed}

      {:ok, other} ->
        {:error, {:bad_response_shape, other}}

      {:error, reason} ->
        {:error, {:bad_json, reason}}
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
