defmodule Worker.Recording.TranscribeClipTest do
  @moduledoc """
  Issue #400: deterministische Fehlerpfade von `Transcribe.transcribe_clip/1`.

  Der Happy-Path (echtes WebM → ffmpeg → whisper-cli → Text) hängt an externen
  Binaries und wird manuell im PR-Test verifiziert; hier deckt die Suite die
  Eingabe-Defensive ab, die ohne ffmpeg/whisper deterministisch ist.
  """

  use ExUnit.Case, async: true

  alias Worker.Recording.Transcribe

  test "leeres Binary → {:error, :invalid_clip}" do
    assert {:error, :invalid_clip} = Transcribe.transcribe_clip("")
  end

  test "nicht-binäre Eingabe → {:error, :invalid_clip}" do
    assert {:error, :invalid_clip} = Transcribe.transcribe_clip(nil)
    assert {:error, :invalid_clip} = Transcribe.transcribe_clip(123)
  end

  test "räumt Temp-Dateien auch bei Konvertierungs-Fehler auf" do
    before = tmp_clip_files()
    # Kein gültiges WebM → ffmpeg scheitert → {:error, ...}. Wichtig ist nur,
    # dass keine lore_clip_*-Leichen im tmp-Dir zurückbleiben.
    _ = Transcribe.transcribe_clip(<<0, 1, 2, 3, 4, 5, 6, 7, 8, 9>>)
    assert tmp_clip_files() == before
  end

  defp tmp_clip_files do
    System.tmp_dir!()
    |> Path.join("lore_clip_*")
    |> Path.wildcard()
    |> Enum.sort()
  end
end
