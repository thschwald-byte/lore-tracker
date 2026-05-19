defmodule Hub.Repo do
  @moduledoc """
  Ecto repository for the Hub when `:storage_backend` is `:postgres`.

  Started as a supervisor child only in that mode (see `Hub.Application`).
  In `:mnesia` mode the process is never started and this module is dormant.
  """

  use Ecto.Repo,
    otp_app: :hub,
    adapter: Ecto.Adapters.Postgres
end
