ExUnit.start()

# Settings + AudioBuffer + Materializer tests poke Mnesia (worker_state writes
# via Settings.put, session-state reads via Worker.Settings.get). Bootstrap
# Mnesia + worker tables once so tests can run isolated from a paired
# Worker.Application boot. Phoenix.PubSub is also session-wide; the
# Materializer broadcasts on Worker.PubSub after each apply.
:ok = Shared.Mnesia.ensure_started!()
:ok = Worker.Schema.Mnesia.bootstrap!()

case Phoenix.PubSub.Supervisor.start_link(name: Worker.PubSub) do
  {:ok, _pid} -> :ok
  {:error, {:already_started, _pid}} -> :ok
end
