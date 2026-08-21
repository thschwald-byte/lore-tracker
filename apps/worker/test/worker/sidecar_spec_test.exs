defmodule Worker.SidecarSpecTest do
  @moduledoc """
  Issue #296: `Worker.Sidecar` ist spec-getrieben. Diese Tests decken den reinen
  Spec-Builder ab — Name/Port/Setting + die Diarisierungs-spezifischen
  Subprozess-Env-Vars.

  #1124: der Faithfulness-Spec ist entfallen, seither gibt es nur noch eine
  Instanz (Diarisierung).
  """

  use ExUnit.Case, async: false

  alias Worker.Sidecar

  test "diarization-spec trägt Name, Port und Setting-Key" do
    d = Sidecar.diarization_spec()

    assert d.name == :diarization_sidecar
    assert d.default_port == 8766
    assert d.setting_key == :diarization_sidecar_url
    assert d.script == "diarization_sidecar.py"
  end

  test "diarization-spec setzt den MIOpen-Build-Workaround als Subprozess-Env" do
    extra = Sidecar.diarization_spec().extra_env
    assert {"MIOPEN_DEBUG_COMGR_HIP_BUILD_FATBIN", "0"} in extra
  end

  test "diarization-spec reicht HUGGINGFACE_TOKEN durch wenn gesetzt" do
    System.put_env("HUGGINGFACE_TOKEN", "hf_test_123")
    extra = Sidecar.diarization_spec().extra_env
    assert {"HUGGINGFACE_TOKEN", "hf_test_123"} in extra
  after
    System.delete_env("HUGGINGFACE_TOKEN")
  end

  test "diarization-spec ohne HUGGINGFACE_TOKEN trägt keinen Token-Eintrag" do
    System.delete_env("HUGGINGFACE_TOKEN")
    extra = Sidecar.diarization_spec().extra_env
    refute Enum.any?(extra, fn {k, _} -> k == "HUGGINGFACE_TOKEN" end)
  end
end
