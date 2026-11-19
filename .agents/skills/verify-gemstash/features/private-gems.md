# Private gems

A user with a `push` key publishes a gem to Gemstash's `/private` source, other users install it with `gem install` or Bundler, and a `yank` key removes it from the index. Pushes and yanks are accepted only under `/private`.

## Sub-features

- `private-push` stores a pushed `.gem` under `private/gems/` and indexes it in `rubygems` and `versions`.
- `private-install-gem` installs the pushed version with `gem install --source <url>/private`.
- `private-install-bundle` resolves and installs it with a `source "<url>/private"` Gemfile.
- `private-push-duplicate` rejects a second push of the same version with HTTP 422 `Version already exists`.
- `private-push-retry` leaves no version or partial gem after a failed storage write, so a retry can publish it.
- `private-push-unauthorized` rejects a push with an invalid key.
- `private-yank` unindexes the version so it disappears from `specs.4.8.gz` and installs fail.
- `private-yank-repush` rejects a push to a yanked version without replacing its stored files.
- `private-upstream-only` refuses pushes to the default (non-`/private`) source.

## How to get to it (user POV)

- Run `gem push --key <credentials name> --host <url>/private <file>.gem` after adding the key to `~/.gem/credentials`, as in the private-gems guide.
- Run `GEM_HOST_API_KEY=<key> gem push --host <url>/private <file>.gem`.
- Run `gem install <name> --source <url>/private`, or `bundle install` with `source "<url>/private"`.
- Run `RUBYGEMS_HOST=<url>/private gem yank --key <credentials name> <name> --version <v>`, as in the guide.

## Driving it with verify-gemstash

Preconditions:

- A run started with `$S launch` and a healthy `$S doctor $RUN`.
- No private gem named `verify-private` exists in the run.

- **Key and credentials** (setup). Run `$S run $RUN key 'gemstash authorize --key verify-all-key --name verify && mkdir -p ~/.gem && printf -- "---\n:verify_key: verify-all-key\n" > ~/.gem/credentials && chmod 0600 ~/.gem/credentials'`. Exit `0`.
- **Build** (setup). Run `$S make-gem $RUN verify-private 0.1.0`. Exit `0`, stdout includes `Successfully built RubyGem`.
- **Push** (`private-push`). Run `$S run $RUN push 'gem push --key verify_key --host $VERIFY_GEMSTASH_URL/private verify-private-0.1.0.gem'`. Exit `0`, stdout `Pushing gem to http://127.0.0.1:<port>/private...`.
- **Stored** (`private-push`). Run `$S state $RUN after-push`. `rubygems` has `verify-private`, `versions` has `full_name: "verify-private-0.1.0-ruby"` with `indexed: true`, and files include `./private/gems/v/e/r/verify_private_0_1_0-*/gem`.
- **Install with gem** (`private-install-gem`). Run `$S run $RUN gem-install 'gem install verify-private -v 0.1.0 --remote --clear-sources --source $VERIFY_GEMSTASH_URL/private --install-dir gems --no-document'`. Exit `0`, stdout `Successfully installed verify-private-0.1.0`.
- **Install with Bundler** (`private-install-bundle`). Run `$S run $RUN bundle-install 'mkdir -p app-private && cd app-private && printf "source \"%s/private\"\ngem \"verify-private\"\n" "$VERIFY_GEMSTASH_URL" > Gemfile && bundle config set --local path vendor/bundle && bundle install && bundle exec ruby -e "require %q(verify-private); puts VerifyPrivate::VERSION"'`. Exit `0`, stdout includes `Fetching gem metadata from http://127.0.0.1:<port>/private/` and ends `0.1.0`.
- **Duplicate push** (`private-push-duplicate`). Run `$S run $RUN push-duplicate 'gem push --key verify_key --host $VERIFY_GEMSTASH_URL/private verify-private-0.1.0.gem; curl -s -w "\nHTTP %{http_code}\n" -H "Authorization: verify-all-key" -H "Content-Type: application/octet-stream" --data-binary @verify-private-0.1.0.gem $VERIFY_GEMSTASH_URL/private/api/v1/gems'`. The curl prints `{"error":"Version already exists","code":422}` and `HTTP 422`.
- **Unauthorized push** (`private-push-unauthorized`). Run `$S run $RUN push-bad-key 'GEM_HOST_API_KEY=wrong gem push --host $VERIFY_GEMSTASH_URL/private verify-private-0.1.0.gem'`. Exit `1`, stdout includes `Authorization key is invalid`.
- **Push to default source** (`private-upstream-only`). Run `$S run $RUN push-default 'curl -s -w "\nHTTP %{http_code}\n" -H "Authorization: verify-all-key" -H "Content-Type: application/octet-stream" --data-binary @verify-private-0.1.0.gem $VERIFY_GEMSTASH_URL/api/v1/gems'`. Stdout `Cannot add gem to an upstream server!` and `HTTP 403`.
- **Yank** (`private-yank`). Run `$S run $RUN yank 'RUBYGEMS_HOST=$VERIFY_GEMSTASH_URL/private gem yank --key verify_key verify-private --version 0.1.0'`. Exit `0`, stdout `Yanking gem from http://127.0.0.1:<port>/private...`.
- **Yank effect** (`private-yank`). Run `$S run $RUN after-yank 'curl -s $VERIFY_GEMSTASH_URL/private/specs.4.8.gz | ruby -rzlib -e "p Marshal.load(Zlib.gunzip(STDIN.read))"; curl -s -o /dev/null -w "gem HTTP %{http_code}\n" $VERIFY_GEMSTASH_URL/private/gems/verify-private-0.1.0.gem; gem install verify-private -v 0.1.0 --remote --clear-sources --source $VERIFY_GEMSTASH_URL/private --install-dir gems-after-yank --no-document'`. Stdout `[]` and `gem HTTP 403`, then stderr `Could not find a valid gem 'verify-private' (= 0.1.0)` and exit `2`. Run `$S state $RUN after-yank`. The `versions` row has `indexed: false`, and the stored gem file remains.
- **Rejected yanked push** (`private-yank-repush`). Run `$S run $RUN repush-yanked 'curl -s -o /dev/null -w "push HTTP %{http_code}\n" -H "Authorization: verify-all-key" -H "Content-Type: application/octet-stream" --data-binary @verify-private-0.1.0.gem $VERIFY_GEMSTASH_URL/private/api/v1/gems; curl -s -o /dev/null -w "gem HTTP %{http_code}\n" $VERIFY_GEMSTASH_URL/private/gems/verify-private-0.1.0.gem'`. The push is rejected (HTTP 500 due to the known logging failure) and the fetch is 403. Run `$S state $RUN after-repush-yanked`; the version remains unindexed and the stored gem and gemspec files remain unchanged.
- **Failed write and retry** (`private-push-retry`). Build a fresh gem with `$S make-gem $RUN retry-private 0.1.0`. Place a blocking file at the new resource's storage directory using `$S run $RUN block-write 'base="${VERIFY_GEMSTASH_LOG%/server.log}"; name=retry-private-0.1.0; digest=$(printf %s "$name" | md5sum | cut -d" " -f1); folder="$base/private/gems/r/e/t/retry_private_0_1_0-$digest"; mkdir -p "$(dirname "$folder")"; printf blocker > "$folder"'`. Push with `$S run $RUN failed-write 'curl -s -o /dev/null -w "HTTP %{http_code}\n" -H "Authorization: verify-all-key" -H "Content-Type: application/octet-stream" --data-binary @retry-private-0.1.0.gem $VERIFY_GEMSTASH_URL/private/api/v1/gems'`; expect HTTP 500. `$S state $RUN after-failed-write` must have no `retry-private` rubygem or version row, and no stored gem. Remove the blocker and retry with `$S run $RUN retry-write 'base="${VERIFY_GEMSTASH_LOG%/server.log}"; name=retry-private-0.1.0; digest=$(printf %s "$name" | md5sum | cut -d" " -f1); rm "$base/private/gems/r/e/t/retry_private_0_1_0-$digest"; curl -s -o /dev/null -w "push HTTP %{http_code}\n" -H "Authorization: verify-all-key" -H "Content-Type: application/octet-stream" --data-binary @retry-private-0.1.0.gem $VERIFY_GEMSTASH_URL/private/api/v1/gems; curl -s -o /dev/null -w "gem HTTP %{http_code}\n" $VERIFY_GEMSTASH_URL/private/gems/retry-private-0.1.0.gem'`. Both statuses are 200; `$S state $RUN after-retry-write` shows an indexed version and gem/spec files.

## Gotchas

- Without `--remote`, `gem install` run from `work/` installs the local `verify-private-0.1.0.gem` and reports success even after a yank. Proof from such a run is void.
- `gem push` and `gem yank` print only the `Pushing`/`Yanking` line on success. Exit codes, `state`, and installs are the proof.
- `/private` serves no compact index (`/private/versions` is 404, `/private/info/*` is 403). Bundler falls back to the dependency API, and `server.log` shows `Querying dependencies: verify-private`.
- Dependency lists are cached in memory for `cache_expiration`. Pushing another version and installing it within that window may resolve from the stale list.
- A yanked gem file stays on disk and its URL returns 403. Only `indexed` changes.
