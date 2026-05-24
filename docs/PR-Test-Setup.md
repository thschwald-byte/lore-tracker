# PR-Test-Setup

Wie eine PR-Test-Stage aussieht, wie sie hochgefahren wird, wie man sie wieder aufräumt.

> **Zielgruppe:** Entwickler:innen (inkl. Claude-Code-Instanzen) die `mix lore.pr_test.spawn` bzw. `mix lore.pr_test` benutzen.
> **Code-Quellen:** `apps/hub/lib/mix/tasks/lore.pr_test.ex`, `lore.pr_test.spawn.ex`, `lore.pr_test_down.ex`, `lore.pr_test/runner.ex`, `lore.pr_test/ports.ex`.

## Anatomie einer Stage

Eine PR-Test-Stage ist ein **isolierter Mini-Stack** parallel zum master-dev-Setup. Sechs Komponenten gehören dazu:

```
┌─────────────────────────────────────────────────────────────┐
│ PR-TEST-STAGE (Port 4005, Branch issue-186-foo)             │
│                                                             │
│  ① Git-Worktree            ../lore-pr-4005/                 │
│     ├── detached HEAD am Feature-Branch-Commit              │
│     ├── apps/, _build/, deps/, mix.lock (Repo-Inhalt)       │
│     └── .env (Symlink → main-clone-.env)                    │
│                                                             │
│  ② Runtime-Verzeichnis     /tmp/pr-4005/                    │
│     ├── hub.pid                Hub-BEAM PID                 │
│     ├── hub.log                Hub stdout/stderr            │
│     ├── hub-mnesia/            (heute leer — Hub seit #164  │
│     │                          DB-frei, dir wird trotzdem   │
│     │                          angelegt)                    │
│     ├── worker-0.pid           Worker-BEAM PID              │
│     ├── worker-0.log           Worker stdout/stderr         │
│     └── worker-0-mnesia/       Worker-Mnesia (state +       │
│                                events + materialized data)  │
│                                                             │
│  ③ Hub-BEAM                hub_pr4005@<short-hostname>      │
│     ├── PPID=1 (init, via setsid --fork detached)           │
│     ├── Listening on 127.0.0.1:4005                         │
│     ├── ENV: LORE_JWT_SECRET, LORE_MNESIA_DIR, PORT         │
│     └── mix phx.server                                      │
│                                                             │
│  ④ Worker-BEAM             worker_pr4005_0@<short-hostname> │
│     ├── PPID=1 (init, via setsid --fork detached)           │
│     ├── ENV: LORE_MNESIA_DIR, HUB_BASE_URL=…:4005,          │
│     │      LORE_WORKER_SETUP_PORT=4090+idx                  │
│     ├── Pre-seedet mit JWT-Token im worker_state            │
│     │   (kein Discord-Pair-Klick nötig)                     │
│     └── Joined als Channel-Client gegen Hub                 │
│                                                             │
│  ⑤ Discord-OAuth-Slot      Redirect-URI :4005/auth/…       │
│     einmalig in Discord-Developer-Console eingetragen,      │
│     eine Stage pro Port → Port-Slot-Mapping (siehe unten)   │
│                                                             │
│  ⑥ CLAUDE.local.md-Eintrag                                  │
│     "Currently running PR-test instances"-Sektion bekommt   │
│     `- Port 4005: branch issue-186-foo, admins=1`           │
└─────────────────────────────────────────────────────────────┘
```

## Port-Slot-System (Issue #186)

Statt globalem Port-Pool für alle Claude-Code-Instanzen hat **jeder Worktree-cwd einen festen 2-Port-Slot**, hinterlegt in `CLAUDE.local.md`. `Mix.Tasks.Lore.PrTest.Ports.allocate!/0` matched den aktuellen `git rev-parse --show-toplevel` gegen die Slot-Tabelle und allokiert nur aus dem eigenen Slot.

Beispiel (`CLAUDE.local.md`):

```markdown
## PR-Test-Port-Slots pro Worktree

- /home/tom/Projekte/lore_tracker → 4001, 4002
- /home/tom/Projekte/lore_tracker2 → 4003, 4004
- /home/tom/Projekte/lore_tracker_issues → 4005, 4006
```

Reserve / ad-hoc: 4007 (manuell via `mix lore.pr_test --port 4007 <branch>` falls je nötig).

**Discord-OAuth-Constraint:** in der Discord-Developer-Console müssen Redirect-URIs für **alle** verwendeten Ports (4000-4007) einmalig eingetragen sein. 4000 ist master-dev-hub.

## Spawn-Flow

```
mix lore.pr_test.spawn
  │
  ├─ Mix.Tasks.Lore.PrTest.Spawn.run/1
  │   ├─ git rev-parse --abbrev-ref HEAD  → "issue-186-foo"
  │   ├─ Refuse wenn == "master" (Sicherheits-Gate)
  │   ├─ Pre-Cleanup: stale Stacks auf eigenen Slot-Ports abräumen
  │   │              (`lore.pr_test_down <port>` für jeden Slot-Port
  │   │              der ein `/tmp/pr-<port>/hub.pid` hat)
  │   └─ Mix.Task.run("lore.pr_test", [branch, "--seed"])
  │
  ▼
Mix.Tasks.Lore.PrTest.run/1
  ├─ load_dotenv()                        # liest .env, setzt OS-env
  ├─ parse args → branch, admins, seed?=true
  └─ port = Ports.allocate!()             # cwd-Slot-Lookup
                                             │
                                             ▼
Ports.allocate!()
  ├─ cwd = git rev-parse --show-toplevel
  ├─ slot_ports = read CLAUDE.local.md, find "- <cwd> → <p1>, <p2>"
  ├─ für jeden Slot-Port:
  │   ├─ schon in "Currently running PR-test"-Sektion?
  │   └─ :gen_tcp.connect probe — :econnrefused = frei
  └─ return erster freier Port (z.B. 4005)
                                             │
  ▼ Runner.run(%{branch, port, admins, seed?})
  │
  ├─ ① ensure_worktree!(branch, "../lore-pr-4005")
  │     git worktree add --detach ../lore-pr-4005 <branch>
  │     (detached HEAD: kein Branch-Konflikt mit current cwd)
  │
  ├─ ② symlink_env!("../lore-pr-4005")
  │     ln -s <repo>/.env ../lore-pr-4005/.env
  │
  ├─ ③ ensure_deps!("../lore-pr-4005")
  │     System.cmd("mix", ["deps.get"], cd: worktree)
  │
  ├─ ④ jwt_secret = generate fresh 32-Byte secret
  │     start_hub!(worktree, runtime_dir, port=4005, jwt_secret, hub_node)
  │      └─ spawn_detached!("elixir --sname hub_pr4005 -S mix phx.server",
  │                         cd=worktree/apps/hub,
  │                         env={LORE_MNESIA_DIR, LORE_JWT_SECRET, PORT},
  │                         log=/tmp/pr-4005/hub.log,
  │                         pid_file=/tmp/pr-4005/hub.pid)
  │           └─ bash -c "cd <cwd> && setsid --fork bash -c '
  │                          echo $$ > hub.pid; exec env <vars> elixir … '"
  │              ▲
  │              └─ setsid --fork: parent exitet sofort, Hub-BEAM
  │                 wird new session leader + bekommt PPID=1.
  │                 OHNE --fork hängt der bash-c in non-interactive
  │                 System.cmd in do_wait auf den Background-Job
  │                 (Job-Control ist off, disown wirkt nicht).
  │
  ├─ ⑤ wait_for_hub_ready!(4005)
  │     poll :gen_tcp.connect 127.0.0.1:4005 alle 500ms, max 180s
  │     dann +500ms PubSub/Tracker-Bootstrap
  │
  ├─ ⑥ pro Admin in admins:
  │     ⑥a sign_jwt!(jwt_secret, worker_id=UUIDv7, admin_did)
  │         Hub.WorkerJWT.sign_token aus dem Mix-Task-BEAM,
  │         temporär jwt_secret in App-env
  │
  │     ⑥b preseed_worker_mnesia!(worktree, runtime_dir, port, descr, jwt)
  │         File.mkdir_p /tmp/pr-4005/worker-0-mnesia
  │         System.cmd("elixir",
  │           ["--sname", "worker_pr4005_0",      ← MUSS = späterer
  │            "-S", "mix", "run", "--no-start",    Worker-sname sein!
  │            "-e", <CODE>],                       Mnesia-Schema ist
  │           cd=worktree/apps/worker,              sname-gebunden.
  │           env={LORE_MNESIA_DIR})
  │
  │         <CODE> bootet Mnesia, schreibt worker_state mit:
  │           hub_token=<JWT>, worker_id, admin_discord_id,
  │           hub_base_url="http://localhost:4005", last_applied_seq=0
  │         + upsert_user(admin, "PR-Test User")
  │         + :mnesia.sync_log + :mnesia.stop (sonst RAM-only verloren!)
  │
  │     ⑥c start_worker!(worktree, runtime_dir, port, descriptor, host)
  │         spawn_detached!("elixir --sname worker_pr4005_0 -S mix run",
  │                         cd=worktree/apps/worker,
  │                         env={LORE_MNESIA_DIR, HUB_BASE_URL, …},
  │                         log=/tmp/pr-4005/worker-0.log,
  │                         pid_file=/tmp/pr-4005/worker-0.pid)
  │           └─ setsid --fork wie beim Hub
  │
  │         Worker bootet, liest worker_state.hub_token, connectet
  │         als Channel-Client gegen Hub auf :4005,
  │         Hub.WorkerJWT.verify akzeptiert (gleiches Secret im App-env)
  │
  ├─ ⑦ wait_for_worker_connected!(port, hostname)
  │     Node.start :pr_setup_4005@host + setcookie
  │     :rpc.call hub_node Hub.WorkerRegistry.list alle 2s, max 60s
  │     warten bis list != []
  │
  ├─ ⑧ wenn seed?:
  │     seed_romeo!(worktree, port, first_admin)
  │       System.cmd("mix",
  │         ["lore.seed.romeo",
  │          "--hub", "http://localhost:4005",
  │          "--as-admin", admin],
  │         cd=worktree)
  │       → applied 1500+ events via POST /dev/event → EventBridge
  │         → online Worker materialisiert
  │
  ├─ ⑨ update_claude_local_md!(port, branch, admins)
  │     Sektion "Currently running PR-test instances":
  │     `- Port 4005: branch issue-186-foo, admins=1` einfügen
  │
  ├─ ⑩ open_browser!(port)
  │     xdg-open http://localhost:4005/
  │
  └─ ⑪ print_summary(port, branch, descriptors, runtime_dir)
        Hub: http://localhost:4005
        Worker: sname worker_pr4005_0
        Logs:   tail -f /tmp/pr-4005/hub.log /tmp/pr-4005/worker-0.log
        Tear-down: mix lore.pr_test_down 4005
```

## Tear-Down

```
mix lore.pr_test_down 4005
  ├─ kill via PID-Files     (kill $(cat /tmp/pr-4005/hub.pid),
  │                          kill $(cat /tmp/pr-4005/worker-0.pid))
  ├─ git worktree remove --force ../lore-pr-4005
  ├─ rm -rf /tmp/pr-4005/
  └─ CLAUDE.local.md aufräumen — Entry für Port aus "Currently
     running"-Sektion löschen
```

Robust gegen fehlende PID-Files / fremde Pfade — kein Fehler wenn Hub bereits tot, kein Crash wenn Worktree nicht mehr existiert.

## Detach-Gotchas (Issue #190)

Zwei Stolperfallen die beim Spawn-Aufruf aus einer non-interactive Shell auftreten:

### 1. Git-Worktree-Konflikt

`git worktree add <path> <branch>` schlägt fehl wenn der **aktuelle** Worktree bereits auf demselben Branch ausgecheckt ist. Lösung: `--detach`-Flag → der PR-Test-Worktree zeigt nur auf den Branch-Commit, ohne Branch-Ownership.

**Konsequenz**: im PR-Test-Worktree ist HEAD detached. Commits dort gehen nicht zurück zum Branch (orphan). Read-only-Schau ist der gewollte Use-Case — Code ändern im Arbeits-Worktree, `git push`, im PR-Test-Worktree reload des Hubs.

### 2. bash hängt im `do_wait`

`System.cmd("bash", ["-c", "... &"])` aus einem Mix-Task läuft in einer non-interactive Shell. Dort ist Job-Control off — `&` macht den Hub-BEAM zwar Background, aber bash wartet trotzdem via `do_wait` darauf (selbst mit `disown` oder simplem `setsid`).

Lösung: `setsid --fork bash -c 'echo $$ > pid; exec …'`
- `setsid --fork` forks und der Parent-Setsid-Prozess exitet sofort.
- Child wird new session leader + bekommt PPID=1 (re-parented zu init).
- Inner-bash schreibt seine PID per `$$` ins pid-File (vor `exec`).
- `exec` ersetzt bash durch den eigentlichen Befehl (PID bleibt erhalten).
- Damit hat die Outer-Bash KEINE Child-Beziehung mehr → kein do_wait.

## Pre-Cleanup vor jedem Spawn (Issue #190)

`mix lore.pr_test.spawn` räumt vor dem eigentlichen Spawn die eigenen Slot-Ports leer:

```
für jeden Slot-Port:
  wenn /tmp/pr-<port>/hub.pid oder worker-0.pid existiert:
    Mix.Task.rerun("lore.pr_test_down", [<port>])
```

Damit landet jeder Spawn immer auf dem primären Slot-Port (kein „Slot-Port-Hopping weil 4005 noch stale ist"). Idempotent: ohne stale Stack = no-op.

## Anti-Patterns

- ❌ `mix lore.pr_test.spawn` aufrufen während du im **main-clone** auf einem Feature-Branch arbeitest, und der main-clone-Slot ist 4001 — der Pre-Cleanup würde die laufende master-dev-Instanz nicht treffen (sie hat Port 4000), aber wenn ein vorheriger PR-Test auf 4001 hängt, wird der gekillt. Das ist gewollt; eine andere parallele Stage zu schützen geht nur über manuelles `mix lore.pr_test --port 4007 <branch>` (Reserve-Port).
- ❌ Im PR-Test-Worktree committen. Detached HEAD → die Commits werden bei `git worktree remove` orphan, kein Branch nimmt sie auf.
- ❌ Mehrere Spawns gleichzeitig aus derselben cwd. Pre-Cleanup räumt eh die eigenen Ports ab; der zweite Spawn killt den ersten.

## Verwandte Issues

- **#167** — `mix lore.pr_test` (initiale Single-Command-Implementierung)
- **#186** — Per-Worktree-Port-Slots + `mix lore.pr_test.spawn`-Wrapper
- **#190** — Detach-Gotchas (worktree --detach + setsid --fork + Pre-Cleanup)
