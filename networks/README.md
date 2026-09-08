# networks/

One folder per tailnet, one small JSON file per router inside it:

```
networks/
  you@example.com/
    my-host.json          role: host    (exactly one)
    my-remote.json        role: remote
    another-remote.json   role: remote
    README.md             optional: your own notes for this deployment
```

Those folders are **git-ignored** — they hold real addresses, node IDs, SSIDs
and public IPs, so they never leave your machine. The two example files here
and this README are committed.

## Start here

Copy an example and edit it:

```sh
mkdir -p "networks/you@example.com"
cp networks/example-host.json   "networks/you@example.com/my-host.json"
cp networks/example-remote.json "networks/you@example.com/my-remote.json"
```

Then install it onto the router:

```sh
./scripts/glinet/tsvpn-push.sh 192.168.8.1 "networks/you@example.com/my-host.json"
```

**Field-by-field reference:** [`../scripts/glinet/README.md`](../scripts/glinet/README.md)

## What goes in a node file

Only what configures the machine — role, the addresses to reach at the host site, and
(for a remote) the host's tailnet address. It should stay small enough to write
by hand.

Everything else a human wants to remember — topology, why a particular device is
awkward, the tailnet ACL, which SSIDs are live, site quirks — belongs in a
`README.md` alongside them. No script reads it, so it can be whatever helps you.

## Credentials do not belong here

Not the GL.iNet admin password, not WiFi keys. Use a password manager. Losing an
AP key means re-joining every client device by hand at the remote site, so keep
it somewhere you trust and can reach.
