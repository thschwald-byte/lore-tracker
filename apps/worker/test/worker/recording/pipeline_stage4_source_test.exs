defmodule Worker.Recording.PipelineStage4SourceTest do
  @moduledoc """
  Issue #436: Stage 4 (Chronik) muss aus dem SESSION-eigenen Resümee
  extrahieren, nicht aus dem campaign-weiten Epos. Der Epos aggregiert alle
  Sessions (stage3 by design) — als Stage-4-Input leakten daraus Plot-Beats
  späterer Sessions in die Chronik dieser einen Session (Future-Plot-Leak,
  Musketiere-Befund). `stage4_source_text/2` scoped den Input strukturell auf
  die triggernde Session, mit Epos-Fallback wenn (noch) kein Resümee da ist.
  """
  use ExUnit.Case, async: false

  import Worker.TestHelper

  alias Worker.Recording.Pipeline
  alias Worker.Schema.Builder

  @cid "camp-stage4-source"
  @sid "sess-stage4-source"
  @epos_md "GESAMT-EPOS über alle Sessions: ... Session 4 Ernennung zum Lieutenant ..."

  setup do
    clear_all_tables!()
    Builder.write!(Builder.campaign(@cid, name: "Test"))
    Builder.write!(Builder.session(@sid, @cid, number: 1, name: "Akt I", status: :completed))
    :ok
  end

  test "nimmt das Session-Resümee als Quelle, nicht den campaign-weiten Epos" do
    Builder.write!(Builder.session_summary(@sid, @cid, content_md: "NUR SESSION 1 INHALT"))
    assert Pipeline.stage4_source_text(@sid, @epos_md) == "NUR SESSION 1 INHALT"
  end

  test "fällt auf den Epos zurück, wenn kein Session-Resümee existiert" do
    assert Pipeline.stage4_source_text(@sid, @epos_md) == @epos_md
  end

  test "fällt auf den Epos zurück bei leerem Resümee-Content" do
    Builder.write!(Builder.session_summary(@sid, @cid, content_md: ""))
    assert Pipeline.stage4_source_text(@sid, @epos_md) == @epos_md
  end
end
