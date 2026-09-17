defmodule Worker.TelemetryAbsturzTest do
  @moduledoc """
  Issue #542, Signal 1: erkennt der Logger-Handler einen Absturzbericht?

  Geprüft wird die reine Erkennung (`absturz_quelle/1`) an den Formen, die
  OTP tatsächlich schickt — und vor allem, dass **alles andere** unberührt
  durchläuft. Ein Handler, der bei einer gewöhnlichen Logzeile etwas tut
  oder gar wirft, würde vom Logger still abgehängt; die Zählung wäre dann
  aus, ohne dass es jemandem auffällt.
  """
  use ExUnit.Case, async: true

  alias Worker.Telemetry.Absturz

  describe "Absturzberichte erkennen" do
    # Die Form stammt aus einer MESSUNG am laufenden Worker (Teststage,
    # 17.09.), nicht aus einer Annahme: ein abgestürzter Task meldet sich
    # als `{Task.Supervisor, :terminating}`. Der erste Entwurf erwartete
    # `{:proc_lib, :crash}` — und seine Tests waren grün, weil sie dieselbe
    # falsche Form prüften. Genau deshalb steht hier die echte.
    test "ein abgestürzter Task unter Task.Supervisor wird erkannt" do
      ereignis = %{
        msg: {:report, %{label: {Task.Supervisor, :terminating}, report: [[], []]}}
      }

      assert Absturz.absturz_quelle(ereignis) == "Task.Supervisor"
    end

    test "ein proc_lib-Crash-Report ebenfalls" do
      ereignis = %{msg: {:report, %{label: {:proc_lib, :crash}, report: [[], []]}}}
      assert Absturz.absturz_quelle(ereignis) == ":proc_lib"
    end

    test "ein GenServer-Abbruch ebenfalls" do
      # Nicht gemessen, aber von derselben Regel erfasst — das ist der Sinn
      # der Regel: sie deckt Formen ab, die niemand einzeln erraten hat.
      ereignis = %{msg: {:report, %{label: {:gen_server, :terminate}, report: []}}}
      assert Absturz.absturz_quelle(ereignis) == ":gen_server"
    end

    test "ein beendetes Supervisor-Kind nennt seinen Supervisor" do
      ereignis = %{
        msg:
          {:report,
           %{
             label: {:supervisor, :child_terminated},
             report: [supervisor: {:local, Worker.TaskSupervisor}, reason: :boom]
           }}
      }

      assert Absturz.absturz_quelle(ereignis) == "Elixir.Worker.TaskSupervisor"
    end

    test "ein Supervisor-Bericht ohne lesbaren Namen fällt auf einen Platzhalter" do
      ereignis = %{
        msg: {:report, %{label: {:supervisor, :child_terminated}, report: [reason: :boom]}}
      }

      assert Absturz.absturz_quelle(ereignis) == "supervisor"
    end
  end

  describe "alles andere passiert unberührt" do
    test "eine gewöhnliche Logzeile ist kein Absturz" do
      assert Absturz.absturz_quelle(%{msg: {:string, "irgendeine Meldung"}}) == nil
    end

    test "ein Fortschritts-Bericht ist kein Absturz" do
      # Derselbe Absender wie ein echter Vorfall, andere Art — die Regel
      # unterscheidet an der Art, sonst zählte jeder Prozessstart mit.
      ereignis = %{msg: {:report, %{label: {:supervisor, :progress}, report: []}}}
      assert Absturz.absturz_quelle(ereignis) == nil
    end

    test "eine unerwartete Form wirft nicht, sondern ergibt nil" do
      # Der Handler sieht JEDE Logzeile des Systems. Käme dort etwas an,
      # das keine der bekannten Formen hat, darf das keine Ausnahme geben.
      for seltsam <- [%{}, %{msg: nil}, %{msg: {:report, %{}}}, %{msg: {:report, :kein_map}}] do
        assert Absturz.absturz_quelle(seltsam) == nil
      end
    end

    test "log/2 schluckt auch das, was absturz_quelle/1 nicht verdaut" do
      # Wirft ein Handler, entfernt der Logger ihn dauerhaft und still —
      # die Zählung wäre aus, ohne Hinweis. Deshalb fängt log/2 alles.
      assert Absturz.log(%{msg: {:report, %{label: {:proc_lib, :crash}}}}, %{}) == :ok
      assert Absturz.log(:voelliger_unsinn, %{}) == :ok
      assert Absturz.log(nil, %{}) == :ok
    end
  end

  describe "anhaengen/0" do
    test "hängt sich in der Testumgebung nicht ein" do
      # In Tests stürzen Prozesse absichtlich ab; diese Berichte sind keine
      # echten Vorfälle und würden die Zählung fremder Tests verfälschen.
      assert Absturz.anhaengen() == :ok
      refute :worker_telemetry_absturz in :logger.get_handler_ids()
    end
  end
end
