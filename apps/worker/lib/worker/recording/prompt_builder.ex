defmodule Worker.Recording.PromptBuilder do
  @moduledoc false

  # Whisper initial_prompt hat ein Hard-Limit von 224 Tokens (~168 Wörter).
  # Aufteilung: ~38 Wörter für Vokabular-Hint, ~130 für Rolling-Context aus
  # den letzten Utterances derselben Session.
  @vocab_word_limit 38
  @context_word_limit 130

  @spec build(String.t(), String.t()) :: String.t()
  def build(session_id, campaign_id) do
    vocab = vocab_part(campaign_id)
    context = context_part(session_id)

    case {vocab, context} do
      {"", ""} -> Worker.Settings.get(:whisper_initial_prompt, "") || ""
      {"", c} -> c
      {v, ""} -> v
      {v, c} -> "#{v} | #{c}"
    end
  end

  @doc """
  Issue #304: Prompt OHNE Rolling-Context — nur das statische Vokabular (bzw.
  der `:whisper_initial_prompt`-Fallback). Für Single-Source-Transkription, wo
  die Pro-Segment-Rückkopplung der letzten Utterances Whisper-Self-Vergiftung
  auslöst (endlose Wiederholungen). Konsistenz-Nutzen des Vokabulars bleibt,
  ohne den selbstverstärkenden Halluzinations-Pfad.
  """
  @spec build_static(String.t()) :: String.t()
  def build_static(campaign_id) do
    case Worker.Repo.get_campaign(campaign_id) do
      %{vocab_hint: hint} when is_binary(hint) and hint != "" ->
        truncate_words(hint, @vocab_word_limit + @context_word_limit)

      _ ->
        Worker.Settings.get(:whisper_initial_prompt, "") || ""
    end
  end

  defp vocab_part(campaign_id) do
    base =
      case Worker.Repo.get_campaign(campaign_id) do
        %{vocab_hint: hint} when is_binary(hint) and hint != "" ->
          hint

        _ ->
          Worker.Settings.get(:whisper_initial_prompt, "") || ""
      end

    truncate_words(base, @vocab_word_limit)
  end

  # Issue #234: Self-Vergiftung-Mitigation. Statt einfach die letzten 10
  # Utterances zu nehmen, holen wir 30, werfen Halluzinations-Onomatopoetika
  # raus (sonst landet caleb's `*Squeaky*`-Mic-Test im Whisper-Prompt für
  # Paters 110-Min-Audio und Whisper projiziert das in Stille-Phasen rein)
  # und nehmen dann die jüngsten 10 was übrig bleibt.
  defp context_part(session_id) do
    Worker.Repo.list_utterances(session_id, limit: 30)
    |> Enum.filter(&prompt_candidate?/1)
    |> Enum.take(-10)
    |> Enum.map(& &1.text)
    |> Enum.join(" ")
    |> truncate_words(@context_word_limit)
  end

  defp prompt_candidate?(%{text: text, status: status}) when is_binary(text) do
    trimmed = String.trim(text)

    cond do
      status != :confirmed -> false
      String.length(trimmed) < 15 -> false
      length(String.split(trimmed, ~r/\s+/, trim: true)) < 4 -> false
      Regex.match?(~r/^\*[^*]+\*\.?$/, trimmed) -> false
      Regex.match?(~r/^\[[^\]]+\]\.?$/, trimmed) -> false
      Worker.Recording.Transcribe.hallucination?(trimmed) -> false
      true -> true
    end
  end

  defp prompt_candidate?(_), do: false

  defp truncate_words("", _limit), do: ""

  defp truncate_words(text, limit) do
    words = String.split(text, ~r/\s+/, trim: true)

    if length(words) <= limit do
      text
    else
      words |> Enum.take(-limit) |> Enum.join(" ")
    end
  end
end
