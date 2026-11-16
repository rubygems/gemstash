# Gemstash verification map

This directory is the maintained source for verifying Gemstash's user-facing behavior: one file per feature, each a recipe of literal commands and the results observed on a live server. [../SKILL.md](../SKILL.md) owns how to launch, drive, judge a proof, and report. This index says which recipes to drive and what they all assume.

## Features

Pick every feature the change or the report can reach. Each entry names the launch option its recipe needs and the code behind the feature.

- [Server lifecycle](./server-lifecycle.md) covers start, `/health`, status, info, version, and stop. Launch: `$S launch`. Code, under `lib/gemstash/` here and below: `cli.rb`, `cli/start.rb`, `cli/stop.rb`, `cli/status.rb`, `cli/info.rb`, `puma.rb`, `config.ru`, `health.rb`, `configuration.rb`, `env.rb`, `db.rb`, `migrations/`, `logging.rb`.
- [API key authorization](./authorize.md) covers generating, scoping, listing, and removing keys with `gemstash authorize`, and the server enforcing them on push. Launch: `$S launch`. Code: `cli/authorize.rb`, `authorization.rb`, `api_key_authorization.rb`, `db/authorization.rb`.
- [Private gems](./private-gems.md) covers push, install with gem and Bundler, duplicate and unauthorized push, and yank on `/private`. Launch: `$S launch`. Code: `gem_pusher.rb`, `gem_yanker.rb`, `gem_source/private_source.rb`, `specs_builder.rb`, `dependencies.rb`, `db/rubygem.rb`, `db/version.rb`, `db/dependency.rb`.
- [Mirror and upstream cache](./mirror-cache.md) covers bundling through Gemstash as a rubygems.org mirror and through `/upstream/<source>`. Launch: `$S launch`, with outbound HTTPS. Code: `gem_source/upstream_source.rb`, `gem_source/dependency_caching.rb`, `gem_fetcher.rb`, `upstream.rb`, `http_client.rb`, `db/upstream.rb`, `db/cached_rubygem.rb`.
- [Protected fetch](./protected-fetch.md) covers requiring a `fetch` key to download private gems. Launch: `$S launch --protected-fetch`. Code: the `protected_fetch` checks in `gem_source/private_source.rb` and `specs_builder.rb`.

A change to code that every request passes through (`web.rb`, `gem_source.rb`, `gem_source/rack_middleware.rb`, `rack_env_rewriter.rb`, `storage.rb`, `cache.rb`) reaches both Private gems and Mirror and upstream cache. Drive both.

`gemstash setup` (`cli/setup.rb`) prompts interactively and has no recipe yet. A change to it, or to any other user-facing behavior that no file here covers, is a gap in the map. Report the behavior as not covered, drive it with `$S run` from the user's documented command in `docs/`, and add a feature file that follows the contract below once the commands and results are observed.

## Baseline preconditions

- `$S launch` started the run with the option the feature entry names, and `$S doctor $RUN` ends `doctor: healthy`.
- The run has driven no other feature file. A fresh run has no API keys, no private gems, and an empty `gem_cache`, and every recipe is written against that state.

## Driving conventions

- Keep every command literal, including gem names, versions, key values, and labels, so the evidence of two runs compares file by file.
- Create API keys with `gemstash authorize ... --key <value>` when a later step uses the key. The generated-key form belongs only where the recipe tests key generation.
- Let the server see each key only after the key's last change, unless the recipe says otherwise. With the memory cache, the server keeps the permissions it first looked up (see Gotchas in [authorize.md](./authorize.md)).
- Follow each mutation (authorize, push, yank, mirror fetch) with `$S state $RUN LABEL`.

## Feature entry contract

Each feature file starts with an H1 title and one paragraph describing the user-visible behavior. It then uses exactly four H2 sections in this order.

1. `Sub-features` lists short IDs with one line for each behavior. Reports cite these IDs.
2. `How to get to it (user POV)` lists every user entry point.
3. `Driving it with verify-gemstash` starts with `Preconditions:` and uses labeled bullets that pair each user action with an exact command and its observable result. Each label is followed by the sub-feature IDs the bullet proves, or `(setup)` when it only prepares state.
4. `Gotchas` lists traps that can waste or invalidate a verification run.

A result enters the map only after it is observed on a live server. When the current code does not do what the feature documents, the bullet states the documented result after `Expected:`, and Gotchas records the observed result as `Known failure on <commit>`. The expectation is never changed to match the failure.

Keep implementation details out of the recipes. Name only user paths, required state, commands, and observable proof. A Gotchas entry may name the cause of a known failure when it explains what the evidence will show.
