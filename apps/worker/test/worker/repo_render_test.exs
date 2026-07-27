defmodule Worker.RepoRenderTest do
  @moduledoc """
  Issue #914 (Cut 0): die PURE Anzeige-Ableitung `Repo.Render.displayed/1`.
  Deckt die Cut-0-Testmatrix ab — inkl. der von der Review geforderten Fälle
  (Freigabe an konkrete version_id gebunden, Reorder, Regenerate ohne
  manuellen Akt).
  """
  use ExUnit.Case, async: true

  alias Worker.Repo.Render

  # event_ids als zeit-geordnete Strings (UUIDv7-Surrogat): "e5" < "e7" < "e9".
  defp slots(kw), do: Map.new(kw)

  test "nur generiert, kein manueller Akt → generiert, kein Prompt" do
    d = Render.displayed(slots(generated_md: "G1", generated_version_id: "e1"))
    assert d == %{content_md: "G1", source: :generiert, rebuild_available?: false}
  end

  test "Edit ohne Freigabe → kuratiert gewinnt, Prompt (generiert weicht ab)" do
    d =
      Render.displayed(
        slots(
          generated_md: "G1",
          generated_version_id: "e1",
          curated_md: "M1",
          curated_event_id: "e5"
        )
      )

    assert d.content_md == "M1"
    assert d.source == :kuratiert
    assert d.rebuild_available?
  end

  test "Freigabe für die AKTUELLE Fassung → generiert, kein Prompt" do
    d =
      Render.displayed(
        slots(
          generated_md: "G1",
          generated_version_id: "v1",
          curated_md: "M1",
          curated_event_id: "e5",
          released_version_id: "v1",
          release_event_id: "e7"
        )
      )

    assert d.content_md == "G1"
    assert d.source == :generiert
    refute d.rebuild_available?
  end

  test "Freigabe für v1, dann Rebuild v2 → Freigabe stale → kuratiert, Prompt erscheint erneut" do
    d =
      Render.displayed(
        slots(
          generated_md: "G2",
          generated_version_id: "v2",
          curated_md: "M1",
          curated_event_id: "e5",
          released_version_id: "v1",
          release_event_id: "e7"
        )
      )

    assert d.content_md == "M1"
    assert d.source == :kuratiert
    assert d.rebuild_available?
  end

  test "Reorder [Edit e9, Freigabe e5] → manueller Edit ist jünger → kuratiert gewinnt" do
    d =
      Render.displayed(
        slots(
          generated_md: "G1",
          generated_version_id: "v1",
          curated_md: "M2",
          curated_event_id: "e9",
          released_version_id: "v1",
          release_event_id: "e5"
        )
      )

    assert d.content_md == "M2"
    assert d.source == :kuratiert
    assert d.rebuild_available?
  end

  test "kuratiert == generiert → kuratiert angezeigt, aber kein Prompt (nichts zu übernehmen)" do
    d =
      Render.displayed(
        slots(
          generated_md: "SAME",
          generated_version_id: "e1",
          curated_md: "SAME",
          curated_event_id: "e5"
        )
      )

    assert d.source == :kuratiert
    refute d.rebuild_available?
  end

  test "kuratiert vorhanden, generiert leer → kuratiert, kein Prompt" do
    d = Render.displayed(slots(curated_md: "M1", curated_event_id: "e5"))
    assert d.content_md == "M1"
    assert d.source == :kuratiert
    refute d.rebuild_available?
  end

  test "beide Slots leer → generiert(nil), kein Prompt" do
    d = Render.displayed(slots([]))
    assert d == %{content_md: nil, source: :generiert, rebuild_available?: false}
  end

  test "Freigabe ohne kuratierten Edit (direkte Zustimmung) → generiert, kein Prompt" do
    d =
      Render.displayed(
        slots(
          generated_md: "G1",
          generated_version_id: "v1",
          released_version_id: "v1",
          release_event_id: "e7"
        )
      )

    assert d.source == :generiert
    refute d.rebuild_available?
  end
end
