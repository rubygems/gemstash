---
name: verify-gemstash
description: Proves Gemstash behavior on a disposable server launched from this checkout, driven the way users do (gemstash CLI, gem, bundle, curl), with every command, exit code, and stored state kept as evidence. Use to verify a Gemstash change end to end, to reproduce a reported server or CLI bug, or to check private gem, API key, mirror cache, or protected fetch behavior on a running server. Not for running the spec suite.
---

# Verify Gemstash

Gemstash has no web UI. Users touch the `gemstash` CLI (`start`, `stop`, `status`, `authorize`, `info`, `version`) and the gem server it starts, which they reach through `gem push`, `gem yank`, `gem install`, `bundle install`, and `GET /health`. A **proof** drives one of those commands against a live server and pairs it with a **second view** of its effect: the stored rows and files, or a later user-facing read. A passing spec or a Ruby call into `Gemstash::` is not a proof.

Run every command from the repository root. Each shell call starts fresh, so begin each one with:

```bash
S=.agents/skills/verify-gemstash/scripts/verify-gemstash
RUN=<the RUN printed by launch>
```

`$S help` lists the helper's commands. The helper needs Ruby and the bundle installed: `.agents/setup` installs both with mise (the first run compiles the Ruby that `mise.toml` pins, about 2 to 3 minutes), or run `bin/setup` with a Ruby you already have. The helper looks for Ruby through `mise exec` in the repository, then for `ruby` on `PATH`.

## 1. Launch

```bash
$S launch                     # memory cache, sqlite3, upstream https://rubygems.org
$S launch --protected-fetch   # private gems need a fetch key
$S launch --upstream URL      # a different default upstream
```

Each launch is a new **run**: its own id, free `127.0.0.1` port, `base_path`, and `HOME`, with `bin/gemstash start` in the background. Runs share nothing, so several can be up at once. Launch returns when `GET /health` answers 200, which means the migrations have run and the database is usable. It prints `RUN=`, `URL=`, `PID=`, `RUN_DIR=` (scratch state under `/tmp/verify-gemstash/`), `EVIDENCE=`, and the health JSON.

Launch a new run for each feature file, and again after every change to `lib/`, `bin/`, `exe/`, or the bundle. A running server keeps the code it loaded at start, while `gemstash` CLI commands pick up an edit at once, so a run that is older than the edit proves the old server against the new CLI.

Drive only runs this helper launched. A server on port 9292 or on `~/.gemstash` is someone's own.

Done when launch prints `RUN=` and a `health:` line whose five checks all read `OK`.

## 2. Doctor

```bash
$S doctor $RUN
```

Doctor is read-only and answers one question: is this run worth driving? It checks that the launched PID is alive, is the puma that owns this run's port, answers `/health`, and still runs the code in the checkout. Its `info` lines give the Gemstash version, the checkout revision, and whether `lib/`, `bin/`, or `exe/` have uncommitted changes. Quote them in the report so the evidence names the code under test.

Run doctor before the first drive and again after any result the recipe does not predict.

Done when the last line is `doctor: healthy`. On `doctor: NOT healthy`, clean up the run and launch a new one. A repaired run is not the state the recipes assume.

## 3. Drive

```bash
$S run $RUN LABEL 'SHELL COMMAND'   # one user action, recorded
$S make-gem $RUN NAME VERSION       # builds work/NAME-VERSION.gem, a minimal gem with lib/NAME.rb
$S state $RUN LABEL                 # second view: database rows and files under base_path
```

`run` executes the command with `bash -c` as a Gemstash user would. The cwd is the run's `work/` directory. `HOME` is the run's own, so `~/.gem/credentials` and Bundler's global config stay isolated. `gemstash` on `PATH` is this checkout's `bin/gemstash` reading the run's config. `$VERIFY_GEMSTASH_URL` is the server, and `$VERIFY_GEMSTASH_LOG` is its `server.log`, where each request appears with its rewritten path and status. `run` prints stdout, stderr, and `[exit N]`, and exits with the command's status.

`state` lists the `authorizations`, `rubygems`, `versions`, `dependencies`, `upstreams`, and `cached_rubygems` rows from the run's SQLite database, and every stored file, such as `private/gems/...` and `gem_cache/<upstream>/...`.

Three traps apply to every drive:

- Single-quote the command. `$VERIFY_GEMSTASH_URL` exists only inside the run, and double quotes expand it to nothing in your shell first.
- Run `gem install` with `--remote`, and give each Gemfile its own subdirectory of `work/`. `work/` holds the built `.gem` files, and RubyGems installs a matching local `.gem` without contacting the server.
- `gem push` and `gem yank` print one line on success and nothing useful on a 500. When the status matters, send the same request with `curl -w '%{http_code}'`.

**To verify a change or check a feature**, read [features/README.md](features/README.md). It routes the change to its feature files and states what every recipe assumes. Follow each chosen recipe top to bottom on its own run, and drive every bullet: a proof through one entry point is incomplete when the recipe lists others.

**To reproduce a reported bug**, write down the result the reporter expected and the result they got before you drive anything. Launch as the closest feature file's preconditions say, then run the reporter's own commands through `$S run`, changing only the host, port, and paths. The bug is reproduced when a second, fresh run shows the same wrong result. After a fix, launch a new run and repeat the same commands with the same labels, so the two evidence directories compare file by file.

Done when every bullet of each chosen recipe, or every reported command, has its numbered evidence files, and every mutation (authorize, push, yank, mirror fetch) is followed by a `state` file or a second user-facing read.

## 4. Evidence

Evidence lands in `tmp/verify-gemstash/$RUN/` in this repository, which is gitignored. `VERIFY_GEMSTASH_EVIDENCE` moves the parent directory. Each `run` and `make-gem` writes `NN-LABEL.cmd`, `.out`, `.err`, and `.exit`. Each `state` writes `NN-state-LABEL.txt`. `transcript.md` holds the whole run in order. Launch adds `config.yml` and `launch-health.json`, and cleanup adds `server.log`, `launch.log`, and `cleanup-stop.txt`.

A step is proved when all of these hold:

- The command is one a user runs, such as `gem push --host <url>/private`, `bundle install` through a mirror, or `gemstash authorize`.
- A second view shows the effect. A push has the `versions` row and the stored gem file in `state`. A mirror install has the `cached_rubygems` row and the `is not cached, fetching gem` line in `$VERIFY_GEMSTASH_LOG`.
- The result is read from `[exit N]` and the HTTP status, compared with what the recipe states.

A result that differs from the recipe is a `fail`. The recipe's expectation stays as written, and the server stays as it is: rewording the expectation, or restarting the server to get a pass, hides the failure.

A bullet that says `Expected:` and points to a `Known failure on <commit>` entry in Gotchas already fails on main. Drive it anyway and report it as a `fail` that is known. When it meets its expectation instead, report that and delete the Gotchas entry in the same change.

## 5. Clean up

```bash
$S cleanup $RUN
$S list                        # runs still on disk, with alive or dead PIDs
ls tmp/verify-gemstash/$RUN    # the evidence
```

Cleanup stops the server with `gemstash stop` through the run's pidfile, signals only the recorded PID if it is still up, copies `server.log` into the evidence directory, and deletes `RUN_DIR`. It never deletes evidence. Clean up every run you launched, including launches that failed: a launch that died still leaves a run directory.

Done when `$S list` no longer shows the run and `ls` still shows its evidence files.

## 6. Report

Report from the evidence files, not from memory:

- The code under test: doctor's `info` line with the version, the revision, and whether the code was modified.
- Each sub-feature ID you drove, from the feature file's `Sub-features` list, as `pass`, `fail`, or `blocked`, with its evidence file.
- For each `fail`: the expected result, the observed result, and whether Gotchas records it as a known failure.
- For each `blocked`: the command attempted and the unmet prerequisite, such as no outbound HTTPS for the mirror recipe. An environment blocker is not a Gemstash failure.
- Each sub-feature you did not drive, named as not driven. A skipped entry point is not verified through another one.
- The evidence directory of every run.
