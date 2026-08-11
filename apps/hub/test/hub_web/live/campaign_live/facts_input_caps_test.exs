defmodule HubWeb.CampaignLive.FactsInputCapsTest do
  @moduledoc """
  Issue #994: Längen-Cap im Fakten-Kurations-Publish (#916). `:curate_facts` ist
  ein MEMBER-Recht — ohne Cap landet ein Multi-MB-Blob im per-Campaign-Event-Store
  und wird via Gossip-Pull auf jeden Member-Worker repliziert (das #636-Threat-
  Model, das für jedes andere User-String-Save im CampaignLive schon greift).

  Beobachtungspunkt ohne Mocking: `Publisher.publish/2` schickt bei fehlendem
  Worker ein `{:bridge_publish_failed, kind}` an den eigenen Prozess. Kommt die
  Nachricht → es WURDE publisht; bleibt sie aus → der Cap hat geblockt.
  """
  use ExUnit.Case, async: true

  alias HubWeb.CampaignLive.Facts

  @quell "u1,u2"

  defp socket do
    %Phoenix.LiveView.Socket{
      assigns:
        %{
          campaign_id: "camp-994",
          campaign: %{"id" => "camp-994"},
          perm_user: %{discord_id: "did-1", role: :spieler, campaign_role: :spieler},
          facts_editing: {"sess-1", "f1", "claim"},
          flash: %{}
        }
        |> Map.put(:__changed__, %{})
    }
  end

  defp save(field, value) do
    Facts.fact_event(socket(), "fact_save", %{
      "session" => "sess-1",
      "quell" => @quell,
      "field" => field,
      "value" => value
    })
  end

  describe "claim" do
    test "innerhalb des Caps → wird publisht" do
      {:noreply, s} = save("claim", String.duplicate("a", 4_000))

      assert_received {:bridge_publish_failed, "FactCurationSet"}
      refute Phoenix.Flash.get(s.assigns.flash, :error)
    end

    test "über dem Cap → KEIN Publish, Flash-Error, Edit-State bleibt offen" do
      {:noreply, s} = save("claim", String.duplicate("a", 4_001))

      refute_received {:bridge_publish_failed, _}
      assert Phoenix.Flash.get(s.assigns.flash, :error) =~ "Fakt"
      assert Phoenix.Flash.get(s.assigns.flash, :error) =~ "4000"
      # Der Edit bleibt offen, damit der User kürzen kann statt seinen Text zu verlieren.
      assert s.assigns.facts_editing == {"sess-1", "f1", "claim"}
    end

    test "Multi-MB-Blob (das eigentliche Threat) → geblockt" do
      {:noreply, _s} = save("claim", String.duplicate("x", 5_000_000))
      refute_received {:bridge_publish_failed, _}
    end
  end

  describe "character" do
    test "über dem 200-Byte-Cap → geblockt" do
      {:noreply, s} = save("character", String.duplicate("n", 201))

      refute_received {:bridge_publish_failed, _}
      assert Phoenix.Flash.get(s.assigns.flash, :error) =~ "Figur"
    end
  end

  describe "thread (JSON-Array, #953)" do
    test "sehr viele/lange Labels → geblockt (Cap greift auf dem finalen JSON)" do
      labels = Enum.map_join(1..500, "\n", fn i -> String.duplicate("label#{i}", 20) end)
      {:noreply, _s} = Facts.fact_event(socket(), "fact_save", %{
        "session" => "sess-1",
        "quell" => @quell,
        "field" => "thread",
        "value" => labels
      })

      refute_received {:bridge_publish_failed, _}
    end

    test "normale Label-Liste → wird publisht" do
      {:noreply, _s} = Facts.fact_event(socket(), "fact_save", %{
        "session" => "sess-1",
        "quell" => @quell,
        "field" => "thread",
        "value" => "Die Fotografie\nDer Brief"
      })

      assert_received {:bridge_publish_failed, "FactCurationSet"}
    end
  end

  describe "Toggles (verified/dismissed)" do
    test "normaler Toggle-Wert → wird publisht" do
      {:noreply, _s} =
        Facts.fact_event(socket(), "fact_toggle", %{
          "session" => "sess-1",
          "quell" => @quell,
          "field" => "verified",
          "value" => "true"
        })

      assert_received {:bridge_publish_failed, "FactCurationSet"}
    end

    test "aufgeblähter phx-value (client-kontrolliert!) → geblockt" do
      {:noreply, _s} =
        Facts.fact_event(socket(), "fact_toggle", %{
          "session" => "sess-1",
          "quell" => @quell,
          "field" => "dismissed",
          "value" => String.duplicate("y", 1_000)
        })

      refute_received {:bridge_publish_failed, _}
    end
  end

  test "Nicht-Member → weiterhin Berechtigungs-Fehler (Cap ändert das Gate nicht)" do
    s = socket()
    s = %{s | assigns: Map.put(s.assigns, :perm_user, %{discord_id: "x", role: :spieler})}

    {:noreply, out} =
      Facts.fact_event(s, "fact_save", %{
        "session" => "sess-1",
        "quell" => @quell,
        "field" => "claim",
        "value" => "kurz"
      })

    refute_received {:bridge_publish_failed, _}
    assert Phoenix.Flash.get(out.assigns.flash, :error) =~ "Berechtigung"
  end
end
