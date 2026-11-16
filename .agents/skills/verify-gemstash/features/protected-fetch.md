# Protected fetch

With `protected_fetch: true`, Gemstash requires an API key with `fetch` (or `all`) permission to download private gems and their specs. Bundler and curl send the key as the HTTP Basic username. Pushing and yanking keep their own permission checks.

## Sub-features

- `pf-anon-denied` returns 401 for a private gem download with no key.
- `pf-wrong-perm-denied` returns 401 for a key without `fetch`.
- `pf-fetch-allowed` serves the exact pushed bytes to a `fetch` key.
- `pf-bundle-denied` makes `bundle install` fail with `Authentication is required` when Bundler has no credentials.
- `pf-bundle-allowed` installs the gem when Bundler has the key for the host.

## How to get to it (user POV)

- Enable `protected_fetch` with `gemstash setup` or `:protected_fetch: true` in the config file, then restart the server.
- Give Bundler the key with `bundle config <host> <key>`, `BUNDLE_<HOST>=<key>`, or `source "http://<key>@<host>/private"`.
- Download with `curl -u <key>: <url>/private/gems/<name>-<version>.gem`.

## Driving it with verify-gemstash

Preconditions:

- A run started with `$S launch --protected-fetch` and a healthy `$S doctor $RUN` (its `info` line shows `protected_fetch true`).

- **Keys** (setup). Run `$S run $RUN keys 'gemstash authorize push --key verify-push-only && gemstash authorize fetch --key verify-fetch-only'`. Exit `0`.
- **Push** (setup). Run `$S make-gem $RUN verify-protected 0.1.0`, then `$S run $RUN push 'GEM_HOST_API_KEY=verify-push-only gem push --host $VERIFY_GEMSTASH_URL/private verify-protected-0.1.0.gem'`. Exit `0`.
- **Anonymous download** (`pf-anon-denied`). Run `$S run $RUN fetch-anon 'curl -s -o /dev/null -w "HTTP %{http_code}\n" $VERIFY_GEMSTASH_URL/private/gems/verify-protected-0.1.0.gem'`. Stdout `HTTP 401`.
- **Push-only key** (`pf-wrong-perm-denied`). Run `$S run $RUN fetch-push-key 'curl -s -o /dev/null -w "HTTP %{http_code}\n" -u verify-push-only: $VERIFY_GEMSTASH_URL/private/gems/verify-protected-0.1.0.gem'`. Stdout `HTTP 401`.
- **Fetch key** (`pf-fetch-allowed`). Run `$S run $RUN fetch-fetch-key 'curl -s -o got.gem -w "HTTP %{http_code}\n" -u verify-fetch-only: $VERIFY_GEMSTASH_URL/private/gems/verify-protected-0.1.0.gem && cmp got.gem verify-protected-0.1.0.gem && echo identical'`. Stdout `HTTP 200` and `identical`.
- **Bundler without credentials** (`pf-bundle-denied`). Run `$S run $RUN bundle-anon 'mkdir -p app-anon && cd app-anon && printf "source \"%s/private\"\ngem \"verify-protected\"\n" "$VERIFY_GEMSTASH_URL" > Gemfile && bundle config set --local path vendor/bundle && bundle install'`. Exit `17`, stdout includes `Authentication is required for 127.0.0.1.`
- **Bundler with credentials** (`pf-bundle-allowed`). Run `$S run $RUN bundle-key 'cd app-anon && BUNDLE_127__0__0__1=verify-fetch-only bundle install && bundle exec ruby -e "require %q(verify-protected); puts VerifyProtected::VERSION"'`. Exit `0`, stdout `Installing verify-protected 0.1.0` and ends `0.1.0`.

## Gotchas

- Bundler matches credentials by host only. The key is `127.0.0.1` (`BUNDLE_127__0__0__1`), not `127.0.0.1:<port>`. A `host:port` config key is ignored, and the install still fails with `Authentication is required`.
- Revoking a key the server has already used does not take effect until the in-memory authorization cache expires. See the known failure in [authorize.md](./authorize.md). Do not test revocation here with a key that has already fetched.
- Upstream and mirror downloads are never protected. Only `/private` paths check `fetch`.
- `protected_fetch` is read at server start. Changing the config needs a new run (`$S launch --protected-fetch`), not an edit to a running one.
