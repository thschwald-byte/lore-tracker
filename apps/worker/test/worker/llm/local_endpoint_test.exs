defmodule Worker.LLM.LocalEndpointTest do
  @moduledoc """
  Issue #736: pro-Stage-Local-Backend-Endpoint-Setting
  (`:model_stage{n}_local_endpoint`, Default `:generate`). Der Dispatch
  zwischen `/api/generate` und `/api/chat` hängt daran. Pur testbar über
  `endpoint_for_stage/1` — der Rest ist :httpc-Plumbing. Seit #783 Phase 2
  hat jede LLM-Stufe ihren eigenen Slot; nach J4 (#1207, Stufe 3 entfallen)
  sind es drei (Stage 2/4/5 = Extraktion/Render-Resümee/Render-Epos).
  """

  use ExUnit.Case, async: false

  alias Worker.LLM.Local
  alias Worker.Settings

  # Restore-Werte pro Stage, damit die Tests unabhängig vom Setting-State beim
  # Session-Start laufen und ihn wieder hinterlassen wie er war.
  setup do
    keys = [
      :model_stage2_local_endpoint,
      :model_stage4_local_endpoint,
      :model_stage5_local_endpoint
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

    test "#783 Phase 2: Stage 4 (Render-Resümee) + Stage 5 (Render-Epos) haben eigene Endpoint-Slots" do
      Settings.put(:model_stage2_local_endpoint, :generate)
      Settings.put(:model_stage4_local_endpoint, :chat)
      Settings.put(:model_stage5_local_endpoint, :generate)

      assert Local.endpoint_for_stage(:summary) == :generate
      assert Local.endpoint_for_stage(:render) == :chat
      assert Local.endpoint_for_stage(:epos) == :generate
    end

    test "J4 (#1207): Stufe 3 (:verify) ist kein Stage-Atom mehr" do
      assert_raise FunctionClauseError, fn -> Local.endpoint_for_stage(:verify) end
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

  describe "resolve_endpoint/2 — Per-Call-Override (#855, Epic #854 Slice 0)" do
    test ":endpoint-Override schlägt das Stage-Setting (:chat über :generate)" do
      Settings.put(:model_stage4_local_endpoint, :generate)
      assert Local.resolve_endpoint([endpoint: :chat], :render) == :chat
    end

    test "\"chat\" als String-Override greift ebenfalls (UI-Form-Shape)" do
      Settings.put(:model_stage4_local_endpoint, :generate)
      assert Local.resolve_endpoint([endpoint: "chat"], :render) == :chat
    end

    test ":generate-Override schlägt ein :chat-Setting (andere Richtung)" do
      Settings.put(:model_stage4_local_endpoint, :chat)
      assert Local.resolve_endpoint([endpoint: :generate], :render) == :generate
      assert Local.resolve_endpoint([endpoint: "generate"], :render) == :generate
    end

    test "ohne :endpoint-Opt gilt das Stage-Setting (unverändert)" do
      Settings.put(:model_stage4_local_endpoint, :chat)
      assert Local.resolve_endpoint([], :render) == :chat

      Settings.put(:model_stage4_local_endpoint, :generate)
      assert Local.resolve_endpoint([], :render) == :generate
    end

    test "unerwarteter Override-Wert fällt auf das Stage-Setting zurück (defensiv)" do
      Settings.put(:model_stage4_local_endpoint, :chat)
      assert Local.resolve_endpoint([endpoint: "bogus"], :render) == :chat
      assert Local.resolve_endpoint([endpoint: :nonsense], :render) == :chat
      assert Local.resolve_endpoint([endpoint: nil], :render) == :chat
    end

    test "der Override schreibt NICHTS in die Settings (kein persistenter Leak)" do
      Settings.put(:model_stage4_local_endpoint, :generate)
      assert Local.resolve_endpoint([endpoint: :chat], :render) == :chat
      # Das Setting muss unverändert :generate sein — der Sweep-Kandidat darf
      # den globalen Stage-4-Endpoint nicht verstellen.
      assert Local.endpoint_for_stage(:render) == :generate
    end
  end
end
