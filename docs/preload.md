# Preloading Gems

You can force a preloading all or the latest gems that are registered in
rubygems. This can be handy particularly if you are working with a bad
connection, or if you plan to be offline for a while.

Being offline and taking your own personal rubygems with you can be achieved
with the *Sherpa mode* (not supported yet)

The preloading process has to be executed while the Gemstash server is running.

Example:

```
$ gemstash preload --limit=100
Preloading all the gems is an extremely heavy and long running process
You can expect that this will take around 24hs and use over 100G of disk
Are you sure you want to do this? yes
100/601553
Done
```

Check the [reference](reference.md#preload) for more options.
