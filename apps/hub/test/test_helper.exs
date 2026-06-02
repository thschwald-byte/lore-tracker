ExUnit.start(exclude: [:integration])

# Etappe 5c (Issue #164): Hub ist vollständig stateless. Kein Mnesia-Bootstrap,
# kein Postgres-Sandbox — Tests laufen rein im RAM (PubSub, WorkerJWT, Reader-
# Round-Trip).

# Issue #66: Das Icon-Wrapper-Component (HubWeb.UIComponents.tabler/1) macht
# `String.to_existing_atom("microphone")` o.ä., um den Icon-Namen auf eine
# TablerIcons-Funktion zu mappen. In :prod/:dev ist TablerIcons beim ersten
# Render längst geladen (alle Icon-Atoms interniert); im Test wird das Modul
# lazy geladen → das Atom existiert beim ersten LiveView-Render evtl. noch
# nicht und `to_existing_atom` crasht. Einmal vorab laden interniert alle
# Icon-Atoms für die ganze Suite.
Code.ensure_loaded!(TablerIcons)
