defmodule Worker.LLM.LocalEndpointTest do
  @moduledoc """
  Issue #736: pro-Stage-Local-Backend-Endpoint-Setting
  (`:model_stage{n}_local_endpoint`, Default `:generate`). Der Dispatch
  zwischen `/api/generate` und `/api/chat` hängt daran. Pur testbar über
  `endpoint_for_stage/1` — der Rest ist :httpc-Plumbing. Seit #783 Phase 2
  gibt es drei unabhängige Slots (Stage 2/3/4 = Extraktion/Verify/Render).
  """

  use ExUnit.Case, async: false

  alias Worker.LLM.Local
  alias Worker.Settings

  # Restore-Werte pro Stage, damit die Tests unabhängig vom Setting-State beim
  # Session-Start laufen und ihn wieder hinterlassen wie er war.
  setup do
    keys = [
      :model_stage2_local_endpoint,
      :model_stage3_local_endpoint,
      :model_stage4_local_endpoint
    ]

    before = Enum.into(keys, %{}, fn k -> {k, Settings.get(k)} end)

    on_exit(fn ->
      Enum.each(keys, fn k ->
        case before[k] do
          nil -> :ok
          v -> Settings.put(k, v)
        end
      end)
    end)

    :ok
  end

  describe "endpoint_for_stage/1" do
    test "Default ist :generate (Stage 2, Extraktion)" do
      Settings.put(:model_stage2_local_endpoint, :generate)

      assert Local.endpoint_for_stage(:summary) == :generate
    end

    test "#783 Phase 2: Stage 3 (Verify) + Stage 4 (Render) haben eigene Endpoint-Slots" do
      Settings.put(:model_stage2_local_endpoint, :generate)
      Settings.put(:model_stage3_local_endpoint, :chat)
      Settings.put(:model_stage4_local_endpoint, :generate)

      assert Local.endpoint_for_stage(:summary) == :generate
      assert Local.endpoint_for_stage(:verify) == :chat
      assert Local.endpoint_for_stage(:render) == :generate
    end

    test ":chat als Atom flipt den Dispatch" do
      Settings.put(:model_stage2_local_endpoint, :chat)
      assert Local.endpoint_for_stage(:summary) == :chat
    end

    test "\"chat\" als String (aus UI-Form) flipt ebenfalls" do
      # Der HTML-Form-Submit liefert "chat" statt :chat — beide müssen greifen.
      Settings.put(:model_stage2_local_endpoint, "chat")
      assert Local.endpoint_for_stage(:summary) == :chat
    end

    test "Unerwartete Werte fallen auf :generate zurück (defensiv)" do
      Settings.put(:model_stage2_local_endpoint, "foo")
      assert Local.endpoint_for_stage(:summary) == :generate

      Settings.put(:model_stage2_local_endpoint, :bogus)
      assert Local.endpoint_for_stage(:summary) == :generate

      Settings.put(:model_stage2_local_endpoint, nil)
      assert Local.endpoint_for_stage(:summary) == :generate
    end

    test ":transcribe fällt konstant auf :generate — kein Local-LLM-Weg" do
      # Auch mit einem :chat-Setting für Stage 2 hat :transcribe kein
      # Backend-Stack; die Klausel ist rein Boundary-Defense.
      Settings.put(:model_stage2_local_endpoint, :chat)
      assert Local.endpoint_for_stage(:transcribe) == :generate
    end
  end
end
