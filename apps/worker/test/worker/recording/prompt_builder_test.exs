defmodule Worker.Recording.PromptBuilderTest do
  @moduledoc """
  Issue #234: PromptBuilder.context_part/1 filtert Halluzinations-Onomatopoetika,
  Mindest-Wortzahl, `:confirmed`-Status, und `*...*`/`[...]`-Markers raus, damit
  diese Patterns nicht im Whisper-Initial-Prompt für die nächste Utterance landen
  (Self-Vergiftung). Symptom 26.05.: caleb's `*Squeaky*`-Mic-Test triggerte einen
  30-Min-Loop in Paters 110-Min-Audio.
  """

  use ExUnit.Case, async: false

  alias Worker.Recording.PromptBuilder
  alias Worker.Schema.Mnesia, as: S

  @session_id "019e1111-1111-7111-8111-111111111111"
  @campaign_id "019e2222-2222-7222-8222-222222222222"

  setup do
    {:atomic, :ok} = :mnesia.clear_table(S.utterances())
    {:atomic, :ok} = :mnesia.clear_table(S.applied_event_ids())
    {:atomic, :ok} = :mnesia.clear_table(S.campaigns())

    mat_pid =
      case Worker.Materializer.start_link([]) do
        {:ok, pid} -> pid
        {:error, {:already_started, _}} -> nil
      end

    on_exit(fn ->
      if mat_pid && Process.alive?(mat_pid), do: Process.exit(mat_pid, :kill)
    end)

    :ok
  end

  test "filtert Halluzinations-Patterns aus dem Rolling-Context raus" do
    seed_utterances([
      {"u1", "Margarete betritt den Garten und erzählt Marthe von Faust.", :confirmed},
      {"u2", "*Squeaky*", :confirmed},
      {"u3", "Marthe lacht und reicht Margarete den Brief von Mephisto.", :confirmed}
    ])

    prompt = PromptBuilder.build(@session_id, @campaign_id)

    refute prompt =~ "Squeaky"
    assert prompt =~ "Margarete"
    assert prompt =~ "Marthe"
  end

  test "filtert zu kurze Utterances (<4 Wörter / <15 Zeichen) raus" do
    seed_utterances([
      {"u1", "Margarete erzählt Marthe vom heutigen Treffen mit Faust.", :confirmed},
      {"u2", "ok", :confirmed},
      {"u3", "Ja gut.", :confirmed},
      {"u4", "Mephisto tritt aus dem Schatten und grinst böse.", :confirmed}
    ])

    prompt = PromptBuilder.build(@session_id, @campaign_id)

    refute prompt =~ "ok"
    refute prompt =~ "Ja gut"
    assert prompt =~ "Margarete"
    assert prompt =~ "Mephisto"
  end

  test "filtert :live-Status Utterances raus (nur :confirmed darf in den Prompt)" do
    seed_utterances([
      {"u1", "Margarete betritt den Garten und blickt sich um.", :confirmed},
      {"u2", "Dieser Text ist noch nicht confirmed sondern live.", :live},
      {"u3", "Faust nähert sich Margarete mit einem Lächeln.", :confirmed}
    ])

    prompt = PromptBuilder.build(@session_id, @campaign_id)

    refute prompt =~ "noch nicht confirmed"
    assert prompt =~ "Margarete"
    assert prompt =~ "Faust"
  end

  test "filtert *Markers* und [Klammer-Markers]" do
    seed_utterances([
      {"u1", "*räuspert sich laut und blickt grimmig zur Tür.*", :confirmed},
      {"u2", "[Mephisto lacht hinterhältig im Hintergrund.]", :confirmed},
      {"u3", "Margarete fragt Marthe nach dem Brief von Faust.", :confirmed}
    ])

    prompt = PromptBuilder.build(@session_id, @campaign_id)

    refute prompt =~ "räuspert"
    refute prompt =~ "hinterhältig"
    assert prompt =~ "Margarete"
  end

  test "context-Teil leer wenn alle Utterances gefiltert werden (default vocab bleibt)" do
    seed_utterances([
      {"u1", "*Squeaky*", :confirmed},
      {"u2", "ok", :confirmed},
      {"u3", "[BLANK_AUDIO]", :confirmed}
    ])

    prompt = PromptBuilder.build(@session_id, @campaign_id)
    # Die ungefilterten Onomatopoetika dürfen nicht im Prompt landen
    refute prompt =~ "Squeaky"
    refute prompt =~ "BLANK_AUDIO"
    # Ein " | " (vocab/context-Separator) gibt's nicht, weil context-Teil leer
    refute prompt =~ " | "
  end

  # ─── helpers ────────────────────────────────────────────────────

  defp seed_utterances(utterances) do
    utterances
    |> Enum.with_index()
    |> Enum.each(fn {{id, text, status}, idx} ->
      ts = DateTime.add(~U[2026-05-26 12:00:00Z], idx * 10, :second)

      :mnesia.transaction(fn ->
        :mnesia.write({
          S.utterances(),
          id,
          @session_id,
          "did-#{idx}",
          ts,
          text,
          nil,
          status,
          nil
        })
      end)
    end)
  end
end
