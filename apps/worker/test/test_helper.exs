ExUnit.start()

# Settings + AudioBuffer tests poke Mnesia (worker_state writes via Settings.put,
# session-state reads via Worker.Settings.get). Bootstrap Mnesia + worker tables
# once so tests can run isolated from a paired Worker.Application boot.
:ok = Shared.Mnesia.ensure_started!()
:ok = Worker.Schema.Mnesia.bootstrap!()
