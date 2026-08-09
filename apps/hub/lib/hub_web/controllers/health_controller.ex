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
end
