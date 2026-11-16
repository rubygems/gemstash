# Server lifecycle

A user starts Gemstash with `gemstash start`, checks it with `gemstash status` and the `/health` endpoint, reads its effective configuration with `gemstash info`, and stops it with `gemstash stop`. All of these honor `--config-file` or `GEMSTASH_CONFIG`.

## Sub-features

- `start` boots puma on the configured `bind` and creates the database and storage under `base_path`.
- `health` serves `/health` (all checks) and `/health/<check>` for each named check.
- `status` reports `Puma is started` through the pidfile.
- `info` prints the effective configuration, defaults merged with the config file.
- `version` prints `Gemstash version <x.y.z>`.
- `stop` stops the server through the pidfile and prints `Gemstash stopped successfully!`.

## How to get to it (user POV)

- Run `gemstash start [--config-file FILE]` in a terminal. It stays in the foreground, and `--daemonize` has no effect.
- Run `gemstash status`, `gemstash info`, `gemstash version`, and `gemstash stop` in another terminal.
- Request `GET /health` or `GET /health/heartbeat` over HTTP, as a load balancer would.

## Driving it with verify-gemstash

Preconditions:

- No run is needed beforehand. `launch` performs the start.

- **Start.** Run `$S launch`. It prints `RUN=`, `URL=`, `PID=`, and `health: {"status":{"heartbeat":"OK","storage_read":"OK","storage_write":"OK","db_read":"OK","db_write":"OK"}}`. `$EVIDENCE/launch-health.json` holds the same JSON.
- **Doctor.** Run `$S doctor $RUN`. Every line is `ok` and the last line is `doctor: healthy`.
- **Single check.** Run `$S run $RUN health-heartbeat 'curl -s -w "\nHTTP %{http_code}\n" $VERIFY_GEMSTASH_URL/health/heartbeat'`. Stdout ends `HTTP 200` and shows `heartbeat` as `OK`.
- **Status.** Run `$S run $RUN status 'gemstash status'`. Exit `0`, stdout `Puma is started`.
- **Info.** Run `$S run $RUN info 'gemstash info'`. Exit `0`, stdout includes `base_path: <RUN_DIR>/base`, `bind: tcp://127.0.0.1:<port>`, `cache_type: memory`, and `db_adapter: sqlite3`.
- **Version.** Run `$S run $RUN version 'gemstash version'`. Stdout matches `Gemstash version` followed by the value of `Gemstash::VERSION` in `lib/gemstash/version.rb`.
- **Stored state.** Run `$S state $RUN started`. The file list includes `./gemstash.db`, `./metadata.yml`, and `./puma.pid`.
- **Stop.** Run `$S cleanup $RUN`. `$EVIDENCE/cleanup-stop.txt` contains `Command stop sent success` and `Gemstash stopped successfully!`, and cleanup prints `stopped PID <pid>`. Then run `$S list`; the run is not listed.

## Gotchas

- `gemstash start` blocks. The helper backgrounds it, and running it through `$S run` would hang that call.
- The puma master retitles itself `puma <version> (tcp://...) [work]`, so search for a run by its PID or port, not by `gemstash` in the process list.
- With the default `puma_workers: 1`, puma logs a cluster-mode warning on every start. It is expected.
- `/health` runs `storage_write` on every request, which rewrites `health/t/e/s/test-*/example`. Use `/health/heartbeat` for a check that writes nothing.
- `gemstash info` and `gemstash version` read config from the CLI side only. They do not prove the server is up.
