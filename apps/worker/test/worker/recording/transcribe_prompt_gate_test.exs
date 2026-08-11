defmodule Worker.Recording.TranscribePromptGateTest do
  @moduledoc """
  Issue #1000: der Whisper-`--prompt` kann die Dekodierung einer ganzen Spur in
  eine Wiederholungsschleife kippen, die den echten Inhalt verdrängt (A/B am
  echten Session-Audio: 63 Zeilen, davon 61× derselbe Satz — mit Prompt; 40
  Zeilen mit 13 verschiedenen — ohne). `whisper_use_prompt` gatet das, Default AUS.

  Getestet wird die Argument-Erzeugung `build_whisper_args/2` — also GENAU die
  Liste, die auch die Produktion an whisper-cli übergibt (kein Nachbau, der die
  Abweichung verstecken würde).
  """
  use ExUnit.Case, async: false

  import Worker.TestHelper

  alias Worker.Recording.Transcribe

  setup do
    clear_all_tables!()
    {:atomic, :ok} = :mnesia.clear_table(Worker.Schema.Mnesia.worker_state())
    Worker.Settings.put(:whisper_bin, "whisper-cli")
    Worker.Settings.put(:whisper_model, "/tmp/model.bin")
    :ok
  end

  defp args(opts), do: Transcribe.build_whisper_args("/tmp/spur.wav", opts)

  describe "Default-Zustand (Issue #1000: Prompt AUS)" do
    test "ohne Zutun wird KEIN --prompt übergeben" do
      refute "--prompt" in args(discord_id: "did-1")
    end

    test "auch MIT Session-/Campaign-Kontext kein --prompt (der Batch-Pfad war der Schadensfall)" do
      refute "--prompt" in args(session_id: "sess-1", campaign_id: "camp-1", discord_id: "did-1")
    end

    test "whisper_prompt/1 liefert leer, obwohl ein Vokabular-Setting gesetzt ist" do
      Worker.Settings.put(:whisper_initial_prompt, "Würfel: W20, Initiative")
      assert Transcribe.whisper_prompt(discord_id: "did-1") == ""
    end
  end

  describe "Opt-in (whisper_use_prompt: true)" do
    setup do
      Worker.Settings.put(:whisper_use_prompt, true)
      :ok
    end

    test "ohne Session-Kontext kommt der Vokabular-Prompt aus den Settings" do
      Worker.Settings.put(:whisper_initial_prompt, "Würfel: W20, Initiative")

      a = args(discord_id: "did-1")
      assert "--prompt" in a
      assert "Würfel: W20, Initiative" in a
    end

    test "leerer Vokabular-Prompt → weiterhin kein --prompt-Flag" do
      Worker.Settings.put(:whisper_initial_prompt, "")
      refute "--prompt" in args(discord_id: "did-1")
    end
  end

  describe "no_prompt (Single-Source, #304) bleibt unabhängig wirksam" do
    test "überstimmt auch ein eingeschaltetes whisper_use_prompt" do
      Worker.Settings.put(:whisper_use_prompt, true)
      Worker.Settings.put(:whisper_initial_prompt, "Würfel: W20")

      refute "--prompt" in args(session_id: "s", campaign_id: "c", no_prompt: true)
      assert Transcribe.whisper_prompt(session_id: "s", campaign_id: "c", no_prompt: true) == ""
    end
  end

  describe "die übrigen Flags bleiben unangetastet" do
    # Gegenprobe zur Messung: --max-len und --split-on-word wurden einzeln
    # getestet und sind UNSCHÄDLIG (13 statt 12 Zeilen) — sie dürfen durch den
    # Prompt-Fix nicht mit abgeschaltet werden.
    test "max-len + split-on-word + Thresholds weiterhin gesetzt" do
      Worker.Settings.put(:whisper_max_len, 120)
      Worker.Settings.put(:whisper_split_on_word, true)

      a = args(discord_id: "did-1")

      assert "--max-len" in a
      assert "120" in a
      assert "--split-on-word" in a
      assert "--no-speech-thold" in a
      assert "--entropy-thold" in a
      assert "--logprob-thold" in a
      # Full-JSON bleibt Pflicht (#376: Per-Token-Confidence).
      assert "-ojf" in a
    end
  end
end
