defmodule Worker.LLM.Mock do
  @moduledoc """
  Deterministic stub backend. No model loading, no network, sub-ms latency —
  perfect for iterating on pipeline orchestration logic.

  Output shape depends on a `:stage` opt: each stage returns content of the
  right kind so the materializer downstream applies cleanly. The actual
  text is a recognizable mock ("[mock-summary] N utterances at hh:mm:ss")
  so it's obvious in the UI what's stubbed.
  """

  @behaviour Worker.LLM.Backend

  @impl true
  def complete(prompt, opts) do
    stage = Keyword.get(opts, :stage, :summary)
    now = DateTime.utc_now() |> Calendar.strftime("%H:%M:%S")

    text =
      case stage do
        :summary ->
          n = lines(prompt)

          "[mock-summary @ #{now}] Verdichtung aus #{n} Snippets. " <>
            "Die Gruppe handelte, würfelte, jemand sagte etwas Plot-relevantes."

        :epos ->
          n = lines(prompt)

          """
          # Kapitel (mock)

          Hier wäre der eingefügte Epos-Text. Quelle: #{n} Eingangs-Zeilen
          (Snippets + bisheriges Resümee), generiert um #{now}.
          """

        :chronik ->
          """
          - 550 CY · Departure from Oakhaven · die Helden brechen auf
          - 552 CY - Spring · Discovery of the Sunken Crypt · sie finden den Eingang
          - 552 CY - Spring · Encounter with Grizlow · der Goblin-Schamane am Altar
          """

        other ->
          "[mock] no template for stage=#{inspect(other)} @ #{now}"
      end

    {:ok, text}
  end

  @impl true
  def transcribe(_audio, _opts) do
    {:ok,
     [
       %{
         discord_id: "mock-speaker",
         text: "[mock-transcript] this would be the spoken text",
         timestamp: DateTime.utc_now()
       }
     ]}
  end

  defp lines(s) when is_binary(s), do: s |> String.split("\n", trim: true) |> length()
  defp lines(_), do: 0
end
