defmodule HubWeb.HealthController do
  @moduledoc """
  Issue #703: unauthentifizierter, prod-live Status-Endpoint für den
  Woodpecker-Deploy-Step. CI kann sich nicht als Hub-User einloggen, daher
  außerhalb der `:require_user`-Pipeline. Liefert bewusst nur ein Boolean —
  keine Session-/Campaign-Details an einen öffentlich erreichbaren Endpoint.
  """

  use HubWeb, :controller

  def recording(conn, _params) do
    json(conn, %{active_recording: Hub.WorkerRegistry.any_active_recording?()})
  end

  @doc """
  Issue #1224: welcher Stand gerade läuft — die Commit-SHA des Releases.

  **Wozu:** Es gab keinen Weg, von außen zu sehen, ob Prod dem master
  hinterherhinkt. `deploy_verify` prüft das gründlich, aber nur *innerhalb*
  eines Laufs, der bis dorthin kommt; ein gekillter master-Lauf (real: 1089 am
  17.09., 1113 am 19.09.) führt es nie aus, und der Commit bleibt undeployt,
  ohne dass irgendetwas meldet. Der `freetier`-Cron kann den Abgleich machen —
  er braucht dafür aber eine Quelle **ohne Secrets**, denn die drei
  `gigalixir_*`-Secrets sind push-scoped und in einem Cron-Lauf unsichtbar.

  **Warum das öffentlich vertretbar ist:** Die SHA benennt einen Commit eines
  öffentlichen AGPL-Repositories — sie verrät nichts, was nicht ohnehin in der
  Repo-Historie steht. Sonst nichts: keine Umgebung, keine Pfade, keine
  Zählwerte. Dieselbe Zurückhaltung wie bei `recording/2`, das bewusst nur ein
  Boolean liefert.

  `dirty?` reist mit, weil der Gigalixir-Build-Baum beim Compile grundsätzlich
  dreckig ist (jedes Prod-Release meldet `+dev`); ohne das Feld hielte ein
  Leser die SHA für unvollständig.
  """
  def version(conn, _params) do
    %{vsn: vsn, sha: sha, dirty?: dirty?} = Hub.Version.current()
    json(conn, %{vsn: vsn, sha: sha, dirty: dirty?})
  end
end
