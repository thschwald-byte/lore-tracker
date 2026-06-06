defmodule Worker.Recording.CampaignReplayTest do
  @moduledoc """
  Issue #608: Smoke für die Backfill-Sequenzierung. Bewusst auf die
  deterministischen, nebenwirkungsfreien Pfade beschränkt (running/0 + das
  Empty-Guard) — der „already_running"-Lock erfordert einen echten Replay-Run,
  der auf dieser Maschine eine reale LLM-Pipeline (Ollama) triggern würde; das
  gehört in einen Integrationstest (#543), nicht in den Unit-Smoke.
  """
  use ExUnit.Case, async: false

  import Worker.TestHelper

  alias Worker.Recording.CampaignReplay
  alias Worker.Schema.Builder

  setup do
    clear_all_tables!()
    ensure_started(CampaignReplay, fn -> CampaignReplay.start_link([]) end)
    :ok
  end

  test "running/0 ist nil, solange kein Replay läuft" do
    assert CampaignReplay.running() == nil
  end

  test "start/2 ohne Sessions-mit-Utterances → {:error, :no_sessions_with_utterances}" do
    # Session existiert, hat aber keine Utterances → kein Backfill-Kandidat,
    # kein Task wird gespawnt (deterministisch, kein Pipeline-Trigger).
    Builder.write!(Builder.session("s-empty", "c-empty", number: 1))

    assert {:error, :no_sessions_with_utterances} =
             CampaignReplay.start("c-empty", "did-gm")

    # Guard hat KEINEN Run gestartet.
    assert CampaignReplay.running() == nil
  end
end
