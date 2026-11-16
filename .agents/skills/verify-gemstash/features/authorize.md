# API key authorization

A Gemstash admin uses `gemstash authorize` to create API keys for private gems, limit them to `push`, `yank`, or `fetch`, name them, list them, and remove them. The CLI writes to the same database the server reads.

## Sub-features

- `auth-generate` creates a random 32-hex key with all permissions when given no permissions and no `--key`.
- `auth-scoped` creates or updates a key limited to the listed permissions.
- `auth-named` attaches `--name` and shows it in `--list`.
- `auth-list` lists all keys, or one with `--name` or `--key`.
- `auth-remove` deletes a key with `--remove --key`.
- `auth-enforced` makes the server reject pushes from keys that are missing, invalid, or lack `push`.

## How to get to it (user POV)

- Run `gemstash authorize [push] [yank] [fetch] [--key KEY] [--name NAME]` in a terminal on the server host.
- Run `gemstash authorize --list [--name NAME | --key KEY]`.
- Run `gemstash authorize --remove --key KEY`.
- Use a key from `gem push` or `gem yank` through `--key <credentials name>` or `GEM_HOST_API_KEY`.

## Driving it with verify-gemstash

Preconditions:

- A run started with `$S launch` and a healthy `$S doctor $RUN`.
- `$S make-gem $RUN verify-auth 0.1.0`, `$S make-gem $RUN verify-auth 0.2.0`, and `$S make-gem $RUN verify-auth 0.3.0` have built three gem files.

- **Generate** (`auth-generate`, `auth-named`). Run `$S run $RUN auth-generate 'gemstash authorize --name generated'`. Stdout is `Your new key is: <32 hex chars>`.
- **Scoped key** (`auth-scoped`). Run `$S run $RUN auth-scoped 'gemstash authorize yank fetch --key verify-yank-fetch --name limited'`. Exit `0`.
- **List** (`auth-list`, `auth-named`). Run `$S run $RUN auth-list 'gemstash authorize --list'`. The table shows `generated` with `all` and `limited` / `verify-yank-fetch` with `yank,fetch`.
- **List one** (`auth-list`). Run `$S run $RUN auth-list-one 'gemstash authorize --list --name limited'`. Only the `limited` row appears.
- **Push denied without push** (`auth-enforced`). Run `$S run $RUN push-no-perm 'GEM_HOST_API_KEY=verify-yank-fetch gem push --host $VERIFY_GEMSTASH_URL/private verify-auth-0.1.0.gem'`. Exit `1`, stdout includes `Authorization key doesn't have push access`.
- **Push denied with unknown key** (`auth-enforced`). Run `$S run $RUN push-bad-key 'GEM_HOST_API_KEY=wrong gem push --host $VERIFY_GEMSTASH_URL/private verify-auth-0.1.0.gem'`. Exit `1`, stdout includes `Authorization key is invalid`.
- **Upgrade before first use** (`auth-scoped`, `auth-enforced`). Run `$S run $RUN auth-upgrade 'gemstash authorize fetch --key verify-upgrade && gemstash authorize push --key verify-upgrade && gemstash authorize --list --key verify-upgrade'`. Permissions read `push`. Then run `$S run $RUN push-upgraded 'GEM_HOST_API_KEY=verify-upgrade gem push --host $VERIFY_GEMSTASH_URL/private verify-auth-0.1.0.gem'`. Exit `0`.
- **Remove** (`auth-remove`). Run `$S run $RUN auth-revoke-create 'gemstash authorize push --key verify-revoke'` and `$S run $RUN push-before-revoke 'GEM_HOST_API_KEY=verify-revoke gem push --host $VERIFY_GEMSTASH_URL/private verify-auth-0.2.0.gem'` (exit `0`). Then run `$S run $RUN auth-remove 'gemstash authorize --remove --key verify-revoke'` and `$S state $RUN after-remove`. The `authorizations` table has no `verify-revoke` row.
- **Removal enforced on the server** (`auth-enforced`). Run `$S run $RUN push-after-revoke 'GEM_HOST_API_KEY=verify-revoke gem push --host $VERIFY_GEMSTASH_URL/private verify-auth-0.3.0.gem'`. Expected: exit `1` with `Authorization key is invalid`, and no `0.3.0` row in a following `$S state $RUN after-revoked-push`. See Gotchas for the observed result.

## Gotchas

- Known failure on 599d04a with the default `cache_type: memory`: the server caches each authorization it has looked up for `cache_expiration` (1800 s). `gemstash authorize` runs in its own process, so its cache invalidation never reaches the server. A key the server has already used keeps its old permissions after an upgrade, downgrade, or `--remove` until expiry or restart. Observed: after `--remove`, `verify-revoke` still pushed `verify-auth-0.3.0` (exit `0`, `indexed: true` row), and in a protected-fetch run a removed `fetch` key still downloaded a private gem with HTTP 200. Report this as a failure. Do not restart the server to make the step pass. With a cache the CLI and server share, the step passes: on postgres with `cache_type: redis` and on mysql2 with `cache_type: memcached`, `push-after-revoke` exited `1` with `Authorization key is invalid` and stored no `0.3.0` row. So the **Removal enforced on the server** step is a known failure only on a memory-cache run.
- Each key above is first used by the server after its last change, except `verify-revoke`, which is used before removal on purpose. Reusing `verify-yank-fetch` after changing it would hit the stale cache and muddle the earlier steps.
- `--remove` prints nothing on success and exits `0` even for an unknown key. Confirm with `--list` or `state`.
- The CLI talks to the database directly. A successful `authorize` proves nothing about the server; the push or fetch step does.
- `authorize` with no permissions stores `all`, which includes permissions added in later versions.
