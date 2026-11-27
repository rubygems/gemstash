# Gemstash Threat Model

This document describes what Gemstash protects, whom it trusts, and where that
trust ends. It is meant for people who run a Gemstash server and for people
who change its code. It also lists the weaknesses that are known and not yet
closed, because an operator can only make up for a gap they know about.

Two things are worth knowing before anything else:

- Gems are programs. Whoever controls what a Gemstash server hands out
  controls code that runs on developer machines, in CI, and in production.
- Out of the box, Gemstash only fetches from its default gem source and limits
  the size and duration of each download, but it listens on every network
  interface over plain HTTP, and anyone who can connect can download private
  gems. What to change is listed in the
  [deployment checklist](#deployment-checklist).

## Overview

Gemstash is an HTTP server that sits between RubyGems clients, such as Bundler
and `gem`, and gem sources. It does two jobs:

- It **caches** the gems, gemspecs, and dependency data that it fetches from
  an *upstream* gem source. That is https://rubygems.org unless the
  configuration says otherwise, or another gem source that the configuration
  allows and a client names.
- It **hosts private gems** that are pushed to it with an API key.

```
 Bundler, gem          +-------------------------------+
 (laptops, CI,   HTTP  |           Gemstash            |  HTTPS or HTTP
  deploys)     ------> |        Puma + Sinatra         | ---------------> upstream
                       +-----+-----------+----------+--+                  gem sources
                             |           |          |
                         base path    database    cache
```

- The **base path** (`~/.gemstash` by default) holds the stored gems, the log,
  the SQLite database if that is used, and by default the configuration file.
- The **database** (SQLite, PostgreSQL, or MySQL) holds the metadata of private
  gems, the API keys, and a record of what is stored.
- The **cache** (in memory, Memcached, or Redis) holds dependency data and
  API key lookups for `:cache_expiration` seconds, 30 minutes by default.

## What Is Worth Protecting

1. The **integrity** of the gems and gem metadata that clients receive.
2. The **confidentiality** of private gems, and of gems from upstreams that
   need credentials.
3. **Secrets**: API keys, upstream credentials, and the connection settings of
   the database and cache.
4. The **network position** of the server. It can usually reach hosts that its
   clients cannot, such as its own loopback interface, the internal network,
   and the metadata address of a cloud provider.
5. **Availability**. Installs, builds, and deploys stop when the server does.

## Who Is Trusted

| Who | Trusted with | Notes |
| --- | --- | --- |
| Operator | Everything | Controls the configuration, the environment, the base path, and the `gemstash` command. A configuration file ending in `.erb` is run as Ruby when Gemstash starts. |
| Client: anyone who can connect | Reading everything that is not a protected private gem | Needs no credentials. Chooses among the gem sources the configuration allows, which by default is only `:rubygems_url`. |
| Holder of an API key | What the key permits: `push`, `yank`, `fetch` | A `push` key publishes code to everyone who installs private gems from this server. |
| Default upstream (`:rubygems_url`) | The content of every gem it serves | Gemstash adds no checks of its own. |
| Allowed upstreams (`:allowed_upstreams`) | The same, for clients that use them | None by default. `"*"` allows any gem source a client names. |
| Redirect targets (`:allowed_redirects`) | The content of the downloads that are redirected to them | Clients cannot name them as gem sources. |
| Database, cache, base path | Everything | Gemstash believes what it reads from them. |
| The network | Nothing | Gemstash serves plain HTTP unless told otherwise. |

Clients are not all people running Bundler. A web page opened by someone on
the same network can make their browser send requests to Gemstash, and since
Gemstash does not check the `Host` header, such a page may also be able to
read the answers (DNS rebinding). "Only reachable from the office network" is
therefore a weaker guarantee than it sounds.

## Entry Points

| Request | Key needed | What happens |
| --- | --- | --- |
| `GET /...` | None | Served from the default upstream, or from the gem source named in the `X-Gemfile-Source` header, which Bundler sends when Gemstash is used as a mirror. |
| `GET /upstream/<url>/...` | None | Served from the gem source in the path. |
| `GET /redirect/<url>/...` | None | Redirected to the gem source in the path. Nothing is fetched or stored. |
| `GET /private/gems/<file>`, `/private/quick/Marshal.4.8/<file>`, `/private/*specs.4.8.gz`, `/private/api/v1/dependencies`, `.../dependencies.json` | None, or `fetch` with `:protected_fetch` | Private gems, their gemspecs, the indexes of them, and the versions and dependencies of the gems that are named. |
| `POST /private/api/v1/gems` | `push` | Adds a private gem. The key is checked before the body is read. |
| `DELETE /private/api/v1/gems/yank` | `yank` | Yanks a version of a private gem. |
| `GET /health`, `/health/<check>` | None | Health checks. All but `heartbeat` write to the base path or query the database. |

A gem source that is not allowed is refused with a `403` on the first three
([rule 2](#rules-the-code-follows)).

For an upstream, Gemstash handles the paths of the gem API differently:

- Gems (`/gems/<file>`) and gemspecs (`/quick/Marshal.4.8/<file>`) are fetched
  once and then **stored for good**.
- Dependency data (`/api/v1/dependencies`) is fetched and **cached** until it
  expires.
- Spec indexes (`/specs.4.8.gz` and its variants) are fetched on every request
  and **passed through**.
- The compact index (`/versions`, `/info/<name>`, `/names`), `/`, and
  `/fetch/actual/gem/<file>` are not served at all. The client is
  **redirected** to the upstream.

The other inputs are the responses of upstreams, the configuration file and
environment, the `gemstash` command, and whatever is in the database, the
cache, and the base path.

## Rules the Code Follows

Changes to Gemstash should keep these true. A change that cannot is a change
to this threat model, and should say so.

1. **Data from clients and upstreams is never unmarshalled or evaluated.**
   Gems, gemspecs, and spec indexes from an upstream are stored and served byte
   for byte and never parsed. Dependency data is requested as JSON, must have
   the shape of the dependency API, and is cut down to the known fields of the
   gems that were asked for. The Marshal form of the dependency data, which
   Gemstash sends to clients that ask for it, is built from that checked data.
   RuboCop (`Security/MarshalLoad`) keeps `Marshal.load` out of `lib/`.
2. **The gem source of a request is checked in one place, before it is used.**
   `RedirectSource#upstream` compares it with `:rubygems_url` and
   `:allowed_upstreams`. A refused gem source is neither sent a request nor
   redirected to, and the client gets a `403` instead.
3. **Every request to an upstream goes through `Gemstash::HTTPClient#get`.**
   It sets the timeouts, ends a fetch that takes longer than
   `:max_upstream_duration` in total or that delivers less than 1 KiB per
   second once `:fetch_timeout` has passed, and stops a download that grows
   past `:max_upstream_bytes`, or whose headers grow past 64 KiB, while it is
   still arriving.
4. **A redirect from an upstream is only followed to a place the operator
   listed.** `HTTPClient.refuse_redirect` checks each one with
   `Gemstash::Upstream.allowed_redirect?` against `:rubygems_url`,
   `:allowed_upstreams`, and `:allowed_redirects`. A redirect from `https` to
   `http`, or to a URL with credentials, is never followed, and the
   credentials Gemstash sent are dropped when a redirect leads to another
   scheme, host, or port.
5. **An upstream does not choose how its content is presented.** Upstream
   content is always served as `application/octet-stream`, and Sinatra adds
   `X-Content-Type-Options: nosniff`. Error responses consist of fixed text,
   never of text taken from the request or from an upstream.
6. **Names from requests do not become paths unchecked.** The id of an upstream
   gem or gemspec must consist of `A-Z`, `a-z`, `0-9`, `.`, `_`, and `-`, and
   end with the extension of its route, `.gem` or `.gemspec.rz`, before it is
   used in a URL (`RedirectSource::VALID_ID` and `#valid_file?`). The name in
   `/info/<name>` is checked the same way, without an extension.
   `Gemstash::Resource` replaces all but letters, digits, and `_` before a
   name is used on disk, and private gems are found through the database.
7. **Changing private gems needs an API key with the matching permission.**
   The key is checked before the body of a push is read. Keys are managed with
   `gemstash authorize` on the server. There is no HTTP interface for it.
8. **The database decides which versions of private gems exist.** A push is
   checked against the database before anything is stored. A version that
   exists or was yanked cannot be pushed again, and a push that fails leaves
   neither a row nor a file behind. A private gem is only served while both
   the database and the store list it as indexed.
9. **Stored gems are kept apart by gem source.** Each upstream URL,
   credentials included, has its own directory and its own dependency cache,
   and private gems have theirs.
10. **Upstream credentials stay out of what Gemstash keeps.** They are not
    written to the log, the database, a cache key, or the metadata of a
    stored gem. Credentials from the configuration or the environment are
    only sent to the host they are for, and never put into a redirect to a
    client.

## Threats

### Running Someone Else's Code on the Server

The usual way to lose a server like this one is to deserialize data that an
outsider controls. This is what is parsed, and how:

| Data | From | Parsed with |
| --- | --- | --- |
| Gems, gemspecs, spec indexes | Upstream | Not parsed |
| Dependency data | Upstream | JSON, then checked for its shape |
| A pushed gem | Client with a `push` key | RubyGems (`Gem::Package`), which reads the metadata with its restricted YAML loader |
| Cached values | Redis | YAML, limited to the classes Gemstash stores |
| Cached values | Memcached | Marshal, which is what the Dalli client uses by default |
| Metadata of stored gems | Base path | YAML, limited to plain data and symbols |
| Configuration | Operator | YAML, after ERB if the file ends in `.erb` |

Two things follow. A Memcached server is as trusted as the Gemstash process
itself ([gap 7](#known-gaps)). And an upstream that offers its dependency data
only in Marshal format cannot provide it through Gemstash: the request fails,
and Bundler falls back to the full index of that gem source.

### Using the Server to Reach Other Hosts

A client can choose the gem source of a request, with an `/upstream/<url>` or
`/redirect/<url>` prefix or with the `X-Gemfile-Source` header. Gemstash then
sends a `GET` request from where it stands in the network and hands the
answer back. Whoever chooses the gem source therefore chooses where the
server sends requests.

`:allowed_upstreams` limits that choice. A gem source is allowed when its
scheme, host, port, and path are those of `:rubygems_url` or of an entry, and
anything else is refused before a connection is made. The list is empty by
default, which allows only `:rubygems_url`, and `gemstash start` refuses to
start with an entry it cannot use. Within an allowed gem source, a client only
chooses which gems, gemspecs, and dependencies are fetched, and their names
are checked ([rule 6](#rules-the-code-follows)). Redirects from an upstream
are held to the same gem sources and to `:allowed_redirects`
([rule 4](#rules-the-code-follows)).

Setting `:allowed_upstreams` to `"*"` allows any gem source a client names,
and any redirect target but those that rule 4 always refuses. A Gemstash
server configured this way is a proxy to everything it can reach, for
everyone who can reach it. `:ignore_gemfile_source` is no substitute for the
list. It only turns the header off, and the `/upstream/` and `/redirect/`
prefixes keep working.

### Redirects

*From an upstream.* Gemstash follows up to three redirects when it fetches.
Unless `:allowed_upstreams` is `"*"`, each must lead to `:rubygems_url`, an
allowed upstream, or an entry of `:allowed_redirects`: its scheme, host, and
port must be those of the entry, and its path must be the path of the entry or
lie below it. An `http` entry also accepts the same host over `https`. A
redirect from `https` to `http`, or to a URL with credentials, is never
followed, and the credentials Gemstash sent are dropped when a redirect leads
to another scheme, host, or port. The path of an entry only confines redirects
as far as the server behind it keeps its paths apart, so treat a host that
serves several gem sources as a whole.

*To a client.* `/redirect/<url>/...`, `/`, `/fetch/actual/gem/<file>`, and the
compact index paths answer with a redirect to the gem source of the request.
Since that gem source has to be allowed, these redirects only lead to gem
sources the operator chose. While `:allowed_upstreams` is `"*"`, anyone can
build a URL on the Gemstash server that redirects to a host of their choice.
Credentials from the configuration are never put into such a redirect.
Credentials that a client put into the URL of its gem source are, and the
redirect is then sent with `Cache-Control: no-store`.

### Tampering With What Clients Install

Gemstash does not verify gems. It checks no checksum and no signature, neither
when it fetches a gem nor when it serves one. The integrity of a stored gem
rests on the upstream, on TLS to the upstream, and on the base path.

- Stored gems and gemspecs are **never refreshed**
  ([gap 2](#known-gaps)). Dependency data expires with the cache.
- A client can only add to the store of a gem source it is allowed to use,
  and only what that gem source serves for the file name of a gem or
  gemspec.
- A gem source cannot add dependency data for gems that were not asked for.
- A version of a private gem cannot be pushed twice, and a yanked version
  cannot be pushed again ([rule 8](#rules-the-code-follows)).
- Gemstash never mixes private gems with those of an upstream. Whether a gem
  name resolves to the private or the public gem is decided by the `Gemfile`,
  so private gems belong in a `source` block of their own.

Clients have a defense of their own. Bundler compares each gem it downloads
with the checksum in the compact index, which comes straight from the upstream
because Gemstash only redirects to it. A client that resolves through the
dependency API or the full index has no such checksum, and that is always the
case for private gems. Checksums in the lockfile
(`bundle lock --add-checksums`) cover both.

### Content That a Browser Would Run

Gems and indexes are downloaded by tools, but the same URLs can be opened in a
browser. Since an upstream is not necessarily trustworthy, its content is
never served with the content type it asked for
([rule 5](#rules-the-code-follows)).

### Exhausting the Server

| Resource | Limited by | Not limited |
| --- | --- | --- |
| Memory | `:max_upstream_bytes` for each response of an upstream (64 MiB by default), 64 KiB for its headers, and `:cache_max_size` entries in the memory cache | The total ([gap 1](#known-gaps)), and the size of a pushed gem ([gap 5](#known-gaps)) |
| Disk | Log rotation (two files of 10 MB) | Stored gems ([gap 1](#known-gaps)), and request bodies while Puma receives them ([gap 5](#known-gaps)) |
| Request threads | `:open_timeout` and `:fetch_timeout` for each wait, `:max_upstream_duration` for a whole fetch (300 seconds by default), at least 1 KiB per second once `:fetch_timeout` has passed, and 200 gems for each dependency request | The number of requests |

Gemstash does not limit the rate of requests.

### Reading Private Gems

Fetching private gems, their gemspecs, the indexes of them, and their
dependency data needs no key unless `:protected_fetch` is set
([gap 4](#known-gaps)). Keys are 128 random bits when `gemstash authorize`
generates them, and are sent either as the user name of HTTP Basic
authentication or as the whole `Authorization` header, which is what
`gem push` does. Without TLS they cross the network in the clear.

Cached gems have no access control at all. This includes gems from upstreams
that Gemstash logs in to ([gap 3](#known-gaps)).

### Secrets

Gemstash keeps API keys as they are, in more places than the database
([gap 6](#known-gaps)). Credentials for an upstream come from the URL a client
asks for, from the matching `:rubygems_url` or `:allowed_upstreams` entry, or
from a `GEMSTASH_<HOST>` environment variable, in that order. Gemstash passes
them on to the upstream as HTTP Basic authentication, and keeps them out of
the log, the database, the cache, and the store
([rule 10](#rules-the-code-follows)).

### The Network

- **Clients to Gemstash.** Plain HTTP on every interface by default
  ([gap 8](#known-gaps)). Someone on the path can read API keys and replace
  gems, indexes, and the redirect to the compact index.
- **Gemstash to upstreams.** `https` is used when a gem source is named without
  a scheme, and certificates are verified against the trust store of the
  system. An `http` gem source is only used when it is `:rubygems_url` or
  listed in `:allowed_upstreams`, or when that list is `"*"`, and a redirect
  from `https` to `http` is never followed.
- **Gemstash to the database and cache.** As configured by the operator.

## Known Gaps

These are ordered roughly by how much they matter on a server with the default
configuration. Each entry says what to do about it today.

1. **Resources are limited for each request, not in total.** A response from
   an upstream is held in memory while it is handled, and can take about twice
   `:max_upstream_bytes` (64 MiB by default) while its buffers grow. Memory use
   can reach that for every request thread at once: `:puma_threads`, 16 by
   default, in each of the `:puma_workers` processes, which is about 2 GiB with
   the defaults. Each fetch can hold its request thread for up to
   `:max_upstream_duration`, 300 seconds by default. Stored gems are never
   evicted, and nothing limits their number or size, so anyone who can connect
   can have the server store every gem that its gem sources offer. Each also
   adds rows to the database. *Today:* keep `:max_upstream_bytes` just above
   the largest gem you need, give the server memory to match, keep the base
   path on a volume of its own, and watch its free space. *To close it:* a size
   limit with eviction, and writing responses to disk as they arrive.

2. **Stored gems are not verified and never refreshed.** A version that was
   yanked upstream stays available to anyone who asks for its file, and a bad
   entry stays bad. *Today:* add checksums to lockfiles, and delete entries
   from the base path when a version must go. *To close it:* compare stored
   gems with the checksums of the upstream.

3. **Cached gems have no access control.** Everything Gemstash fetches with
   credentials from the configuration or the environment is available to
   every client. A gem source whose `:allowed_upstreams` entry, or
   `:rubygems_url`, carries credentials can therefore be read by anyone who
   can reach Gemstash. `GEMSTASH_<HOST>` credentials are chosen by host name
   alone, and are sent to every allowed gem source on that host, whatever its
   scheme, port, or path. With `:allowed_upstreams` set to `"*"`, that is any
   port and path a client names, over plain `http` as well. Gems fetched with
   credentials that a client supplied itself are kept apart, and are only
   served to requests that carry the same credentials. *Today:* allow only the
   gem sources you need, and limit who can reach the server.

4. **Private gems can be read without a key by default.** Without
   `:protected_fetch`, anyone who can connect can download private gems and
   their gemspecs, and list their versions and dependencies. With it, all of
   these need a key with the `fetch` permission. [SECURITY.md](SECURITY.md)
   treats this default as documented behavior, not as a vulnerability.
   *Today:* set `:protected_fetch` if private gems are confidential.

5. **The size of a push is not limited.** Once its key has been checked, a
   push is read into memory in full, however large it is. Like the body of any
   request, it has already been received by Puma by then, in memory or in a
   temporary file. *Today:* limit the size of requests in a reverse proxy.

6. **API keys are stored and logged as they are.** API keys are stored
   unhashed in the database, are written to the log when they are created,
   changed, or removed, are used as keys in the cache, and are shown by
   `gemstash authorize --list`. The log, the database, stored gems, and a
   configuration file written by `gemstash setup` are created with the default
   permissions of the process, which usually lets other local users read them.
   *Today:* restrict the base path and the configuration file to the user
   Gemstash runs as, and treat logs and backups as secrets.

7. **Memcached values are unmarshalled.** With `:cache_type: memcached`,
   anyone who can write to the Memcached server can run code in Gemstash and
   grant any API key any permission. With Redis they cannot run code, but they
   can still forge keys and dependency data. *Today:* make sure only Gemstash
   can reach the cache server.

8. **The server listens on every interface without TLS, and accepts any
   `Host`.** `:bind` defaults to `tcp://0.0.0.0:9292`. Requests are not rate
   limited, and `/health` writes to the base path and queries the database on
   every request. *Today:* bind to the loopback interface and put a reverse
   proxy with TLS in front.

9. **The log does not say why an upstream request failed.** A refused gem
   source or redirect is logged with a warning that starts with `Refusing`.
   Any other failed request to an upstream is logged as
   `Upstream request failed (HTTP <status>)`, so a download that was stopped
   for its size cannot be told apart from one that timed out or sent data
   Gemstash could not use. *Today:* watch for these warnings, and for `403`
   and `502` responses in the request lines.

## Deployment Checklist

The defaults already allow only `:rubygems_url`, and limit each download to
64 MiB and 300 seconds. What else to change depends on where the server runs.
For a server behind a reverse proxy on the same machine, start from:

```yaml
# ~/.gemstash/config.yml
---
:bind: tcp://127.0.0.1:9292
:protected_fetch: true
```

- [ ] List the other gem sources of your `Gemfile`s and mirror settings in
      `:allowed_upstreams`, and nothing else. Do not set it to `"*"` on a
      server that anyone you do not trust can reach.
- [ ] If a gem source redirects its downloads to another host, such as a CDN,
      list that host in `:allowed_redirects`, with a path if you can.
- [ ] Use `https` for `:rubygems_url` and for every allowed upstream and
      redirect target.
- [ ] Keep `:max_upstream_bytes` just above the largest gem you need. In the
      worst case the server holds about twice that for every request thread
      at once.
- [ ] Keep the server from connecting to anything but its gem sources, with a
      firewall or an outbound proxy. The HTTP client honors `http_proxy` and
      `https_proxy`. This is what still stands between Gemstash and your
      internal network if an allowed host name resolves to an internal
      address, or if `:allowed_upstreams` is ever set to `"*"`.
- [ ] Bind to `127.0.0.1` and put a reverse proxy in front that terminates
      TLS, accepts only your host name, and limits the size of requests. If the
      proxy caches, make the `X-Gemfile-Source` header part of its cache key,
      since Gemstash does not send a `Vary` header for it.
- [ ] Set `:protected_fetch` if private gems are confidential.
- [ ] Let `gemstash authorize` generate keys, give each key only the
      permissions it needs, and keep `push` keys away from machines that only
      install.
- [ ] Run Gemstash as a user of its own, with a base path and a configuration
      file that only this user can read and write.
- [ ] Keep Memcached, Redis, and the database reachable by Gemstash alone.
- [ ] Put the base path on a volume of its own and monitor its free space.
- [ ] Watch the log for warnings that start with `Refusing`. They show clients
      asking for gem sources, or gem sources redirecting to places, that you
      did not list.
- [ ] On the clients, add checksums to lockfiles
      (`bundle lock --add-checksums`) and name private gems in a `source`
      block.
- [ ] Keep Gemstash and its dependencies up to date.

## Out of Scope

[SECURITY.md](SECURITY.md) says how to report a vulnerability, and what is not
treated as one. This document does not cover:

- A gem source that serves malicious gems, or one whose TLS is broken.
  Gemstash passes on what it is given.
- What a gem does once it is installed.
- An attacker who already controls the server, its user account, the
  database, or the cache.
- Vulnerabilities in Puma, Rack, Sinatra, Faraday, or Ruby itself.
- Floods of requests. Gemstash has no defense of its own against volume.

## Keeping This Document Current

Update this document in the same change that does any of the following:

- adds or changes a route, or what a route needs in order to be authorized
- parses anything that came from a client, an upstream, or the cache
- sends a request to a new place, or builds a URL or a path from new input
- adds a configuration key that changes who is trusted, or changes the
  default of one
- closes one of the [known gaps](#known-gaps), or finds a new one
