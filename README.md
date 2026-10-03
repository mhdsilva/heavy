# heavy

A machine-wide queue for heavy commands: test suites, type checkers, linters, builds.

```bash
heavy uv run pytest -n 3 tests/
heavy --timeout 600 npx vitest run
heavy --status
```

## Why

Running several coding agents in parallel (Claude Code, Codex, OpenCode, Cursor…) on one laptop is cheap on CPU most of the time, because each agent spends most of its time waiting on the model. The trouble starts when their verification steps land in the same minute. Three sessions each start `pytest -n 6`, `tsc` and a `vite build`, the load average climbs past 30 on 8 cores, the machine starts swapping, and every one of those jobs runs several times slower than it would have alone.

`heavy` keeps the parallel agents and puts their heavy commands in a queue:

- **Slots.** At most `HEAVY_SLOTS` wrapped commands run at once on the machine, across every terminal and agent session. The rest wait for a slot and say so on stderr.
- **Low priority.** Commands run under `nice` (and `ionice` on Linux), so the desktop and the agents themselves stay responsive.
- **A shared CPU/RAM cap** (Linux with systemd). All queued jobs together run inside one cgroup, capped at about 5/8 of the cores and 45% of RAM. A slot count alone can't contain a single job that spawns many threads, and this can.

## Install

```bash
git clone https://github.com/mhdsilva/heavy.git ~/.heavy
~/.heavy/heavy --install
```

`--install` links `~/.local/bin/heavy` to the clone, so `git pull` updates it. On Linux with a systemd user session, it also writes the cgroup slice (`~/.config/systemd/user/heavy.slice`), sized for the machine. Rerun it after changing hardware.

## Usage

```bash
heavy <command> [args...]
heavy --timeout <seconds> <command> [args...]
heavy --status
```

| Variable | Default | Meaning |
|---|---|---|
| `HEAVY_SLOTS` | CPUs / 4, at least 1 | Commands allowed to run at once |
| `HEAVY_WAIT` | `1800` | Max seconds waiting for a slot; then exit 75 |
| `HEAVY_LOCK` | `$XDG_RUNTIME_DIR/heavy.lock` or `/tmp/heavy-<uid>.lock` | Lock file base path |

Behavior worth knowing:

- **Put the timeout inside.** Use `heavy --timeout 600 cmd`, not `timeout 600 heavy cmd`, because the outer form spends the timeout waiting in the queue. The built-in timeout exits 124, like coreutils `timeout`, and also works on macOS, which doesn't ship `timeout`.
- **Exit codes pass through.** heavy adds only 75 (gave up waiting) and 124 (timed out).
- **Nesting is safe.** `heavy make check` calling `heavy pytest` inside takes one slot, not two, so it can't deadlock on itself.
- **Signals reach the whole command.** Ctrl-C, `kill` or the timeout stop the command and its child processes, and leave no orphans running in the background.
- **Don't wrap things that don't exit.** A dev server or a file watcher would hold its slot forever.

## Platforms

A missing tool never stops the command from running. heavy only loses the protection that tool provided.

| | Queue | Priority | CPU/RAM cap |
|---|---|---|---|
| Linux | `flock` | `nice` + `ionice` | systemd user slice |
| WSL2 | `flock` | `nice` + `ionice` | only with systemd enabled in `/etc/wsl.conf` |
| macOS | `perl` (ships with macOS), or `flock` from Homebrew | `nice` | — |

It runs on bash 3.2, the version macOS ships. CI tests every row above, including a real macOS runner with the system bash.

## Telling your agents

Add something like this to your `AGENTS.md` / `CLAUDE.md`:

```markdown
When `heavy` is on PATH, wrap every heavy verification command in it: test suites, type
checkers, linters, builds. Put the timeout inside (`heavy --timeout 600 <cmd>`). A
`[heavy] queued` line is the queue working, not a hang. Never wrap dev servers or watchers.
```

## Tests

```bash
tests/run.sh
```

## License

MIT
