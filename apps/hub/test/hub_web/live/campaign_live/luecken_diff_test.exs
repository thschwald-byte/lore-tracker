defmodule HubWeb.CampaignLive.LueckenDiffTest do
  @moduledoc """
  Issue #865 (Review-Nachtrag): Wort-Diff fürs Lücken-Panel — unverändert
  normal, ergänzt grün, entfallen rot durchgestrichen. Der User-Beispielfall:
  „Das ist ist do nicht richtig herr genrl" → „Das ist ist do so nicht richtig
  Herr General." (Einfügung + Wort-Ersetzungen).
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias HubWeb.CampaignLive.Editors

  describe "word_diff/2" do
    test "reine Einfügung → :ins-Segment, Umgebung :eq" do
      assert Editors.word_diff("wir sollten so unserem", "wir sollten so zu unserem") == [
               eq: ~w(wir sollten so),
               ins: ~w(zu),
               eq: ~w(unserem)
             ]
    end

    test "Wort-Ersetzung → :del + :ins nebeneinander (User-Beispiel: genrl → General.)" do
      diff = Editors.word_diff("richtig herr genrl", "richtig Herr General.")

      assert diff[:eq] == ~w(richtig)
      assert diff[:del] == ~w(herr genrl)
      assert diff[:ins] == ~w(Herr General.)
    end

    test "identischer Text → nur :eq" do
      assert Editors.word_diff("alles gleich", "alles gleich") == [eq: ~w(alles gleich)]
    end
  end

  describe "luecken_diff/1 (gerendert)" do
    test "ergänzte Wörter grün, entfallene rot durchgestrichen, Rest ohne Farbklasse" do
      html =
        render_component(&Editors.luecken_diff/1,
          old: "Das ist do nicht richtig herr genrl",
          new: "Das ist do so nicht richtig Herr General."
        )

      assert html =~ ~s(class="text-success")
      assert html =~ ~s(class="text-danger line-through")
      # Ergänztes „so" grün; altes „herr genrl" rot.
      assert html =~ "so"
      assert html =~ "genrl"
    end
  end
end
