# Gemstash verification map

This directory is the maintained source for verifying Gemstash's user-facing behavior. Read this index before driving the app, then use the matching feature file as the recipe.

## Baseline preconditions

- Ruby and the bundle are installed (see Prerequisites in [../SKILL.md](../SKILL.md)).
- Each shell call starts with `S=.agents/skills/verify-gemstash/scripts/verify-gemstash` and `RUN=<id>` from the repository root.
- The run was started by `$S launch` with the options the feature file names, and `$S doctor $RUN` ends `doctor: healthy`.
- A fresh run has no API keys, no private gems, and an empty `gem_cache`.

## Driving conventions

- Run every user action through `$S run $RUN LABEL '<command>'`, with the command single-quoted so `$VERIFY_GEMSTASH_URL` expands inside the run.
- Keep commands literal, including gem names, versions, keys, and labels, so evidence from different runs lines up.
- Create API keys with `gemstash authorize ... --key <value>` when a later step needs the key. Use the generated-key form only where the feature tests key generation.
- Put Gemfiles and bundle installs in their own subdirectory of `work/` (for example `app-private/`), and run `gem install` with `--remote`. `work/` holds the built `.gem` files, and RubyGems installs a matching local `.gem` without contacting the server.
- Take a `$S state $RUN LABEL` after each mutation (authorize, push, yank, mirror fetch).

## Proof and skip reporting

- CLI proof is the numbered `.cmd`, `.out`, `.err`, and `.exit` files. HTTP proof includes the status code (`curl -w '%{http_code}'`).
- Mutation proof adds a `state` dump or a second user-facing read (install, index fetch, `authorize --list`) showing the stored result.
- Record the feature file and sub-feature IDs you drove next to the evidence path in your report.
- A step whose result differs from the map is a failure. Report the expected and observed result and the evidence file. Do not report a skipped entry point as verified through another one.

## Feature entry contract

Each feature file starts with an H1 title and one paragraph describing the user-visible behavior. It then uses exactly four H2 sections in this order.

1. `Sub-features` lists short IDs with one line for each behavior.
2. `How to get to it (user POV)` lists every user entry point.
3. `Driving it with verify-gemstash` starts with `Preconditions:` and uses labeled bullets that pair each user action with an exact command and observable result.
4. `Gotchas` lists traps that can waste or invalidate a verification run, including known failures observed on the current code.

## Features

- [Server lifecycle](./server-lifecycle.md) covers start, health, status, info, version, and stop.
- [API key authorization](./authorize.md) covers generating, scoping, listing, and removing keys with `gemstash authorize`.
- [Private gems](./private-gems.md) covers push, install with gem and Bundler, duplicate and unauthorized push, and yank on `/private`.
- [Mirror and upstream cache](./mirror-cache.md) covers bundling through Gemstash as a rubygems.org mirror and through `/upstream/<source>`.
- [Protected fetch](./protected-fetch.md) covers requiring a `fetch` key to download private gems.
