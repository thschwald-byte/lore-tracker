defmodule Worker.Discord.ConsentCheck do
  @moduledoc """
  Issue #1002: wertet die Frames des Consent-Fensters pro Sprecher aus —
  Frames → Clip → Whisper → `Worker.Recording.ConsentPhrase`-Urteil.

  Läuft im `Worker.TaskSupervisor` (nicht im `VoiceSession`-GenServer), weil
  `Transcribe.transcribe_clip/1` blockierend ist (`System.cmd` auf whisper-cli):
  im GenServer würden sich die eingehenden Voice-Pakete für Sekunden stauen.

  **Nichts hiervon wird persistiert.** Die Clips entstehen nur zur Prüfung und
  werden verworfen; es gibt keinen `AudioBuffer.append/4`-Aufruf. Das grenzt das
  Bootstrap-Problem ein („um die Zustimmung zu hören, muss man zuhören"):
  verarbeitet ja, gespeichert nein.

  **Fail-closed an jeder Kante:** ein Sprecher, dessen SSRC nicht auflösbar ist,
  dessen Clip-Bau scheitert oder dessen Transkription fehlschlägt, bekommt
  **kein** `:granted`. Wer im Fenster gar nichts sagt, erscheint überhaupt nicht
  im Ergebnis — und ohne Eintrag gilt keine Zustimmung.
  """

  require Logger

  alias Worker.Recording.{ConsentPhrase, Transcribe}

  @doc """
  `frames` (chronologisch) + `ssrc_map` (`%{ssrc => discord_id}`) →
  `%{discord_id_string => verdict}`.

  SSRCs ohne Mapping werden verworfen (dieselbe Regel wie im Aufnahme-Pfad:
  kein Audio-Urteil ohne geklärte Identität — sonst würde eine Zustimmung
  womöglich der falschen Person zugeschrieben).
  """
  @spec evaluate_frames([map()], %{optional(integer()) => integer()}) :: %{
          optional(String.t()) => ConsentPhrase.verdict()
        }
  def evaluate_frames([], _ssrc_map), do: %{}

  def evaluate_frames(frames, ssrc_map) when is_list(frames) and is_map(ssrc_map) do
    frames
    |> Worker.Discord.AudioBridge.build_speaker_clips()
    |> Enum.reduce(%{}, fn {ssrc, clip_result}, acc ->
      case Map.get(ssrc_map, ssrc) do
        nil ->
          Logger.warning(
            "ConsentCheck: kein SSRC->User-Mapping für ssrc=#{ssrc} — Zustimmung nicht zuordenbar, verworfen"
          )

          acc

        discord_id ->
          Map.put(acc, to_string(discord_id), verdict_for(clip_result, discord_id))
      end
    end)
  end

  def evaluate_frames(_, _), do: %{}

  defp verdict_for({:ok, base64_webm}, discord_id) do
    with {:ok, webm} <- decode(base64_webm),
         {:ok, transcript} <- Transcribe.transcribe_clip(webm) do
      verdict = ConsentPhrase.evaluate(transcript)

      Logger.info(
        "ConsentCheck: did=#{discord_id} verdict=#{verdict} transcript=#{inspect(String.slice(transcript, 0, 120))}"
      )

      verdict
    else
      {:error, reason} ->
        # Kein Urteil möglich ⇒ :unclear (nicht :granted). Ein technischer
        # Fehler darf nie zu einer unterstellten Zustimmung führen.
        Logger.warning(
          "ConsentCheck: Auswertung für did=#{discord_id} fehlgeschlagen: #{inspect(reason)} — gilt als unclear"
        )

        :unclear
    end
  end

  defp verdict_for({:error, reason}, discord_id) do
    Logger.warning(
      "ConsentCheck: Clip-Bau für did=#{discord_id} fehlgeschlagen: #{inspect(reason)} — gilt als unclear"
    )

    :unclear
  end

  defp decode(base64) do
    case Base.decode64(base64) do
      {:ok, bin} -> {:ok, bin}
      :error -> {:error, :undecodable_base64}
    end
  end
end
