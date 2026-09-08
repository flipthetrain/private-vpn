# scripts/macos/ — macOS

The implementation for **macOS running the standalone Tailscale build**. For
other hardware see [`../README.md`](../README.md) — the design is shared, the
scripts are not.

> ## ⚠️ Not yet run on a Mac
>
> The shell parses and the config reader was exercised, but **no Mac was
> available**, so nothing here has been executed on the platform it targets.
> That makes it the least proven set in this repo.
>
> **You can start testing before joining the tailnet.** `tsvpn-audit.sh` is
> read-only and safe to run on a Mac that has never seen Tailscale: the
> Tailscale checks will fail and everything else — the config reader, the
> macOS version probe, forwarding, pf, name resolution — still reports
> honestly. That is the cheapest way to shake out script bugs first.

## Contents

| | |
|---|---|
| [§1 What a Mac is good for here](#1-what-a-mac-is-good-for-here) | |
| [§2 Requirements](#2-requirements) | **the App Store build will not work** |
| [§3 First-time setup](#3-first-time-setup) | |
| [§4 Installing](#4-installing) | |
| [§5 DNS](#5-dns) | |
| [§6 What the scripts configure](#6-what-the-scripts-configure) | including the part macOS needs that Linux does not |
| [§7 Verification and troubleshooting](#7-verification-and-troubleshooting) | |
| [§8 Bring-up checklist](#8-bring-up-checklist) | **read this first** |
| [§9 Why there is no remote role](#9-why-there-is-no-remote-role) | |

---

## 1. What a Mac is good for here

**As a host — yes**, and a Mac mini that lives on a shelf is close to ideal:
always on, wired, quiet, and already trusted on your network. You get your
household IP while travelling and can reach devices at the host site from a
laptop or phone.

The caveat is the one every general-purpose computer has: it sleeps, it reboots
for updates, and someone might close the lid. A host that is asleep is a host
that is down, and every remote depending on it goes dark. Laptops make poor
hosts for that reason. If anyone else relies on this deployment, put the host on
[`../glinet/`](../glinet/) or [`../rasp-pi/`](../rasp-pi/) hardware.

**As a remote — no.** Not supported; the scripts refuse it. See §9.

## 2. Requirements

- **macOS 12 or later** (nothing here is version-specific; older will likely
  work).
- **The standalone Tailscale build**, signed in:
  [tailscale.com/download/mac](https://tailscale.com/download/mac) → the `.pkg`.

> ### The Mac App Store build cannot do this job
>
> It is sandboxed, and **cannot advertise subnet routes or act as an exit
> node** — the two things a host exists to do. No amount of configuration
> changes that.
>
> Both the installer and the audit detect it (by the `_MASReceipt` that only
> the App Store build carries) and refuse rather than producing a host that
> silently advertises nothing. If you have it, replace it with the standalone
> `.pkg`; your node keeps its identity.

Nothing else to install. The scripts use `plutil`, `pfctl`, `sysctl`,
`launchctl` and `route`, all of which ship with macOS. In particular they do
**not** need `python3`, which has not shipped with macOS since 12.3 and exists
only if the Xcode command line tools are installed.

## 3. First-time setup

1. **Tailscale account and tailnet** — see the
   [root README](../../README.md#4-tailnet-settings).
2. **Install the standalone build and sign in.** Give the Mac a recognisable
   name in the console. This is the one step no script can do.
3. **Console settings**: disable key expiry, and add `autoApprovers` for each
   address you intend to reach. Both fail silently if skipped.
4. **Stop it sleeping**, or accept that the host goes down when it does:

   ```sh
   sudo pmset -a sleep 0 disksleep 0
   sudo pmset -a womp 1        # wake on network access
   ```

   On a laptop, `pmset -b` settings still apply on battery — a lid-closed
   MacBook is not a host.
5. **Optional, for remote administration**: System Settings → General →
   Sharing → **Remote Login**. Needed only if you want to use
   `tsvpn-push.sh` from another machine.

## 4. Installing

On the Mac:

```sh
sudo sh tsvpn-install.sh my-host.json
```

Or from another machine, if Remote Login is on:

```sh
./tsvpn-push.sh admin@192.168.1.20 ../../networks/you@example.com/mac-host.json
```

**Idempotent** — re-run any time: to change a setting, to repair, or after a
macOS update. It ends by auditing itself and exits non-zero on failure.

### The node file

```json
{
  "deployment": "you@example.com",
  "node": "mac-host",
  "role": "host",
  "targets": ["192.0.2.10"]
}
```

`role` must be `host`. Full field reference:
[`../../networks/README.md`](../../networks/README.md).

## 5. DNS

macOS ships no DNS forwarder, so this host cannot answer lookups for a
**remote** the way a GL.iNet or Pi host does.

| Who | Affected? |
|---|---|
| Your laptop or phone using the exit node | **No.** Tailscale routes their DNS through the exit node itself |
| A **remote router** with clients behind it | **Yes.** It has nothing to forward to |

If you only travel with your own devices, ignore this section.

If you do want a remote, **do not install a DNS server**. Advertise the resolver
your host site already uses as a **target**, and point the remote at it:

```jsonc
// on the Mac host — 192.168.1.1 is your router, already a resolver
{ "role": "host", "targets": ["192.0.2.10", "192.168.1.1"] }

// on the remote
{ "role": "remote", "targets": ["192.0.2.10", "192.168.1.1"],
  "exit_node": "100.64.0.1", "dns_upstream": ["192.168.1.1"] }
```

Add `192.168.1.1/32` to `autoApprovers` like any other target. The remote's
clients then resolve through the same resolver every device at the host site
uses, egressing at the host site's IP — design §3.5 satisfied, with nothing
extra running on the Mac.

Homebrew's `dnsmasq` also works if you would rather; the audit notices it.

## 6. What the scripts configure

`tsvpn-selfheal.sh` applies all of it, at every boot and on demand.

### 6.1 IP forwarding

```sh
sysctl -w net.inet.ip.forwarding=1
```

**macOS clears this on every boot.** Whether `/etc/sysctl.conf` is honoured
varies by version, and it is not something to rely on, so the LaunchDaemon
re-applying it each boot is the mechanism. The line is written to
`/etc/sysctl.conf` as well — it costs nothing, it works where it is supported,
and it documents the intent for whoever reads the machine next.

The audit reports the **live** value, because that is the only one that
matters.

### 6.2 NAT, via pf

Tailscale's automatic firewall and NAT integration is **Linux-only** —
`tailscaled` writes netfilter rules there and has no equivalent on macOS. So do
not assume forwarded traffic is SNATed for you here.

It matters because without SNAT a target device replies to a `100.x` address it
has no route to, so **subnet routes fail while the exit node looks perfectly
healthy** — a confusing split, and the one this platform is most likely to hit.
If it turns out your build does handle it, the rule below is simply redundant:
it NATs the same traffic to the same address.

The self-heal writes `/etc/pf.anchors/tsvpn`:

```
nat on en0 inet from 100.64.0.0/10 to any -> (en0)
```

Only forwarded traffic matches: the Mac's own packets leave with the interface's
own address, and its traffic to tailnet peers leaves on `utun`.

#### It does not touch Apple's `/etc/pf.conf`

pf only evaluates an anchor that the loaded ruleset declares, and that
declaration has to sit with the other translation rules — pf requires `nat`
before `rdr` before filter rules. The obvious approach is to edit
`/etc/pf.conf`. **This does not do that**, for two reasons: a bad edit costs you
networking on a machine you may not be sitting at, and a macOS update rewrites
that file, so you would be re-patching it forever.

Instead the self-heal reads Apple's file, splices the anchor into a **copy** at
`/etc/tsvpn/pf.conf`, and loads that:

```sh
sudo pfctl -f /etc/tsvpn/pf.conf
```

Apple's file is left exactly as they shipped it. Because the copy is
regenerated from theirs on every boot, a macOS update that changes `pf.conf`
is simply picked up rather than fought. And a generated ruleset is never loaded
unless `pfctl -n` parses it first — if it does not parse, nothing is loaded and
the error is printed.

> pf rules are not persistent on macOS regardless, so the LaunchDaemon reloading
> them each boot is the mechanism, exactly as with forwarding.

> If the audit shows the exit node working but a target unreachable **from a
> remote**, this is the first place to look: `sudo pfctl -a tsvpn -s nat`.

### 6.3 Advertisements

```sh
tailscale set --advertise-exit-node --advertise-routes=<targets as /32s>
```

Re-applied every boot, because a `tailscale up` typed without the flags silently
clears them.

### 6.4 Staying configured

A **LaunchDaemon**, `com.tsvpn.selfheal`, not a login item: forwarding and pf
must be restored before anyone logs in, and on a headless Mac nobody ever does.

Log: `/var/log/tsvpn-selfheal.log`.

## 7. Verification and troubleshooting

```sh
sudo /etc/tsvpn/tsvpn-audit.sh      # read-only, always safe
sudo /etc/tsvpn/tsvpn-selfheal.sh   # fixes almost everything
```

| Symptom | Likely cause | Fix |
|---|---|---|
| Everything dark at a remote site | this Mac asleep, rebooted, or off | wake it; then §3 step 4 |
| **Exit node works, targets unreachable** | pf NAT not loaded | §6.2; `sudo pfctl -a tsvpn -s nat` |
| Nothing routes at all after a reboot | forwarding cleared and the daemon did not run | `sudo launchctl print system/com.tsvpn.selfheal` |
| Advertisements empty | a bare `tailscale up`, or an app update | run the self-heal |
| Audit says "App Store build" | wrong Tailscale variant | §2 — replace with the standalone `.pkg` |
| pf rules gone after a reboot | pf is not persistent on macOS | check the daemon ran: `sudo launchctl print system/com.tsvpn.selfheal` |
| pf rules gone after a macOS update | the update replaced `/etc/pf.conf`, which our copy is generated from | run the self-heal; it re-reads Apple's file and regenerates |
| Remote's clients resolve nothing | no forwarder on this Mac | §5 |

## 8. Bring-up checklist

Nothing here has run on a Mac, so treat the first install as bring-up. Do it at
the machine, not over SSH — enabling forwarding and reloading pf can disturb
networking.

1. **Before installing anything, and before joining the tailnet**, copy this
   folder over and run the audit against a node file:

   ```sh
   sudo TSVPN_DIR=$PWD TSVPN_NODE=$PWD/my-host.json sh ./tsvpn-audit.sh
   ```

   Expect the Tailscale and pf checks to fail — nothing is set up. What you are
   looking for is that it *runs*: the config reader, `sw_vers`, `sysctl`,
   `scutil`, `dscacheutil` and `route` all behave. This costs nothing and finds
   script bugs before any change is made.
2. Install the standalone Tailscale build, `tailscale up`, confirm a `100.x`.
3. Run the installer. It refuses if the App Store build is present or the Mac is
   not signed in, without changing anything.
4. Run the audit again. Expect all PASS.
5. From another tailnet device, select this Mac as exit node and confirm your
   public IP becomes the host site's.
6. From another tailnet device, `ping` a target. **If step 5 worked and this
   does not, it is the pf NAT** (§6.2) — the single most likely thing to need
   adjusting.
7. Reboot. Wait two minutes. Run the audit again. This proves the LaunchDaemon
   restored forwarding and pf, which is the whole basis of it staying
   configured.

## 9. Why there is no remote role

A remote is a router for other devices: an access point, DHCP, DNS, and a
**kill-switch** that drops forwarded traffic when the tunnel is down.

macOS has Internet Sharing, which covers the first three. But it is configured
through a plist that Apple does not document as an interface, its behaviour
changes between releases, and there is no supported way to script it or to
verify it ended up in the state you asked for. pf *could* express a kill-switch,
but a kill-switch bolted onto a sharing mechanism you cannot inspect is one you
cannot trust — and an untrusted kill-switch is worse than none, because it fails
open silently while the devices behind it appear to work.

So the scripts refuse `role: remote`. For a remote, use
[`../glinet/`](../glinet/) or [`../rasp-pi/`](../rasp-pi/), which are built for
it and, in GL.iNet's case, field-verified.
