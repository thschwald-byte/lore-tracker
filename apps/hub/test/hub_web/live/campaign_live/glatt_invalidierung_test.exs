defmodule HubWeb.CampaignLive.GlattInvalidierungTest do
  @moduledoc """
  Issue #1153 (C6): ein Scope-Reload ersetzt `smoothed`, aber NICHT `glatt_texte`.

  Das ist Absicht — sonst würfe jede Kuration alles Nachgeladene weg und der
  Betrachter sähe gelesene Blöcke wieder leer. Es hat aber eine Kante: ein
  einmal nachgeladener Block zeigte bis zum Neuladen der Seite den Stand seines
  ersten Ladens. `block_texte/4` im Worker trägt neben `text` auch
  `vorschlag_text`, `vorschlag_modell` und `override` — nach einem
  `LueckenVorschlagGeneriert` fehlte also das 💡 in der Standardansicht, nach
  einer manuellen Korrektur blieben ✎-Zeile und „von X" veraltet.

  An seattleV4 S1 umfasst der Worker-Tail 10 Texte; praktisch jeder dort
  kuratierte Block liegt außerhalb.
  """

  use ExUnit.Case, async: true

  alias HubWeb.CampaignLive.Updates

  defp sock(assigns), do: %Phoenix.LiveView.Socket{assigns: Map.put(assigns, :__changed__, %{})}

  describe "invalidiere_glatt_texte/3" do
    test "ein Vorschlags-Event verwirft genau seinen Block" do
      s =
        sock(%{glatt_texte: %{"b1" => %{"text" => "alt"}, "b2" => %{"text" => "bleibt"}}})
        |> Updates.invalidiere_glatt_texte(Shared.Events.luecken_vorschlag_generiert(), %{
          "block_id" => "b1"
        })

      refute Map.has_key?(s.assigns.glatt_texte, "b1")
      assert s.assigns.glatt_texte["b2"] == %{"text" => "bleibt"}
    end

    test "ein Kurations-Event verwirft genau seinen Block" do
      s =
        sock(%{glatt_texte: %{"b1" => %{"text" => "alt"}}})
        |> Updates.invalidiere_glatt_texte(Shared.Events.luecken_kuration_set(), %{
          "block_id" => "b1"
        })

      assert s.assigns.glatt_texte == %{}
    end

    test "andere Events lassen den Bestand unangetastet" do
      # TranscriptSmoothed lädt denselben Scope neu, trägt aber keine Block-ID.
      # Für ihn stutzt `stutze_glatt_texte/2` beim Apply, s.u.
      bestand = %{"b1" => %{"text" => "alt"}}

      s =
        sock(%{glatt_texte: bestand})
        |> Updates.invalidiere_glatt_texte(Shared.Events.transcript_smoothed(), %{
          "block_id" => "b1"
        })

      assert s.assigns.glatt_texte == bestand
    end

    test "ohne block_id passiert nichts (kein Absturz)" do
      bestand = %{"b1" => %{"text" => "alt"}}

      s =
        sock(%{glatt_texte: bestand})
        |> Updates.invalidiere_glatt_texte(Shared.Events.luecken_kuration_set(), %{})

      assert s.assigns.glatt_texte == bestand
    end
  end

  describe "stutze_glatt_texte/2 — Waisen nach einem Re-Smoothing" do
    test "Einträge ohne Block im neuen Skelett fallen raus" do
      smoothed = [%{"session_id" => "s1", "blocks" => [%{"block_id" => "neu"}]}]

      s =
        sock(%{glatt_texte: %{"alt" => %{"text" => "waise"}, "neu" => %{"text" => "lebt"}}})
        |> Updates.stutze_glatt_texte(smoothed)

      assert Map.keys(s.assigns.glatt_texte) == ["neu"]
    end

    test "leerer Bestand bleibt leer, auch ohne Skelett" do
      s = sock(%{glatt_texte: %{}}) |> Updates.stutze_glatt_texte([])
      assert s.assigns.glatt_texte == %{}
    end
  end
end
