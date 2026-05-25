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

  defp context_part(session_id) do
    Worker.Repo.recent_utterance_texts(session_id, 10)
    |> Enum.join(" ")
    |> truncate_words(@context_word_limit)
  end

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
