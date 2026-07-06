defmodule Worker.Recording.TranscribeFfmpegRobustnessTest do
  @moduledoc """
  Issue #704: dynamischer ffmpeg-Timeout, harter Orphan-Kill in run_cmd, und
  Sichtbarkeit + Preserve bei Track-Ausfall (statt Silent-Failure).
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Worker.TestHelper

  alias Worker.Recording.{Cmd, Transcribe}
  alias Worker.Schema.Builder

  describe "ffmpeg_timeout_for/3 (pur)" do
    test "kleine/leere Datei → Floor" do
      assert Transcribe.ffmpeg_timeout_for(0, 900_000, 5_000) == 900_000
      assert Transcribe.ffmpeg_timeout_for(1_000, 900_000, 5_000) == 900_000
    end

    test "106-MB-Track (Free Seattle) übersteigt den alten 120s-Floor deutlich" do
      t = Transcribe.ffmpeg_timeout_for(106 * 1_048_576, 120_000, 5_000)
      assert t == 530_000
      assert t > 120_000
    end

    test "sehr großer Track: per-MB-Term dominiert den 900s-Floor" do
      t = Transcribe.ffmpeg_timeout_for(300 * 1_048_576, 900_000, 5_000)
      assert t == 1_500_000
      assert t > 900_000
    end
  end

  describe "run_cmd (Port-basiert, Orphan-Kill)" do
    test "Happy-Path: exit 0 → {:ok, _}, exit≠0 → {:error, {:exit, ...}}" do
      assert {:ok, _} = Cmd.run("true", [], 5_000)
      assert {:error, {:exit, code, _out}} = Cmd.run("false", [], 5_000)
      assert code != 0
    end

    test "Timeout killt den OS-Prozess wirklich (kein Orphan)" do
      # Unübliche Dauer als eindeutiger pgrep-Marker.
      marker = "774411"
      task = Task.async(fn -> Cmd.run("sleep", [marker], 200) end)

      assert {:error, {:timeout, 200}} = Task.await(task, 5_000)

      # Der sleep-Prozess muss weg sein (SIGKILL ist async → kurz pollen).
      gone? =
        Enum.reduce_while(1..20, false, fn _, _ ->
          {out, _} = System.cmd("pgrep", ["-f", "sleep #{marker}"], stderr_to_stdout: true)

          if String.trim(out) == "" do
            {:halt, true}
          else
            Process.sleep(50)
            {:cont, false}
          end
        end)

      assert gone?, "ffmpeg/sleep-Orphan lebt nach Timeout weiter — Kill hat nicht gegriffen"
    end
  end

  describe "transcribe_one-Fehler ist nicht mehr still (Issue #704)" do
    setup do
      clear_all_tables!()
      mat = ensure_materializer!()

      # publish_status/publish senden an Worker.HubClient — im Test nicht
      # gestartet. Minimaler GenServer-Stub, der publish_status (send) schluckt
      # und publish_intent (GenServer.call) sofort beantwortet (sonst 5s-Timeout).
      {:ok, stub} = start_supervised({__MODULE__.HubClientStub, []})

      failed_dir =
        Path.join(System.tmp_dir!(), "lore_failed_test_#{System.unique_integer([:positive])}")

      Worker.Settings.put(:audio_failed_dir, failed_dir)

      on_exit(fn ->
        if mat && Process.alive?(mat), do: Process.exit(mat, :kill)
        File.rm_rf(failed_dir)
      end)

      %{failed_dir: failed_dir, stub: stub}
    end

    test "ffmpeg-Fehlschlag → pipeline_status failed + Preserve-Kopie", %{failed_dir: failed_dir} do
      cid = "camp-704"
      sid = "sess-704"
      did = "111222333"

      Builder.write!(Builder.campaign(cid, name: "704-Test"))
      Builder.write!(Builder.campaign_member(cid, did, character_name: "Liv"))
      Builder.write!(Builder.session(sid, cid, number: 1))

      # >256-Byte-Junk-webm → passt am size<256-Skip vorbei, ffmpeg lehnt es ab.
      dir = Path.join(System.tmp_dir!(), "lore_in_704_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      webm = Path.join(dir, "#{did}.webm")
      File.write!(webm, :crypto.strong_rand_bytes(1024))
      on_exit(fn -> File.rm_rf(dir) end)

      :ok = Phoenix.PubSub.subscribe(Worker.PubSub, "pipeline_status")

      capture_log(fn ->
        assert :ok = Transcribe.run(sid, [{did, webm}])
      end)

      # Der Track-Ausfall wird laut gemeldet (Sprecher-Name aus dem Member).
      assert_receive {:pipeline_stage,
                      %{"stage" => "stage1", "status" => "failed", "error" => msg}},
                     5_000

      assert msg =~ "nicht transkribiert"
      assert msg =~ "Liv"

      # Die gescheiterte webm ist unter audio_failed_dir/<sid>/ bewahrt.
      preserved = Path.join([failed_dir, sid, "#{did}.webm"])
      assert File.exists?(preserved)
    end
  end

  defmodule HubClientStub do
    @moduledoc false
    use GenServer
    def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: Worker.HubClient)
    @impl true
    def init(_), do: {:ok, nil}
    @impl true
    def handle_call({:publish_intent, _id, _payload}, _from, s), do: {:reply, {:ok, 1}, s}
    def handle_call(_msg, _from, s), do: {:reply, :ok, s}
    @impl true
    def handle_info(_msg, s), do: {:noreply, s}
  end
end
