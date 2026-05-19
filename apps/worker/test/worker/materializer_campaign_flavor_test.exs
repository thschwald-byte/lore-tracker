defmodule Worker.MaterializerCampaignFlavorTest do
  @moduledoc """
  Smoke tests für `CampaignFlavorSet`: setzt + überschreibt + reset auf nil,
  ignoriert unbekannte campaign_id.
  """

  use ExUnit.Case, async: false

  alias Worker.Materializer
  alias Worker.Schema.Mnesia, as: S

  @cid "camp-flavor-test"
  @owner "owner-did"

  setup do
    {:atomic, :ok} = :mnesia.clear_table(S.campaigns())
    {:atomic, :ok} = :mnesia.clear_table(S.worker_state())

    mat_pid =
      case Worker.Materializer.start_link([]) do
        {:ok, pid} -> pid
        {:error, {:already_started, _}} -> nil
      end

    {:atomic, :ok} =
      :mnesia.transaction(fn ->
        :mnesia.write({
          S.campaigns(),
          @cid,
          "Test Campaign",
          nil,
          nil,
          :active,
          @owner,
          DateTime.utc_now(),
          nil
        })
      end)

    on_exit(fn ->
      if mat_pid && Process.alive?(mat_pid), do: Process.exit(mat_pid, :kill)
    end)

    :ok
  end

  defp event(payload, seq) do
    %{
      "seq" => seq,
      "ts" => DateTime.to_iso8601(DateTime.utc_now()),
      "author_worker_id" => "test",
      "payload" => Map.put(payload, "kind", "CampaignFlavorSet")
    }
  end

  test "setzt flavor + überschreibt + resettet auf nil" do
    ev1 = event(%{"campaign_id" => @cid, "flavor" => "Düster", "edited_by" => "x"}, 400)
    assert {:applied, 400} = Materializer.apply_event(ev1)

    [{_, _, _, _, _, _, _, _, flavor}] = :mnesia.dirty_read(S.campaigns(), @cid)
    assert flavor == "Düster"

    ev2 = event(%{"campaign_id" => @cid, "flavor" => "Cyberpunk", "edited_by" => "x"}, 401)
    assert {:applied, 401} = Materializer.apply_event(ev2)
    [{_, _, _, _, _, _, _, _, flavor2}] = :mnesia.dirty_read(S.campaigns(), @cid)
    assert flavor2 == "Cyberpunk"

    ev3 = event(%{"campaign_id" => @cid, "flavor" => nil, "edited_by" => "x"}, 402)
    assert {:applied, 402} = Materializer.apply_event(ev3)
    [{_, _, _, _, _, _, _, _, flavor3}] = :mnesia.dirty_read(S.campaigns(), @cid)
    assert flavor3 == nil
  end

  test "unbekannte campaign_id wird ignoriert" do
    ev = event(%{"campaign_id" => "unknown", "flavor" => "x", "edited_by" => "y"}, 410)
    assert {:applied, 410} = Materializer.apply_event(ev)
  end
end
