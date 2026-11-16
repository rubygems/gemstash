---
name: verify-gemstash
description: Proves Gemstash behavior on a disposable server launched from this checkout, driven the way users do (gemstash CLI, gem, bundle, curl), with every command, exit code, and stored state kept as evidence. Use when asked to "verify this gemstash change", "prove it works end to end", "reproduce this gemstash bug", or "check that gem push to /private still works", or to check private gem, API key, mirror cache, or protected fetch behavior on a running server. Not for running the spec suite.
compatibility: Needs Ruby and this repository's bundle (.agents/setup with mise, or bin/setup), plus bash, curl, and lsof. The mirror recipes need outbound HTTPS to rubygems.org. Verified on Linux with Ruby 3.3 and 4.0, JRuby 10.1, sqlite3, postgres, mysql2, memcached, and redis, and on macOS with Ruby 3.3 and sqlite3.
---

# Verify Gemstash

Gemstash has no web UI. Users touch the `gemstash` CLI (`start`, `stop`, `status`, `authorize`, `info`, `version`) and the gem server it starts, which they reach through `gem push`, `gem yank`, `gem install`, `bundle install`, and `GET /health`. A **proof** drives one of those commands against a live server and pairs it with a **second view** of its effect: the stored rows and files, or a later user-facing read. A passing spec or a Ruby call into `Gemstash::` is not a proof.

Run every command from the repository root. Each shell call starts fresh, so begin each one with:

```bash
S=.agents/skills/verify-gemstash/scripts/verify-gemstash
RUN=<the RUN printed by launch>
```

`$S help` lists the helper's commands. The helper needs Ruby and the bundle installed: `.agents/setup` installs both with mise (the first run compiles the Ruby that `mise.toml` pins, about 2 to 3 minutes), or run `bin/setup` with a Ruby you already have. The helper looks for Ruby through `mise exec` in the repository, then for `ruby` on `PATH`. To verify on another Ruby, install it with mise and set `MISE_RUBY_VERSION` (such as `4.0.9` or `jruby-10.1.3.0`) for the whole session, then run `mise exec -- bundle install` once with it set.

## 1. Launch

```bash
$S launch                     # memory cache, sqlite3, upstream https://rubygems.org
$S launch --protected-fetch   # private gems need a fetch key
$S launch --upstream URL      # a different default upstream
$S launch --set db_adapter=postgres --set db_url=postgres://USER:PASS@127.0.0.1:5432/DB \
          --set cache_type=redis --set redis_servers=redis://127.0.0.1:6379
```

`--set KEY=VALUE` adds a key from `docs/gemstash-configuration.5.md` to the run's config. It refuses `base_path`, `bind`, `pidfile`, `log_file`, `rubygems_url`, and `protected_fetch`, which the helper owns so every run stays disposable. Use it for keys such as `db_adapter=mysql2` with `db_url=mysql2://...` or `cache_type=memcached` with `memcached_servers=127.0.0.1:11211`. The helper does not start or reset those services. Each run needs an empty database and an empty cache, so drop and recreate the database and flush the cache before every launch; leftovers from an earlier run break the recipes' row counts and the fresh-key steps. Doctor's `info settings` line shows the extra keys with passwords removed.

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

**To verify a change or check a feature**, read [features/INDEX.md](features/INDEX.md). It routes the change to its feature files and states what every recipe assumes. Follow each chosen recipe top to bottom on its own run, and drive every bullet: a proof through one entry point is incomplete when the recipe lists others.

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

## Example

The user says: "I changed `gem_pusher.rb` so a duplicate push returns 422. Verify it."

1. [features/INDEX.md](features/INDEX.md) lists `gem_pusher.rb` under Private gems, so the recipe is [features/private-gems.md](features/private-gems.md), launched with plain `$S launch`.
2. `$S doctor $RUN` ends `doctor: healthy`, and its `info` line shows `lib/bin/exe modified`, which confirms the run loaded the edited code.
3. Every bullet of the recipe runs through `$S run` or `$S state`, from **Key and credentials** to **Yank effect**.
4. `$S cleanup $RUN`, then `ls tmp/verify-gemstash/$RUN` still lists the evidence.

The report gives the code under test, then one line per sub-feature: `private-push-duplicate` passes when `NN-push-duplicate.out` shows `{"error":"Version already exists","code":422}` and `HTTP 422`. Because that bullet points to a known failure in Gotchas, the report also says the entry is deleted in the same change. The other sub-features are listed as pass or fail with their evidence files.

## Troubleshooting

These are the helper's own errors. Traps specific to one recipe are in that feature file's Gotchas.

- **`no Ruby found; run .agents/setup or bin/setup`.** Neither `mise exec` in the repository nor `ruby` on `PATH` gave a Ruby. In an orb, mise lives in `~/.local/bin`, which a fresh shell may not have on `PATH`: run `export PATH=$HOME/.local/bin:$PATH`, or run `.agents/setup` if Ruby was never installed.
- **`bundle is incomplete; run bin/setup (or .agents/setup) first`.** `bundle check` failed, usually on a fresh checkout or after the Gemfile changed. Run `bin/setup` with the same Ruby, then launch again. When this follows a `bin/setup` that succeeded, `bin/setup` ran another Ruby's `bundle`; on macOS a Homebrew Ruby on `PATH` can come before mise's even inside `mise exec`. Run `PATH="$(mise exec -- ruby -e 'print RbConfig::CONFIG["bindir"]'):$PATH" bin/setup`.
- **`bundle install` on JRuby fails and lists `gemstash-2.8.2-java` as the only matching gem in source `.`.** The gitignored `Gemfile.lock` was resolved on CRuby and locks the `ruby` platform gem. Move it aside, run `mise exec -- bundle install` with JRuby selected so it resolves a fresh lock, and put the CRuby lock back when you switch Rubies again.
- **`server exited during launch; run cleanup <RUN>`.** Puma died before `/health` answered. The last 40 lines of `launch.log` are printed above the error. Fix what they show, run `$S cleanup <RUN>`, and launch again.
- **`/health never returned 200; run cleanup <RUN>`.** The server stayed up for about 60 seconds but `/health` never answered 200. `$EVIDENCE/launch-health.json` holds the last response body. Clean up and launch again; a repeat on a fresh run is a Gemstash failure to report.
- **`doctor: NOT healthy`.** Each `FAIL` line names a check. `checkout code unchanged since launch` means `lib/`, `bin/`, `exe/`, or the bundle changed after launch, so the server still runs the old code. In every case, clean up and launch a new run.
- **`no run at ... (already cleaned up?)`.** The RUN id is wrong or the run was cleaned up. `$S list` shows the runs on disk.
- **`PID <pid> still running; not deleting <RUN_DIR>`.** `gemstash stop` and the signals did not stop the server. Check it with `ps -o pid,args -p <pid>`, stop that PID yourself, and run cleanup again.
- **`PID <pid> is no longer this run's server (reused?); left it running`.** The server died and its PID now belongs to a process whose command line or working directory is not this run's, so cleanup did not signal it and removed the run anyway. Treat the server as crashed: `server.log` in the evidence holds its last lines, and the result for any sub-feature driven after the crash is `blocked`.
- **A mirror step fails with a connection or DNS error.** Outbound HTTPS is blocked. Report the step as `blocked`, not `fail`.
