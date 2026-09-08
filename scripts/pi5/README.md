# scripts/pi5/ — Raspberry Pi 5

The implementation for a **Raspberry Pi 5 running Raspberry Pi OS (Bookworm)**
or any recent Debian. For other hardware see [`../README.md`](../README.md) —
the design is shared, the scripts are not.

> ## ⚠️ Not yet verified on hardware
>
> These scripts were written against the same contract as the GL.iNet set and
> are syntax-checked, but **no Pi 5 was available to run them on**. The GL.iNet
> set is field-verified; this one is not.
>
> Nothing here writes anything until you run the installer, and the installer
> refuses to start if a prerequisite is missing. But treat the first run as
> bring-up, not deployment: work through [§8 Bring-up checklist](#8-bring-up-checklist)
> with a screen and keyboard attached, and let `tsvpn-audit.sh` tell you what is
> actually true rather than trusting this file.

Everything here is **deployment-generic**: identical on every Pi, in every
deployment. The only thing that makes a Pi a host or a remote, on your network
or someone else's, is one small JSON file: `/etc/tsvpn/node.json`.

## Contents

| | |
|---|---|
| [§1 What a Pi is good at here](#1-what-a-pi-is-good-at-here) | which role to use it for |
| [§2 Requirements](#2-requirements) | hardware, OS, packages |
| [§3 First-time setup](#3-first-time-setup) | the hands-on steps |
| [§4 Installing](#4-installing) | the one command |
| [§5 The node file](#5-the-node-file) | the only file unique to a Pi |
| [§6 What the scripts configure](#6-what-the-scripts-configure) | explained, so you can verify or rebuild by hand |
| [§7 Verification and troubleshooting](#7-verification-and-troubleshooting) | |
| [§8 Bring-up checklist](#8-bring-up-checklist) | **read this for the first Pi** |
| [§9 How this differs from the GL.iNet build](#9-how-this-differs-from-the-glinet-build) | |

---

## 1. What a Pi is good at here

**As a host** — the machine at the host site that is the exit node and subnet router — a
Pi 5 is an excellent fit and the simpler of the two roles. It sits on the host
site's LAN by ethernet, needs no access point, and Tailscale does most of the work
itself. If you only want one thing from this folder, make it this.

**As a remote** — the box at the far site that client devices join — a Pi works,
but it is doing a job a travel router does out of the box: running an access
point, handing out DHCP, NAT-ing its clients into the tunnel. Everything needed
is here, but there are more moving parts than the GL.iNet equivalent, and the
Pi's built-in radio is a modest AP. Prefer ethernet for the clients where you
can.

A Pi 5 has **one** ethernet port. On a remote that port is the *uplink*, so the
LAN side has to be the WiFi AP — or a USB ethernet adapter if you would rather
give clients a cable.

---

## 2. Requirements

- **Raspberry Pi 5** (a 4 will do; nothing here is 5-specific) running
  **Raspberry Pi OS Bookworm** or Debian 12+.
- **A wired uplink** for the remote role — the ethernet port goes to the site's
  network, exactly like the GL.iNet WAN port.
- Packages: `tailscale`, `dnsmasq`, and for the remote role `nftables`.
  `python3` is already present on Raspberry Pi OS and is what reads `node.json`.
  `traceroute` is optional and only used by one audit check.

```sh
curl -fsSL https://tailscale.com/install.sh | sh
sudo apt install -y dnsmasq nftables traceroute
```

The installer checks all of this and tells you exactly what is missing before it
changes anything.

> **Do not enable dnsmasq's DHCP on the host site's network by accident.** On a
> **host** Pi the config we write serves DNS on the tailnet only and explicitly
> disables DHCP there. On a **remote** Pi it serves DHCP on the AP interface
> only. Neither touches the host site's LAN — but if you already run dnsmasq for
> something else, look at `/etc/dnsmasq.d/tsvpn.conf` before starting it.

---

## 3. First-time setup

### 3.1 Tailscale account and tailnet

Sign up at [tailscale.com](https://tailscale.com) with the account that will own
the tunnel; the free tier is enough. Note the **tailnet name** and the
**MagicDNS suffix** (`something.ts.net`), shown under DNS.

Use an account you control long-term: every node's identity is tied to it.

### 3.2 Authenticate the Pi

```sh
sudo tailscale up
```

Open the URL it prints, sign in, approve the machine. Then give it a
recognisable name in the console — it is what you will look for when something
breaks. Confirm with `tailscale status`; it should show a `100.x` address.

**This is the one step no script can do.** Everything after it can be driven
over SSH from anywhere.

> Unlike the GL.iNet build, a Pi is not a sealed appliance: if you lose access
> you can put the SD card in another machine, or attach a screen. Re-authenticating
> is not the disaster it is on a router at someone else's house — but it still
> changes the node's `100.x` address, which every remote pins. See §5.

### 3.3 Tailnet settings that only exist in the console

Both are silent failures if skipped — nothing errors, the feature simply never
works. They are per-tailnet, not per-platform, so they are described once in the
[root README](../../README.md#4-tailnet-settings): **disable key expiry** on
every node, and add **`autoApprovers`** to the ACL for each address you intend
to reach.

### 3.4 Cable it in

**Host:** ethernet to the host site's network, as any other device.

**Remote:** ethernet to the *remote site's* network — that port is the uplink.
Client devices join the Pi's WiFi, not this cable.

### 3.5 Remote only — set up the access point

Run once, by hand. It asks for the SSID and passphrase interactively so they
never enter `node.json` or your repo:

```sh
sudo /etc/tsvpn/tsvpn-setup-ap.sh
```

Record the SSID and passphrase in a password manager. Losing them means
re-joining every client device by hand at the remote site.

---

## 4. Installing

From your own machine:

```sh
./tsvpn-push.sh <[user@]host> <node.json>
```

```sh
# a Pi on your desk
./tsvpn-push.sh pi@192.168.1.50 ../../networks/you@example.com/pi-host.json

# a Pi anywhere in the world, over the tunnel
./tsvpn-push.sh pi@100.64.0.3 ../../networks/you@example.com/pi-remote.json
```

It copies this folder and the JSON to the Pi and runs the installer there. It
uses `sudo`, so it may ask for that user's password.

Or copy the files across any way you like and run it on the Pi:

```sh
sudo sh /tmp/tsvpn-install/tsvpn-install.sh /tmp/tsvpn-install/node.json
```

**Idempotent** — re-run it any time: to change a setting, to repair, or after an
OS upgrade. It ends by auditing what it built and exits non-zero if anything
failed.

### What the installer does

1. checks prerequisites, and stops without changing anything if any are missing
2. copies the generic scripts to `/etc/tsvpn/`
3. installs your JSON as `/etc/tsvpn/node.json` (mode 600)
4. installs and enables the systemd units that re-apply everything at boot
5. runs the self-heal, which applies §6, then the audit

---

## 5. The node file

One small JSON per machine. Same schema as every other platform, plus a few
optional Pi-specific keys.

### Host

```json
{
  "deployment": "you@example.com",
  "node": "pi-host",
  "role": "host",
  "targets": ["192.0.2.10"]
}
```

### Remote

```json
{
  "deployment": "you@example.com",
  "node": "pi-remote",
  "role": "remote",
  "targets": ["192.0.2.10"],
  "exit_node": "100.64.0.1",

  "wan_iface": "eth0",
  "lan_iface": "wlan0",
  "lan_cidr": "192.168.9.1/24"
}
```

| Field | Who | Meaning |
|---|---|---|
| `deployment` | both | tailnet name. Cosmetic — it labels logs and audit output |
| `node` | both | this machine's name. Use the name you gave it in the Tailscale console |
| `role` | both | `host` or `remote`. **Exactly one host per deployment** |
| `targets` | both | bare IPv4 addresses at the host site to reach. No `/32`, no port. Same list on every node |
| `exit_node` | remote | the **host's `100.x` address**. Required |
| `dns_upstream` | remote | optional list. **Leave it out** — DNS then resolves through the host (design §3.5) |
| `wan_iface` | both | optional. The uplink. Default: whichever interface currently holds the non-tunnel default route |
| `lan_iface` | remote | optional. The interface clients join. Default `wlan0` |
| `lan_cidr` | remote | optional. The Pi's address on that interface. Default `192.168.9.1/24` |

`collide` is accepted for compatibility with the GL.iNet files but is not needed
here: this build pins every target to the tunnel unconditionally (§6.4), so a
colliding site LAN is handled whether or not you declare it.

Pick a `lan_cidr` that does **not** overlap the host site's network or the remote
site's. `192.168.9.0/24` is a deliberately unusual default.

### If you rebuild the host

It gets a **new `100.x`**. Update `exit_node` in every remote's JSON and re-run
the installer against each. Until you do, a remote keeps pinning the dead
address and blackholes all its internet — Tailscale failing closed rather than
leaking, but it looks like a dead line.

---

## 6. What the scripts configure

You never need to run any of this by hand — `tsvpn-selfheal.sh` applies all of
it and re-applies it at every boot. It is here so you can read what it did,
check it, or rebuild with nothing but a shell.

### 6.1 Both roles — forwarding

`net.ipv4.ip_forward=1`, persisted in `/etc/sysctl.d/99-tsvpn.conf`. A host
forwards exit-node and subnet-route traffic; a remote forwards its LAN into the
tunnel.

### 6.2 Host

```sh
tailscale set --advertise-exit-node --advertise-routes=<targets as /32s>
```

**No firewall or NAT rules of our own.** On Linux, `tailscaled` installs the SNAT
for exit-node egress and for advertised subnet routes itself, provided its
netfilter mode is left on. Adding a second masquerade is how you break return
traffic, not how you fix it. The audit checks `NoSNAT` has not been turned on.

DNS — `/etc/dnsmasq.d/tsvpn.conf`:

```
interface=tailscale0
bind-dynamic
no-dhcp-interface=tailscale0
```

Deliberately **no** `no-resolv` and **no** `server=`. The host forwards to
whatever `/etc/resolv.conf` points at — the same resolver every other device at
the host site uses — and serves those answers to the tailnet. A remote site then gets
exactly what a device sitting at the host site gets: same resolver, same egress, nothing
for a service to correlate (design §3.5).

### 6.3 Remote — nftables

Written to `/etc/tsvpn/nftables.conf` and loaded on every boot. Our own tables,
so we never fight Tailscale's rules and can flush and rebuild cleanly. A `drop`
in any table is final, which is what makes the kill-switch reliable regardless
of what else accepts.

```
table inet tsvpn {
    chain forward {
        iifname "wlan0" oifname "tailscale0" accept
        iifname "tailscale0" oifname "wlan0" ct state established,related accept
        oifname "eth0" drop          # KILL-SWITCH
    }
}
table ip tsvpn_nat {
    chain postrouting {
        oifname "tailscale0" masquerade    # REQUIRED — design §3.3
    }
}
```

The kill-switch drops **everything forwarded out the uplink**. Client traffic
goes through the tunnel or nowhere. Tailscale's own encrypted packets are
generated locally, so they take the OUTPUT path and are unaffected — the tunnel
itself is not cut. The `inet` family covers IPv6 too, which is how a v6 leak is
prevented while v4 looks perfect (design §3.6).

The masquerade is not optional. Without it, client traffic reaches the host
sourced from this site's private range, which the host routes to its own LAN and
drops. Symptom: the Pi works over the tunnel, nothing behind it does.

### 6.4 Remote — DNS, DHCP and target routing

`/etc/dnsmasq.d/tsvpn.conf` serves DHCP and DNS on the AP interface only, with
`no-resolv` and `server=<host tailnet IP>`, so clients resolve **through the
host** and can never fall back to this site's resolver. It fails closed: no
tunnel means no DNS, rather than a local answer that gives you away.

`tsvpn-fix-route.sh` pins each target to table 52 at policy priority 1000, ahead
of anything `--exit-node-allow-lan-access` installs for local subnets. Re-run at
boot and every 5 minutes by `tsvpn-fix-route.timer`. Harmless when there is no
collision, and already in place if the site is later swapped for a colliding one
(design §3.2).

### 6.5 Staying configured

| Unit | What |
|---|---|
| `tsvpn-selfheal.service` | runs the self-heal at boot. `Restart=on-failure` with a 60s delay, because boot races with `tailscaled` are common and self-correcting |
| `tsvpn-fix-route.timer` | re-checks target routing every 5 minutes (remote only) |

Log: `/var/log/tsvpn-selfheal.log`, truncated each run, so it is always "what
happened last time".

---

## 7. Verification and troubleshooting

### The one command that answers the question

```sh
sudo /etc/tsvpn/tsvpn-audit.sh
```

Read-only, so always safe. Checks every design requirement plus the
installation, prints `PASS`/`FAIL`/`WARN` per check, and **exits 1 if anything
failed**. Run it on every machine, and on a remote after any change to the host
— a remote's audit is the only thing that proves the path *through* the host.

### The one command that fixes almost everything

```sh
sudo /etc/tsvpn/tsvpn-selfheal.sh
```

Rebuilds everything from `node.json`, then audits itself. Idempotent. Try this
before diagnosing anything.

| Symptom | Likely cause | Fix |
|---|---|---|
| Everything dead at the remote site | exit node pinned but no longer advertising | fix the host; `sudo tailscale set --exit-node=` restores the site's own internet as a stopgap — **and drops the kill-switch and the host site's IP with it** |
| The Pi works, clients behind it don't | masquerade missing | §6.3; re-run the self-heal |
| **"No internet", but `ping 8.8.8.8` works** | dnsmasq has no upstream, or is not running | §6.4; `systemctl status dnsmasq` |
| Clients get an address but nothing resolves | dnsmasq bound to the wrong interface | check `interface=` in `/etc/dnsmasq.d/tsvpn.conf` matches `lan_iface` |
| Clients get no address at all | the AP is up but dnsmasq is not serving it | `sudo /etc/tsvpn/tsvpn-setup-ap.sh --show`, then re-run the self-heal |
| AP will not start | regulatory domain unset, or the radio cannot do AP mode | `sudo iw reg set <CC>`; `iw list \| grep -A10 'Supported interface modes'` |
| Video stalls, pages load | MTU/MSS | see design §3.4; on Linux Tailscale normally handles this — report it if you hit it |
| `dnsmasq` will not start | something else holds port 53 | `ss -lnup \| grep :53`; usually `systemd-resolved` with a stub listener |
| Target unreachable, internet fine | the site's LAN overlaps the target | `sudo /etc/tsvpn/tsvpn-fix-route.sh`, then check `ip rule` |

### The pinned-exit-node trap

A remote stores its exit node by **node ID**, independently of whether that node
still advertises `0.0.0.0/0`. If the host stops advertising, the remote keeps
routing at it and Tailscale **blackholes** rather than leaking. That looks like a
dead uplink but is a correctly configured remote pointed at a node that stopped
serving.

`tailscale status` still prints `… exit node` next to the peer — that means
"this is the node I selected", not "this node is offering". To tell them apart:

```sh
tailscale exit-node list                         # "no exit nodes found" = nobody offering
tailscale status --json | grep ExitNodeOption    # false = not offering
```

---

## 8. Bring-up checklist

For the first Pi, since none of this has been run on hardware yet. Do it with a
screen and keyboard attached, or at least on a machine you can physically reach.

**Host first** — it is the simpler role, and a remote cannot pass its audit
until the host works.

1. `sudo tailscale up`, confirm `tailscale status` shows a `100.x`.
2. Install prerequisites (§2). Run the installer; it should stop and name
   anything missing rather than half-configuring.
3. `sudo /etc/tsvpn/tsvpn-audit.sh` — expect all PASS.
4. From another tailnet device, check the host answers DNS:
   `dig @<host 100.x> github.com` — **if this fails, no client will ever
   resolve**, and it is the check most likely to need adjustment.
5. From another tailnet device, select the host as exit node and confirm your
   public IP becomes the host site's.

**Then a remote:**

6. Cable its ethernet to the site network. `sudo tailscale up`.
7. `sudo /etc/tsvpn/tsvpn-setup-ap.sh` — get the AP up **before** installing, so
   the interface exists and has its address.
8. Run the installer. Expect the kill-switch to cut the Pi's *clients* off the
   local uplink immediately — the Pi's own SSH stays up, since that is OUTPUT,
   not forwarded traffic. **Verify you can still SSH in before walking away.**
9. `sudo /etc/tsvpn/tsvpn-audit.sh` — expect all PASS.
10. Join a phone to the AP. Check it gets an address, resolves a name, and that
    `what is my IP` shows the **host site's** address.

Things most likely to need a fix on first contact, in order: the host's dnsmasq
binding to `tailscale0`; AP mode and the regulatory domain; whether Tailscale's
own netfilter rules interact with our `nftables` tables in a way the audit does
not anticipate.

---

## 9. How this differs from the GL.iNet build

Same design, same `node.json`, same audit contract. The mechanisms differ
because the platforms do.

| | GL.iNet | Pi 5 |
|---|---|---|
| Config system | `uci` | files in `/etc` |
| Firewall | fw3 / iptables via `uci` | our own `nftables` tables |
| Runs at boot | `/etc/rc.local` | systemd unit |
| Survives an update by | a full copy of `/etc/tsvpn` embedded in `rc.local` | nothing special — Debian does not wipe `/etc` |
| Host NAT | the `wan` zone's masquerade | `tailscaled` does it itself |
| LAN side | built in | an AP you set up once (§3.5) |
| Collision fix | only when `collide` is set | always on |

**The self-heal still matters here**, for a different reason. A GL.iNet firmware
update actively destroys the configuration; Debian does not. What this one
defends against is a reboot, an `nftables` reload, someone re-running
`tailscale up` without the flags, or a package reinstall replacing a config
file. Those are silent in exactly the same way.
