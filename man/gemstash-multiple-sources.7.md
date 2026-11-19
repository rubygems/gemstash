---
title: gemstash-multiple-sources
date: October 8, 2015
section: 7
...

# Multiple Gem Sources

Gemstash will stash from any amount of gem sources. By the end of this guide,
you will be able to bundle using multiple gem sources, all stashed within your
Gemstash server.

## Default Source

When you don't provide an explicit source (as with the [Quickstart
Guide][README_QUICKSTART]), your gems will be fetched from
https://rubygems.org. This default source is not set in stone. To change it, you
need only edit the Gemstash configuration found at `~/.gemstash/config.yml`:
```yaml
# ~/.gemstash/config.yml
---
:rubygems_url: https://my.gem-source.local
```

Make sure to restart your Gemstash server after changing the config:
```
$ gemstash stop
$ gemstash start
```

Once restarted, bundling against `http://localhost:9292` will fetch gems from
`https://my.gem-source.local`. If you had bundled before making these changes,
fear not; bundling with a different default gem source will store gems in a
separate location, ensuring different sources won't leak between each other.

## Bundling with Multiple Sources

Changing the default source won't help you if you need to bundle against
https://rubygems.org along with additional sources. If you need to bundle with
multiple gem sources, list each additional source in `:allowed_upstreams`
before upgrading. By default Gemstash permits only its configured
`:rubygems_url`; an unlisted source returns 403. Consider the following
`Gemfile`:

```ruby
# ./Gemfile
require "cgi"
source "http://localhost:9292"
gem "rubywarrior"

source "http://localhost:9292/upstream/#{CGI.escape("https://my.gem-source.local")}" do
  gem "my-gem"
end

source "http://localhost:9292/upstream/my-other.gem-source.local" do
  gem "my-other-gem"
end
```

Notice the `CGI.escape` call in the second source. This is important, as it
properly URL escapes the source URL so Gemstash knows what gem source you want.
The `/upstream` prefix tells Gemstash to use a gem source other than the default
source. You can now bundle with the additional source.

Notice that the third source doesn't need to be escaped.
This is because the `https://` is used by default when no scheme is set,
and the source URL does not contain any characters that need to be escaped.

## Authentication with Multiple Sources

You can use basic authentication or API keys on sources directly in Gemfile
or using ENV variables on the Gemstash instance.

Example `Gemfile`:
```ruby
# ./Gemfile
require "cgi"
source "http://localhost:9292"

source "http://localhost:9292/upstream/#{CGI.escape("user:password@my.gem-source.local")}" do
  gem "my-gem"
end

source "http://localhost:9292/upstream/#{CGI.escape("api_key@my-other.gem-source.local")}" do
  gem "my-other-gem"
end
```

If you set `GEMSTASH_<HOST>` ENV variable with your authentication information,
you can omit it from the `Gemfile`:

```ruby
# ./Gemfile
source "http://localhost:9292"

source "http://localhost:9292/upstream/my.gem-source.local" do
  gem "my-gem"
end
```

And run the Gemstash with the credentials set in an ENV variable:

```bash
GEMSTASH_MY__GEM___SOURCE__LOCAL=user:password gemstash start --config-file config.yml.erb
```

The name of the ENV variable is the uppercase version of the host name,
with all `.` characters replaced with `__`, all `-` with `___` and a `GEMSTASH_` prefix
(it uses the same syntax as [Bundler](https://bundler.io/v2.4/man/bundle-config.1.html#CREDENTIALS-FOR-GEM-SOURCES)).

Example: `my.gem-source.local` => `GEMSTASH_MY__GEM___SOURCE__LOCAL`

When credentials for a request are available from more than one place,
Gemstash uses the first of: the URL the client asked for, the matching
`:rubygems_url` or `:allowed_upstreams` entry, and the `GEMSTASH_<HOST>`
variable. Credentials in a URL are percent-decoded before use, while the
variable is used as written.

## Redirecting

Gemstash supports an alternate mode of specifying your gem sources. If you want
Gemstash to redirect Bundler to your given gem sources, then you can specify
your `Gemfile` like so:
```ruby
# ./Gemfile
require "cgi"
source "http://localhost:9292/redirect/#{CGI.escape("https://rubygems.org")}"
gem "rubywarrior"
```

Notice the `/redirect` prefix. This prefix tells Gemstash to redirect API calls
to the provided URL. Redirected calls like this will not be cached by Gemstash,
and gem files will not be stashed, even if they were previously cached or
stashed from the same gem source.

## Restricting Gem Sources

Gemstash allows only its configured `:rubygems_url` by default. Before
upgrading, list any additional Gemfile or mirror sources you use in the
Gemstash configuration so Bundler requests for them continue working:
```yaml
# ~/.gemstash/config.yml
---
:allowed_upstreams:
  - https://my.gem-source.local
  - https://my-other.gem-source.local
```

Gemstash will then only fetch from, or redirect to, the default source and the
listed gem sources. Requests for any other gem source are refused. See the
[`:allowed_upstreams` configuration key][ALLOWED_UPSTREAMS] for how gem sources
are compared.

[README_QUICKSTART]: ../readme.md#quickstart-guide
[ALLOWED_UPSTREAMS]: ./gemstash-configuration.5.md#allowed-upstreams
