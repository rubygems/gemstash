# Mirror and upstream cache

A user points Bundler at Gemstash as a mirror of rubygems.org, or names another source through `/upstream/<source>`. Gemstash fetches each `.gem` once, stores it permanently, and serves later requests from its cache. Index requests (`/versions`, `/info/*`) are redirected to the upstream's index.

## Sub-features

- `mirror-bundle` installs gems through `bundle config mirror.https://rubygems.org <url>`.
- `mirror-cache-fill` stores the first fetch under `gem_cache/<upstream>/` with a `cached_rubygems` row.
- `mirror-cache-hit` serves a repeat fetch without contacting the upstream.
- `mirror-index-redirect` answers `/versions` and `/info/<name>` with 302 to `index.rubygems.org`.
- `upstream-source` serves a gem through `/upstream/<CGI-escaped source>` and caches it per source.
- `upstream-readonly` refuses push and yank on upstream sources.

## How to get to it (user POV)

- Run `bundle config mirror.https://rubygems.org <url>`, keep `source "https://rubygems.org"` in the Gemfile, and run `bundle install`.
- Use `source "<url>"` directly in a Gemfile, which uses the configured default upstream.
- Use `source "<url>/upstream/#{CGI.escape("https://other.source")}"` in a Gemfile for another source.

## Driving it with verify-gemstash

Preconditions:

- A run started with `$S launch` (default upstream `https://rubygems.org`) and a healthy `$S doctor $RUN`.
- Outbound HTTPS to rubygems.org and index.rubygems.org works.
- `rainbow` 3.1.1 (no runtime dependencies) is not yet cached in this run.

- **Mirror install** (`mirror-bundle`). Run `$S run $RUN bundle-mirror 'mkdir -p app-mirror && cd app-mirror && printf "source \"https://rubygems.org\"\ngem \"rainbow\", \"3.1.1\"\n" > Gemfile && bundle config set --local mirror.https://rubygems.org $VERIFY_GEMSTASH_URL && bundle config set --local path vendor/bundle && bundle install'`. Exit `0`, stdout `Fetching gem metadata from http://127.0.0.1:<port>/` and `Installing rainbow 3.1.1`.
- **Cache fill** (`mirror-cache-fill`). Run `$S state $RUN after-mirror`. `upstreams` has `uri: "https://rubygems.org/"`, `cached_rubygems` has `name: "rainbow-3.1.1"` and `resource_type: "gem"`, and files include `./gem_cache/rubygems.org_*/r/a/i/rainbow_3_1_1-*/gem`. Run `$S run $RUN log-fill 'grep -c "Gem rainbow-3.1.1 is not cached" $VERIFY_GEMSTASH_LOG'`. Stdout `1`.
- **Index redirect** (`mirror-index-redirect`). Run `$S run $RUN index-redirect 'curl -s -o /dev/null -w "HTTP %{http_code} %{redirect_url}\n" $VERIFY_GEMSTASH_URL/info/rainbow'`. Stdout `HTTP 302 https://index.rubygems.org/info/rainbow`.
- **Cache hit** (`mirror-cache-hit`). Run `$S run $RUN bundle-mirror-again 'mkdir -p app-mirror2 && cd app-mirror2 && cp ../app-mirror/Gemfile . && bundle config set --local mirror.https://rubygems.org $VERIFY_GEMSTASH_URL && bundle config set --local path vendor/bundle && bundle install && grep -c "Gem rainbow-3.1.1 is not cached" $VERIFY_GEMSTASH_LOG'`. Exit `0`, `Installing rainbow 3.1.1`, and the final count is still `1`.
- **Upstream source** (`upstream-source`). Run `$S run $RUN upstream-source 'curl -s -o rainbow-upstream.gem -w "HTTP %{http_code}\n" "$VERIFY_GEMSTASH_URL/upstream/$(ruby -rcgi -e "print CGI.escape(%q(https://rubygems.org))")/gems/rainbow-3.1.1.gem" && sha256sum rainbow-upstream.gem app-mirror/vendor/bundle/ruby/*/cache/rainbow-3.1.1.gem'`. Stdout `HTTP 200` and two identical SHA-256 sums.
- **Upstream read-only** (`upstream-readonly`). Run `$S run $RUN upstream-push 'curl -s -w "\nHTTP %{http_code}\n" -X POST $VERIFY_GEMSTASH_URL/upstream/rubygems.org/api/v1/gems'`. Stdout `Cannot add gem to an upstream server!` and `HTTP 403`.

## Gotchas

- `$VERIFY_GEMSTASH_LOG` exists only inside `$S run`. From your own shell the log is `$RUN_DIR/base/server.log`, and after cleanup it is `server.log` in the evidence directory.
- `/upstream/https%3A%2F%2Frubygems.org` (no trailing slash) is a different cache namespace from the default `https://rubygems.org/`, so the first fetch through it logs `is not cached` again. That is expected per-source isolation, not a cache miss.
- The mirror journeys depend on live rubygems.org. A network failure is an environment blocker; report it as such, not as a Gemstash failure. Use `$S launch --upstream URL` to point at a different source.
- Bundler installs `rainbow` into `vendor/bundle` in each app dir. A second install in the same dir reuses Bundler's own copy and never reaches Gemstash, so the cache-hit step uses a fresh `app-mirror2`.
- Dependency and index data are cached in memory only for `cache_expiration` (30 min). The permanent cache covers `.gem` files and quick-marshal specs.
