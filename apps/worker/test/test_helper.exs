# :jack_prod — Jacks Werkzeuge gegen einen Abzug einer echten Prod-Sitzung
# (`mix lore.jack.abzug`); der liegt außerhalb des Repos und läuft nur mit
# `--only jack_prod`, nie im Standardlauf und nie in der CI.
ExUnit.start(exclude: [:stt_bench, :jack_prod])

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
