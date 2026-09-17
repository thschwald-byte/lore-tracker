defmodule Worker.Telemetry.Absturz do
  @moduledoc """
  Issue #542, Signal 1: abgestürzte Tasks zählen.

  `Task.Supervisor` sendet **kein** Telemetrie-Ereignis, wenn ein Kind
  stirbt — es gibt also nichts, woran man sich hängen könnte. Was es gibt,
  ist der Absturzbericht, den OTP ohnehin schreibt. Dieses Modul ist ein
  `:logger`-Handler, der solche Berichte erkennt und
  `Worker.Telemetry.zaehle/2` ruft.

  **Erkannt wird an der ART des Berichts, nicht an einer Liste bekannter
  Absender** (s. `@absturz_arten`). Der Grund steht dort: die zuerst
  angenommene Form war falsch, und weil der Test dieselbe Annahme prüfte,
  fiel es erst an einem echten Absturz auf der Teststage auf.

  Die Berichte wurden bisher geschrieben und gelesen hat sie niemand — das
  ist die Lücke aus #542: *„der `Task.Supervisor` (#233) loggt sie schon →
  zählen/alerten"*.

  ## Warum das hier vorsichtig sein muss

  Ein `:logger`-Handler läuft bei **jeder** Logzeile des Systems, im
  aufrufenden Prozess. Daraus folgt beides:

  - **Er muss billig sein.** Die erste Klausel entscheidet anhand der
    Berichtsform; alles andere fällt sofort durch die Catch-all-Klausel.
  - **Er darf nicht scheitern.** Wirft ein Handler, entfernt der Logger ihn
    dauerhaft — und zwar still. Ein kaputter Zähler würde so die Zählung
    abschalten, und niemand erführe davon. Deshalb liegt der ganze Rumpf in
    einem `try`, und `zaehle/2` ist ein `cast`, der auch ohne laufenden
    Reporter nicht scheitert.

  ## Ehrliche Grenzen

  - Gezählt wird, was OTP **als Bericht formuliert**. Ein Prozess, der ohne
    Crash-Report endet (`:normal`, `:shutdown`, ein `Task.start/1` ausserhalb
    des Supervisors), erscheint nicht — richtig so, das sind keine Abstürze.
  - Der Handler unterscheidet **nicht**, welcher Supervisor betroffen ist.
    Ein Absturz in einer fremden Anwendung desselben Knotens zählt mit. Für
    den Worker-Daemon ist das unerheblich (er ist die einzige Anwendung), in
    Tests dagegen sichtbar — deshalb hängt er sich nur im laufenden Betrieb
    an, nicht in der Testumgebung.
  """

  @handler_id :worker_telemetry_absturz

  @doc """
  Hängt den Handler an den Logger. Idempotent: ein zweiter Aufruf
  (Neustart des Reporters unter seinem Supervisor) ist folgenlos.

  In der Testumgebung passiert nichts — dort erzeugen absichtlich
  abstürzende Prozesse Berichte, die keine echten Vorfälle sind.
  """
  @spec anhaengen() :: :ok
  def anhaengen do
    if Application.get_env(:worker, :env) == :test do
      :ok
    else
      case :logger.add_handler(@handler_id, __MODULE__, %{level: :error}) do
        :ok -> :ok
        {:error, {:already_exist, _}} -> :ok
        {:error, _andere} -> :ok
      end
    end
  end

  @doc "Entfernt den Handler wieder (Tests, geordneter Rückbau)."
  @spec entfernen() :: :ok
  def entfernen do
    :logger.remove_handler(@handler_id)
    :ok
  end

  @doc """
  Logger-Rückruf. Erkennt die zwei OTP-Berichtsformen eines gestorbenen
  Prozesses und zählt sie; alles andere passiert unberührt.
  """
  def log(ereignis, _config) do
    case absturz_quelle(ereignis) do
      nil -> :ok
      quelle -> Worker.Telemetry.zaehle(:task_crash, quelle: quelle)
    end
  catch
    # Siehe Moduldoc: ein werfender Handler wird still abgehängt. Lieber
    # einen Vorfall nicht zählen als die Zählung ganz verlieren.
    _, _ -> :ok
  end

  # Die Arten von Bericht, die einen gestorbenen Prozess melden. **Erkannt
  # wird an der Art, nicht an einer Liste bekannter Absender** — welches
  # Etikett OTP und Elixir im Einzelfall vergeben, ist nicht vollständig
  # erratbar, und eine Liste, die einen Fall vergisst, zählt ihn stumm nicht
  # mit.
  #
  # Am laufenden Worker gemessen (Teststage, 17.09.): ein unter
  # `Task.Supervisor` abgestürzter Task meldet sich als
  # `{Task.Supervisor, :terminating}` — NICHT als `{:proc_lib, :crash}`, wie
  # der erste Entwurf annahm. Dessen Tests waren grün, weil sie dieselbe
  # falsche Form prüften, die der Code erwartete; aufgefallen ist es erst
  # an einem echten Absturz auf der Teststage. Mit dieser Regel sind auch
  # `{:gen_server, :terminate}`, `{:gen_statem, :terminate}` und
  # `{:proc_lib, :crash}` abgedeckt, ohne sie einzeln erraten zu müssen.
  @absturz_arten [:terminating, :terminate, :crash, :child_terminated]

  @doc false
  @spec absturz_quelle(map()) :: String.t() | nil
  def absturz_quelle(%{msg: {:report, %{label: {absender, art}} = report}})
      when art in @absturz_arten do
    kurz(absender, report)
  end

  def absturz_quelle(_andere), do: nil

  # Für die Zeile reicht ein kurzer Bezeichner: was genau passiert ist,
  # steht ohnehin vollständig im Bericht daneben — diese Zählung sagt DASS,
  # nicht WAS. Bei einem Supervisor ist sein Name die nützlichere Auskunft
  # als das Wort „supervisor".
  defp kurz(:supervisor, %{report: report}) when is_list(report) do
    case Keyword.get(report, :supervisor) do
      {:local, name} -> to_string(name)
      _ -> "supervisor"
    end
  end

  defp kurz(absender, _report) when is_atom(absender), do: inspect(absender)
  defp kurz(_absender, _report), do: "unbekannt"
end
