defmodule Worker.SidecarSpecTest do
  @moduledoc """
  Issue #296: `Worker.Sidecar` ist spec-getrieben (zwei Instanzen). Diese Tests
  decken die reinen Spec-Builder ab — distinkte Namen/Ports/Settings + die
  Diarisierungs-spezifischen Subprozess-Env-Vars.
  """

  use ExUnit.Case, async: false

  alias Worker.Sidecar

  test "faithfulness- und diarization-spec haben distinkte Namen/Ports/Settings" do
    f = Sidecar.faithfulness_spec()
    d = Sidecar.diarization_spec()

    assert f.name == :faithfulness_sidecar
    assert d.name == :diarization_sidecar
    assert f.default_port == 8765
    assert d.default_port == 8766
    assert f.setting_key == :faithfulness_sidecar_url
    assert d.setting_key == :diarization_sidecar_url
    assert f.script == "faithfulness_sidecar.py"
    assert d.script == "diarization_sidecar.py"
    assert f.disable_env != d.disable_env
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

  test "faithfulness-spec hat keine extra-env (unverändertes Verhalten)" do
    assert Sidecar.faithfulness_spec().extra_env == []
  end
end
