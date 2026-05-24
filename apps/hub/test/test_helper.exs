ExUnit.start(exclude: [:integration])

# Etappe 5c (Issue #164): Hub ist vollständig stateless. Kein Mnesia-Bootstrap,
# kein Postgres-Sandbox — Tests laufen rein im RAM (PubSub, WorkerJWT, Reader-
# Round-Trip).
