# Shared

Bibliotheks-App für Code, der von `apps/hub` und `apps/worker` gemeinsam genutzt wird. Kein eigener Supervisor-Tree (`application/0` ohne `mod:`-Eintrag).

## Inhalt

- **`Shared.Events`** — Event-Kind-Konstanten + Type-Helper. Single source of truth für das Wire-Protokoll zwischen Hub und Worker (z.B. `Shared.Events.invite_created()`).
- **`Shared.Mnesia`** — Bootstrap-Helper (`ensure_started!/0`, `ensure_table!/2`) für Mnesia-disc-copies. Wird sowohl vom Hub als auch vom Worker zum Aufsetzen ihrer jeweiligen Tabellen genutzt.

## Versionierung

`shared/mix.exs:version` wird bei Wire-Protocol- oder Schema-Änderungen gebumpt. Ein `shared`-Bump erzwingt `hub`- + `worker`-Mit-Bump (Synchro-Pflicht). Siehe CLAUDE.md → „Versionierungs-Schema".

## Verwendung

In sibling-Apps:

```elixir
defp deps do
  [
    {:shared, in_umbrella: true}
  ]
end
```

## Mehr

Siehe Root-[`README.md`](../../README.md) und [`CLAUDE.md`](../../CLAUDE.md).
