defmodule HubWeb.ConnCase do
  @moduledoc """
  Test-Case für Hub-Tests, die einen `conn` / LiveView-Mount brauchen
  (Issue #66). Bisher hatte der Hub gar kein `test/support/` und 0
  LiveView-Mount-Tests.

  Stellt bereit:
    - `Phoenix.ConnTest` + `Phoenix.LiveViewTest` Imports + `@endpoint`
    - `conn` im Setup
    - `log_in/2` — schreibt einen `HubWeb.Fixtures.user/1` als Session-`current_user`
      (Pendant zu `Hub.Auth.put_user/2`), sodass der `:require_user`-Plug durchlässt
    - `stub_reader!/1` — ersetzt den supervisten `Hub.Reader` für die Dauer des
      Tests durch einen Stub, der ein fixes Snapshot zurückgibt (LV-Mount ohne Worker)
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import Plug.Conn
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest
      import HubWeb.ConnCase

      alias HubWeb.Fixtures

      @endpoint HubWeb.Endpoint
    end
  end

  setup _tags do
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc """
  Loggt einen User in die Session ein (Session-Key `:current_user`, analog
  `Hub.Auth.put_user/2`). `user` ist eine `HubWeb.Fixtures.user/1`-Map.
  """
  def log_in(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:current_user, user)
  end

  @doc """
  Ersetzt den supervisten `Hub.Reader` durch `HubWeb.ReaderStub`, der auf jeden
  `read`-Call `{:ok, snapshot}` zurückgibt. Nach dem Test wird der echte Reader
  vom Supervisor wieder gestartet. Macht den Test zwangsläufig `async: false`.
  """
  def stub_reader!(snapshot) do
    :ok = Supervisor.terminate_child(Hub.Supervisor, Hub.Reader)
    {:ok, pid} = HubWeb.ReaderStub.start_link({:ok, snapshot})

    ExUnit.Callbacks.on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
      Supervisor.restart_child(Hub.Supervisor, Hub.Reader)
    end)

    pid
  end
end
