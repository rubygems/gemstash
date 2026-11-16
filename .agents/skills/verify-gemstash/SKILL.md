---
name: verify-gemstash
description: Launches a disposable Gemstash server from this checkout and drives it the way users do, through the gemstash CLI, gem, bundle, and HTTP, capturing command evidence and stored state. Use to prove a Gemstash change end to end, reproduce a reported server or CLI bug, or check private-gem, mirror, auth, or protected-fetch behavior.
---

# Verify Gemstash

Gemstash has no web UI. Its user surface is the `gemstash` CLI (start, stop, status, authorize, info, version) and the gem server it starts, which users reach through `gem push`, `gem yank`, `gem install`, and `bundle install`, plus `/health`. Drive those, not specs or internal classes.

All commands below run from the repository root. Set these at the top of every shell call, because each shell starts fresh:

```bash
S=.agents/skills/verify-gemstash/scripts/verify-gemstash
RUN=<the RUN printed by launch>
```

## Prerequisites

Ruby and the bundle must already be installed. In an Amp orb, `.agents/setup` installs them with mise (it compiles the Ruby that `mise.toml` pins, about 2–3 minutes the first time). Elsewhere, run `bin/setup` with that Ruby. The helper finds Ruby through `mise exec` in the repository, falling back to `ruby` on `PATH`, so put mise on `PATH` (`export PATH=$HOME/.local/bin:$PATH` in an orb). Launch fails with `bundle is incomplete` until this is done.

Mirror journeys fetch from https://rubygems.org and need outbound HTTPS. Everything else is local.

## Launch

```bash
$S launch                     # default config: memory cache, sqlite3, upstream rubygems.org
$S launch --protected-fetch   # private gems need a fetch key
$S launch --upstream URL      # different default upstream
```

Each launch gets a new RUN id, a free `127.0.0.1` port, its own `base_path`, and its own `HOME`, then runs `bin/gemstash start --config-file <run>/config.yml` in the background. Launch returns only when `GET /health` answers 200 with all five checks (`heartbeat`, `storage_read`, `storage_write`, `db_read`, `db_write`) `OK`, so migrations have run and the database is usable. It prints `RUN=`, `URL=`, `PID=`, `RUN_DIR=` (scratch state, default `/tmp/verify-gemstash/$RUN`), `EVIDENCE=`, and the health JSON. Runs are fully isolated, so several can run side by side. Drive only runs that this helper launched. A server on port 9292 or using `~/.gemstash` belongs to someone else.

## Doctor

```bash
$S doctor $RUN
```

Read-only. It checks that the launched PID is alive and matches `puma.pid`, that the process is puma bound to this run's port with cwd in this run's work dir, that the PID owns the listening port, and that `/health/heartbeat` and `/health/db_read` return 200. It prints the Gemstash version and checkout revision, and flags modified `lib/`, `bin/`, or `exe/`. Run it first whenever anything looks off. If it ends `NOT healthy`, clean up the run and launch a new one instead of repairing it.

## Drive

```bash
$S run $RUN LABEL 'SHELL COMMAND'
```

This runs the command with `bash -c` as a Gemstash user would. The cwd is the run's `work/` dir and `HOME` is the run's own home, so `~/.gem/credentials` and global bundle config stay isolated. `gemstash` on `PATH` is this checkout's `bin/gemstash`, which uses the run's config through `GEMSTASH_CONFIG`. `$VERIFY_GEMSTASH_URL` is the server URL. Single-quote the command so `$VERIFY_GEMSTASH_URL` expands inside the run. The helper prints stdout, stderr, and `[exit N]`, and exits with the command's status.

```bash
$S make-gem $RUN NAME VERSION   # builds work/NAME-VERSION.gem, a minimal gem with lib/NAME.rb
$S state $RUN LABEL             # read-only dump of DB rows and files under base_path
```

`state` is the second view for side effects. It lists `authorizations`, `rubygems`, `versions`, `upstreams`, and `cached_rubygems` rows from the run's SQLite DB, plus every stored file, such as `private/gems/...` and `gem_cache/<upstream>/...`. The server log is `$RUN_DIR/base/server.log` while the run is up. Each request appears there with its rewritten path and status.

The feature map in [features/README.md](features/README.md) holds the recipe for each user-facing feature. Read it before driving, and follow the matching feature file.

## Evidence

Evidence goes to `tmp/verify-gemstash/$RUN/` in this repository (gitignored). Set `VERIFY_GEMSTASH_EVIDENCE` to change the parent directory. Every `run`, `make-gem`, and `state` call writes numbered files: `NN-LABEL.cmd`, `.out`, `.err`, and `.exit`, or `NN-state-LABEL.txt`. Each call also appends to `transcript.md`. Launch writes `config.yml` and `launch-health.json`. Cleanup adds `server.log`, `launch.log`, and `cleanup-stop.txt`.

A proof:

- Drives the documented user command (`gem push --host .../private`, `bundle install` with a mirror, `gemstash authorize`) and not a spec helper or a Ruby call into `Gemstash::`.
- Pairs every action with a second view of its effect. For example, show a push with a `state` dump showing the `versions` row and the stored gem file, or a mirror install with the `cached_rubygems` row and the `is not cached, fetching gem` line in `server.log`.
- Treats `[exit N]` and HTTP status as the result. `gem push` and `gem yank` print almost nothing on success and nothing useful on a 500, so add `curl -w '%{http_code}'` against the same endpoint when the status matters.
- Reports a step that does not match the map as a failure with its evidence file, and does not reword the expectation.

## Cleanup

```bash
$S cleanup $RUN
$S list      # any runs still on disk, with alive or dead PIDs
```

Cleanup sends `gemstash stop` through the run's pidfile, waits, and then signals only the recorded PID. It copies `server.log` into the evidence dir and deletes `RUN_DIR`. The evidence dir is never deleted, so confirm it still lists your files after cleanup. Run cleanup after failed attempts too. A launch that died still leaves a run dir for `cleanup` to remove.
