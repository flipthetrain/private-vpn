# scripts/glinet/ — GL.iNet routers

The complete manual for running this private VPN on **GL.iNet travel routers,
firmware 4.x**: from unboxing one to repairing it at 2am.

The *design* — what is being built, and why each requirement exists — is
platform-independent and lives in the [root README](../../README.md). This file
is the GL.iNet implementation of it. For other hardware see
[`../README.md`](../README.md).

Everything in this folder is **deployment-generic**: byte-identical on every
GL.iNet router, in every deployment. Nothing here knows an address, an SSID, or
a tailnet. The only thing that makes a router a host or a remote, on your
network or someone else's, is one small JSON file: `/etc/tsvpn/node.json`.

## Turnkey: new router from the box

**With Claude Code:** open it in this repo and say *"I plugged in a new GL.iNet"*.
The repo's `tsvpn-new-router` skill (`.claude/skills/`) asks which of these you
are doing and does everything except the steps that need a person:

| You are… | You provide | Your hands-on steps |
|---|---|---|
| **adding a remote** to a working deployment | its name; optionally a client WiFi name + key | phone: wizard, firmware, enable WAN SSH · approve it in the Tailscale console + disable key expiry |
| **building a new deployment** (host first) | tailnet account, host name, target device IPs, whether DNS is a single Pi-hole | the above, plus the one-time ACL `autoApprovers` paste |
| **replacing the host** | nothing new | the above, for the new host only; every remote is re-pointed automatically |
| **repairing / re-auditing** | which router | none |

**Without Claude Code,** the same steps by hand — each is idempotent and prints
what you must do next:

```sh
P=scripts/glinet/tsvpn-provision.sh
$P new-remote you@example.com my-remote        # or: new-host <tailnet> <name> <target-ip>...
# phone: join the sticker WiFi, http://192.168.8.1 — wizard (admin password,
# timezone), System > Upgrade, Security > Remote Access Control > SSH on
$P discover                                    # find its WAN address
TSVPN_PASSWORD='…' $P bootstrap <wan-ip> networks/you@example.com/my-remote.json
$P login   <wan-ip> networks/you@example.com/my-remote.json          # prints an approval URL
$P login   <wan-ip> networks/you@example.com/my-remote.json --wait   # after approving
$P install <wan-ip> networks/you@example.com/my-remote.json
$P lockdown <100.x>                            # close WAN SSH again
$P test     <100.x>                            # remote: live path + speed
$P wifi     <100.x> my-ssid 'wifi-key'         # optional
$P speed    you@example.com [my-remote]        # throughput report + bottleneck
```

**Throughput, measured on GL-MT3000s (2026-11):** the tunnel, not anyone's
internet line, is the limit — WireGuard runs on the router CPU. About 160 Mbit/s
each way per remote with tailscaled memory-capped (the default; ~240 uncapped,
but a host then ran out of memory under load). That is ~6 simultaneous 4K
streams. All remotes share the host's one CPU, so together they cannot take more
than that from the host site's line. `speed` saturates lines for about a minute
per remote: run it when nobody is watching.

### Admin page

Every router serves **`http://<its-100.x>:8099/`** (or `http://<name>:8099/` with
MagicDNS). Two gates: the browser must be on a **machine on the tailnet** (the
page listens only on the tailnet address, and each router refuses to forward its
own LAN devices to any 100.x, so a TV at a remote site cannot reach it), and you
log in with **that router's GL.iNet admin password** (checked by rpcd, never
stored; 5 wrong in 10 min locks login for 10 min; sessions last 30 min).

- A **remote's** page shows that router only: health, audit, exit-node test,
  speed test, self-heal, restart Tailscale, reboot, settings (targets, exit node,
  client WiFi), and a link to GL's admin UI for firmware.
- The **host's** page is the dashboard: itself plus every remote, with the same
  buttons for each and links to each remote's own page. Whoever can log in to the
  host can administer the whole deployment. The host reaches remotes with its own
  key, which each remote fetches at boot and pins to `tsvpn-api.sh` (a fixed menu
  of actions, never a shell).

A remote can be built at the host's own site and shipped: at its destination it
only needs its **WAN** port plugged into that site's router.

The rest of this section is the same job explained, done by hand.

## Quick start

This is the whole job. Everything after it is detail you only need when
something is unusual or has gone wrong.

You do this **once per router** — once for the host at your house, and once for
each remote at another house. The only difference between them is the small file
in step 1.

**Before you start**, the router must be on your tailnet. That is a ten-minute
job with a browser, done once, and it is the only part no script can do:
see [§2 First-time setup](#2-first-time-setup).

### 1. Make one small file for that router

Copy an example and change a few lines. Nothing else in this repo needs editing,
ever.

**For the host** — the router at your house:

```sh
mkdir -p "networks/you@example.com"
cp networks/example-host.json "networks/you@example.com/my-host.json"
```

Open it and set three things:

```json
{
  "deployment": "you@example.com",     <- your Tailscale account
  "node": "my-host",                   <- any name you like
  "role": "host",                      <- leave this alone
  "targets": ["192.0.2.10"]         <- the device you want to reach
}
```

`targets` is the address of the thing at your house you want to get to from
away — a TV tuner, a NAS, a media server. Add more in the list if you have them.

**For a remote** — a router at someone else's house:

```sh
cp networks/example-remote.json "networks/you@example.com/my-remote.json"
```

Same three, plus one more:

```json
{
  "deployment": "you@example.com",
  "node": "my-remote",
  "role": "remote",                    <- leave this alone
  "targets": ["192.0.2.10"],        <- the SAME list as the host
  "exit_node": "100.64.0.1"         <- the host router's 100.x address
}
```

The `exit_node` line is the host's Tailscale address — the `100.x` number shown
next to it in the Tailscale app or the admin console.

### 2. Copy the scripts and that one file onto the router

From this folder on your computer:

```sh
scp -O scripts/glinet/*.sh "networks/you@example.com/my-host.json" root@192.168.8.1:
```

It asks for a password: that is the router's **admin password**, the one you set
when you first opened its web page.

> **The `-O` matters.** Without it you get `sftp-server: not found` and nothing
> copies. These routers only speak the older file-copy protocol, and `-O` is
> what tells `scp` to use it.

`192.168.8.1` is the router when you are on its own WiFi. If it is already on
your tailnet you can use its `100.x` address instead, from anywhere in the
world.

### 3. Run the installer

```sh
ssh root@192.168.8.1
sh tsvpn-install.sh my-host.json
```

That is it. It configures everything, then checks its own work and prints a list
ending in something like:

```
=== 25 passed, 0 failed, 0 warnings ===
```

**If it says `0 failed`, you are done.** If anything failed, the line tells you
what — and [§7](#7-verification-and-troubleshooting) tells you what to do about
it.

Repeat steps 1–3 for each remote router, using that router's own file.

### Even shorter

One command from your computer, which does steps 2 and 3 together:

```sh
./scripts/glinet/tsvpn-push.sh 192.168.8.1 "networks/you@example.com/my-host.json"
```

### Afterwards

- **To change something** — edit that router's file and run the installer again.
  It is safe to re-run as many times as you like.
- **To check it is still right** — `ssh root@<router> '/etc/tsvpn/tsvpn-audit.sh'`
- **If something breaks** — `ssh root@<router> '/etc/tsvpn/tsvpn-selfheal.sh'`
  fixes almost everything without a reboot.

### If you cannot reach the router at all

The admin page lives on the router itself, so your computer has to be talking to
**it** — not to your own network, not to the hotel.

Join the router's own WiFi: either the name you gave it, or the default printed
on a sticker underneath (usually like `GL-XXXX-abc`). Or run a network cable
from your computer into one of its **LAN** ports. Then open `http://192.168.8.1`.

> The router's own WiFi works **even when the router has no internet at all**.
> Your phone may warn "no internet connection" and offer to switch back — tell
> it to stay connected. That is what makes this recoverable in a hotel.

---

## Contents

| | |
|---|---|
| [**Turnkey**](#turnkey-new-router-from-the-box) | **new router from the box, mostly automated — start here** |
| [Quick start](#quick-start) | the whole job by hand, in three steps |
| [§1 Requirements](#1-requirements) | hardware and tools |
| [§2 First-time setup](#2-first-time-setup) | hands-on steps, once per router — **start here for new hardware** |
| [§3 Installing a router](#3-installing-a-router) | the one command |
| [§4 The node file](#4-the-node-file) | the only file unique to a router |
| [§5 What the scripts configure](#5-what-the-scripts-configure) | host, remote and leak-tightening, explained |
| [§6 Captive portals](#6-captive-portals) | hotel and airport WiFi |
| [§7 Verification and troubleshooting](#7-verification-and-troubleshooting) | is it right, and what to do when it is not |
| [§8 Firmware updates](#8-firmware-updates) | **read before flashing** |
| [§9 Runbooks](#9-runbooks) | add a remote, replace the host, build a deployment, emergencies |
| [§10 Script reference](#10-script-reference) | what each script does, where things land |
| [§11 Letting a remote helper in](#11-letting-a-remote-helper-in) | temporarily, and how to revoke |

---

## 1. Requirements

- **Your machine:** `ssh`. Nothing else — no python, no jq.
- **The router:** **GL.iNet on firmware 4.x**, with the Tailscale plugin
  available. Uses only `sh`, `uci`, `jsonfilter`, `dnsmasq`, `iptables` and
  `tailscale` — all present in stock firmware, nothing to install.
- Tested on **GL-MT3000**, firmware 4.9.0, Tailscale 1.92.5. Other GL.iNet 4.x
  models should work unchanged; the design assumes only a WAN port, a LAN/WiFi
  side, and the stock firewall layout.

### These scripts are written for GL.iNet, deliberately

Most of what they do exists *because* of how GL.iNet firmware behaves:

| Thing | Why it is GL.iNet-specific |
|---|---|
| the whole self-heal | a firmware update wipes `/root`, replaces `/etc/hotplug.d/iface`, resets `firewall.tailscale0.masq`, and resets the Tailscale advertisements and exit-node selection |
| `uci set tailscale.settings.*` | the GL.iNet Tailscale **plugin**'s config (`/etc/config/tailscale`); plain OpenWrt has no such file |
| re-applying `--advertise-routes` | the plugin re-derives it from its own UI toggles on first boot, replacing a `/32` with the whole `/24` |
| the subnet-collision fix | GL.iNet installs a priority-0 policy rule on **every** WAN ifup |
| `remount_ubifs` in `rc.local` | GL.iNet's read-only-by-default `/etc` overlay |
| the kill-switch re-strip | GL.iNet restores `lan → wan`, `guest → wan` and `iot → wan` on update |

The GL.iNet-only calls are guarded, so the scripts degrade rather than crash on
plain OpenWrt — but that is defensive coding, not a supported configuration.
For anything that is not a GL.iNet router, write a platform set alongside this
one rather than bending these: see the contract in [`../README.md`](../README.md).

---

## 2. First-time setup

The steps that **cannot be automated** and must be done by a person, once per
router, before any script applies. Each needs a browser, a physical cable, or a
credential. Budget about 15 minutes per router.

| Step | What | Where |
|---|---|---|
| 2.1 | Tailscale account and tailnet | browser |
| 2.2 | Unbox the router and reach its admin panel | browser + cable |
| 2.3 | Enable Tailscale and authenticate it | router UI + browser |
| 2.4 | Tailnet settings that only exist in the console | browser |
| 2.5 | Place and cable each router at its site | physical |

> Do 2.2 and 2.3 for **every** router. 2.1 and 2.4 are once per tailnet. It is
> far easier to do every router on one desk before deploying any of them.

### 2.1 Tailscale account and tailnet

1. Sign up at [tailscale.com](https://tailscale.com) with the account that will
   own the tunnel. The free tier is sufficient.
2. Note two things from the admin console:
   - the **tailnet name** (usually the account, e.g. `you@example.com`)
   - the **MagicDNS suffix** (`something.ts.net`), shown under DNS

Use an account you control long-term. Every router's identity is tied to it, and
moving a tailnet later means re-authenticating every node in person.

Record the tailnet name and suffix in the deployment's notes — see
[`networks/README.md`](../../networks/README.md).

---

### 2.2 Unbox the router and reach its admin panel

A factory-fresh GL.iNet serves `192.168.8.1` on its **LAN** side. The default
WiFi SSID and key are printed on the label underneath.

1. Connect your laptop to one of its **LAN** ports, or to that default WiFi.
   Leave the WAN port empty for now.
2. Browse to `http://192.168.8.1`.
3. Complete the setup wizard. **Set the admin password** — this is also the
   `root` SSH password, and nothing else works until it is set.
4. Set the timezone while you are there; it makes every later log readable.

### Confirm SSH is enabled

GL.iNet ships with SSH **already on** — there is nothing to enable. Verify it
rather than assume:

```sh
ssh root@192.168.8.1 'uci show dropbear'
```

Expect `enable '1'`, `Port '22'`, and `PasswordAuth 'on'`. That last one is why
you can log in with the admin password before any key exists, and why handing
someone that password is a working credential later.

If it ever comes back disabled:

```sh
uci set dropbear.main.enable='1'
uci commit dropbear
/etc/init.d/dropbear restart
```

**Do not open SSH to the WAN side.** It listens on all interfaces, but the
firewall is what decides who reaches it, and the `wan` zone is `input DROP` by
default:

```sh
uci get firewall.@zone[1].input      # wan — expect DROP
```

Leave that alone. Remote SSH access does **not** come from exposing a port; it
comes from the tunnel. The VPN guide sets `firewall.tailscale0.input='ACCEPT'`,
which makes SSH — and the GL.iNet web UI — reachable at the router's `100.x`
address to your tailnet, and to nobody else. That is the whole security model:
the router stays closed to the internet and to the site's own network, and
Tailscale is the only door.

> **Optional hardening, later.** Once keys are installed and verified on both
> routers, you can turn password auth off entirely
> (`uci set dropbear.main.PasswordAuth='off'`). Think first: it locks out the
> "just give them the admin password" option for remote helpers, and if you ever
> lose your private key your only way back in is a physical reset. Sensible for
> a router you alone administer; awkward for one where someone else may need to
> help.

### Change the LAN subnet now, if you are going to

Both routers ship on `192.168.8.0/24`. If the remote site's own network collides
with the host network you intend to route into, fixing it here is trivial and
fixing it later is not — changing the LAN subnet drops whatever connection you
are using to change it.

Network → LAN → change the IP, save, then reconnect on the new address.

See design §3.2 for whether your sites actually collide.

### Set the WiFi the client devices will use

Wireless → set the SSID and password for the AP that TVs, consoles and sticks
will join. Pick something you can read aloud over the phone.

> **Record the SSID and key somewhere durable and private** — a password manager,
> not a file in this repo. If they are lost, every client
> device has to be re-joined by hand at the remote site.

### Create an SSH key, if you don't already have one

Password authentication does not work from non-interactive shells, so without a
key every later remote repair needs a human typing a password. Five minutes here
saves that every time.

**Check whether you already have one** — on your own machine, not the router:

```sh
ls ~/.ssh/id_ed25519.pub
```

If that prints a path, you have a key already; skip to installing it.

**If it says "No such file", create one:**

```sh
ssh-keygen -t ed25519 -C "glinet-routers"
```

- Press Enter to accept the default location (`~/.ssh/id_ed25519`).
- A passphrase is optional. If you set one, add the key to `ssh-agent`
  (`ssh-add ~/.ssh/id_ed25519`) so you are not retyping it constantly.

That writes **two** files:

| File | What it is |
|---|---|
| `~/.ssh/id_ed25519` | **private key** — never copy, share, or paste it anywhere |
| `~/.ssh/id_ed25519.pub` | **public key** — safe to paste; this is what goes on the router |

**Read the public key out:**

```sh
cat ~/.ssh/id_ed25519.pub
```

One line, looking like:

```
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI... you@yourmachine
```

That entire line — algorithm, blob, and trailing comment — is the public key.
You should not need to paste it anywhere: the commands below read it straight
out of the file.

> **Windows:** the same commands work in PowerShell; OpenSSH ships with Windows
> 10 and later, and the key lands in `C:\Users\<you>\.ssh\`. If you work in
> WSL, note that WSL has its own home directory — a key made in WSL is not the
> same as one made in PowerShell. Generate it wherever you will actually run
> `ssh` from.

### Install the public key on the router

> **One key, every router.** You do **not** generate a key per router. Generate
> one keypair per *machine you administer from*, and install its public half on
> every GL.iNet you own — the same key works on all of them. `authorized_keys`
> holds one line per authorised machine, so if you later want to admin from a
> laptop as well, generate a key there too and append it to each router. Prefer
> that over copying a private key between your machines: separate keys can be
> revoked individually, and a leaked one does not compromise the rest.

Still on the desk, while you have easy access. Pipe the file straight in rather
than copying and pasting it — this avoids pasting a truncated key, or the
private one by mistake. The `grep -q` guard makes it safe to re-run:

```sh
cat ~/.ssh/id_ed25519.pub | ssh root@192.168.8.1 \
  'mkdir -p /etc/dropbear; K=$(cat); grep -qxF "$K" /etc/dropbear/authorized_keys 2>/dev/null \
   || echo "$K" >> /etc/dropbear/authorized_keys; chmod 600 /etc/dropbear/authorized_keys'
```

Without the guard, a plain `>>` appends a duplicate every time you run it.
Harmless — dropbear matches the first — but it makes the file hard to audit when
several machines are authorised. To clean up duplicates later:

```sh
ssh root@<ROUTER> 'awk "!seen[\$0]++" /etc/dropbear/authorized_keys > /tmp/ak \
  && cat /tmp/ak > /etc/dropbear/authorized_keys && rm /tmp/ak'
```

To see which machines are authorised on a router:

```sh
ssh root@<ROUTER> 'awk "{print \$3}" /etc/dropbear/authorized_keys'
```

It will ask for the admin password from Step 2 — that is the last time it should.

PowerShell:

```powershell
type $env:USERPROFILE\.ssh\id_ed25519.pub | ssh root@192.168.8.1 `
  'mkdir -p /etc/dropbear; K=$(cat); grep -qxF "$K" /etc/dropbear/authorized_keys 2>/dev/null || echo "$K" >> /etc/dropbear/authorized_keys; chmod 600 /etc/dropbear/authorized_keys'
```

### Two directions of trust — don't confuse them

| Direction | Lives in | Means |
|---|---|---|
| **You → router** | `/etc/dropbear/authorized_keys` *on the router* | "this machine may log in as root" |
| **Router → you** | `~/.ssh/known_hosts` *on your machine* | "this is the router I saw last time" |

The first is what you just installed. The second is what SSH is asking about when
a new router prompts `The authenticity of host ... can't be established` — that
is your machine recording the router's own host key.

It matters later: **factory-resetting or reflashing a router regenerates its host
key**, so your next connection fails with `WARNING: REMOTE HOST IDENTIFICATION
HAS CHANGED`. That is expected after a deliberate rebuild, and the fix is to drop
the stale entry:

```sh
ssh-keygen -R <ROUTER>
```

Only do that when *you* caused the change. The same warning on a box you did not
touch is worth investigating rather than clearing.

Then confirm it worked before you unplug anything — this should **not** prompt
for a password:

```sh
ssh root@192.168.8.1 'echo key-auth-ok'
```

> **Why not `ssh-copy-id`?** It writes to `~/.ssh/authorized_keys`, which for
> root on OpenWrt is `/root/.ssh/`. GL.iNet firmware updates **destroy `/root`**,
> so a key installed that way disappears at the worst possible moment. GL.iNet
> uses **dropbear**, which also reads `/etc/dropbear/authorized_keys` — that path
> is under `/etc` and survives updates. Use it.

---

### 2.3 Enable Tailscale and authenticate the router

This is the step that genuinely requires a person at the router's site, and the
only one that cannot be done again remotely if it is lost.

**In the GL.iNet UI:** Applications → Tailscale → enable. (On some firmware it is
under VPN → Tailscale.)

**Or over SSH:**

```sh
uci set tailscale.settings.enabled='1'
uci commit tailscale
/etc/init.d/tailscale restart
sleep 5
tailscale up
```

`tailscale up` prints a **login URL**. Open it in a browser, sign in to the
account from Step 1, and approve the machine. Then confirm:

```sh
tailscale status        # this node should now show a 100.x address
```

Give the machine a recognisable name in the console while you are there — it is
what you will look for when something breaks.

Once this succeeds, `/etc/tailscale/tailscaled.state` holds the node identity and
it survives reboots *and* firmware updates. Everything after this point can be
done over the tunnel.

> A factory reset or `tailscale logout` destroys this and requires physically
> returning to the router. It also produces a **new node identity and a new
> `100.x` address**, which invalidates any peer pinning the old one — see §9.2.

Record each router's `100.x` address: a remote's `exit_node` is exactly this.

---

### 2.4 Tailnet settings that only exist in the console

Both of these are silent failures if skipped: nothing errors, the feature simply
never works.

### Disable key expiry — per machine

Machines → select the router → ⋯ → **Disable key expiry**.

Do this for **every** router. By default node keys expire in about six months,
and re-authentication is the in-person step from Step 3. A remote router whose
key expires means a site visit.

### Add `autoApprovers` to the ACL — once per tailnet

Access Controls → edit the policy file:

```json
"autoApprovers": {
  "exitNode": ["autogroup:admin"],
  "routes": {
    "<TARGET_DEVICE_IP>/32": ["autogroup:admin"]
  }
}
```

Without this, every advertised route and exit node must be approved by hand in
the console, and re-approved whenever a node is rebuilt. Approval failures are
**silent** — no CLI warning, the route simply never appears on the far end.

Add one `routes` entry per device you intend to reach. Coming back to add another
later is easy; forgetting that you must is what costs an afternoon.

---

### 2.5 Place and cable each router

Each router cables into its site's existing network via its **WAN** port. This is
the standard GL.iNet travel-router topology: the upstream network arrives on WAN,
and the router keeps its own isolated LAN and WiFi for clients. The site's
existing router is never reconfigured.

```
site's existing router  ──LAN port──►  ──WAN port──  GL.iNet router
                                                         │
                                                    its own LAN / WiFi
                                                         ▼
                                                    client devices
```

> ⚠️ **Do not plug the upstream cable into a LAN port.** That islands the router:
> it gets no default route so it never reaches the tailnet, and it starts
> answering DHCP on the site's network, breaking other devices there. Symptoms
> are the box never appearing in the console plus unrelated devices at the site
> dropping off. There is no remote recovery — someone has to move the cable.

Power on and give it about two minutes, then confirm the router appears online in
the Tailscale console before leaving the site.

---

### Done — what you should have

- [ ] A Tailscale account, tailnet name and MagicDNS suffix recorded
- [ ] Both routers set up, admin password set, timezone set
- [ ] LAN subnets chosen (and de-collided, if needed)
- [ ] Client WiFi SSID + key set and **recorded privately**
- [ ] Your SSH key installed on both routers
- [ ] Both routers authenticated and showing `100.x` addresses
- [ ] Key expiry disabled on both
- [ ] `autoApprovers` in the tailnet ACL
- [ ] Both routers cabled into their site by the **WAN** port and online

### Credentials to keep (never in the repo)

- GL.iNet admin password (also the `root` SSH password)
- Client WiFi SSID and key
- The remote site's own WiFi key, if you configure a repeater fallback

Then go to §3 and install the scripts.

---


## 3. Installing a router

Copy this folder plus that router's JSON onto the box and run the installer:

```sh
./tsvpn-push.sh <router> <node.json>
```

```sh
# a brand-new router, while you are on its own WiFi
./tsvpn-push.sh 192.168.8.1 ../../networks/you@example.com/my-host.json

# an existing one, over the tunnel, from anywhere in the world
./tsvpn-push.sh 100.64.0.2 ../../networks/you@example.com/my-remote.json
```

`tsvpn-push.sh` only copies files and then runs `tsvpn-install.sh` on the router.
If `ssh` is awkward — a browser terminal, a phone — copy the files across any way
you like and run the installer there yourself:

```sh
sh /tmp/tsvpn/tsvpn-install.sh /tmp/tsvpn/my-remote.json
```

It is **idempotent**. Re-run it any time: to change a setting, to repair a
router, or after a firmware update. It finishes by auditing what it built, and
exits non-zero if anything failed.

**One prerequisite:** the router must already be authenticated to your tailnet
(§2.3). That is the single step no script can do.

### What the installer does

1. copies the generic scripts to `/etc/tsvpn/`
2. installs your JSON as `/etc/tsvpn/node.json`
3. generates `/etc/rc.local` — a bootstrap carrying a copy of all of it, so a
   firmware update cannot leave the router unrepairable with nobody on site
4. lists `/etc/tsvpn` in `/etc/sysupgrade.conf`
5. runs the self-heal, applying everything in §5, then audits it

### The installer *is* the provisioner

`tsvpn-selfheal.sh` does everything in §5 — plugin toggles, the firewall zone and
forwardings, masquerade, the kill-switch, DNS, IPv6, the collision fix with its
hotplug hook and cron backstop, and the clobbered `tailscale set` line — all
keyed off `role`. §5 is the explanation of *what* it does and *why*; the
installer is how you apply it.

So provisioning a router, once it is authenticated, is: write the JSON, run the
installer. There is no separate configuration step.

---

## 4. The node file

One small JSON per router. That is the whole of a deployment's configuration:
one file for the host, one for each remote.

```
networks/
  you@example.com/
    my-host.json          <- role: host
    my-remote.json        <- role: remote
    another-remote.json   <- role: remote
```

Copy [`../../networks/example-host.json`](../../networks/example-host.json) or
[`../../networks/example-remote.json`](../../networks/example-remote.json) and
edit. Real ones are git-ignored; the examples are not.

### Host

```json
{
  "deployment": "you@example.com",
  "node": "my-host",
  "role": "host",
  "targets": ["192.0.2.10"]
}
```

### Remote

```json
{
  "deployment": "you@example.com",
  "node": "my-remote",
  "role": "remote",
  "targets": ["192.0.2.10"],
  "exit_node": "100.64.0.1",
  "collide": "192.168.1.0/24"
}
```

### Every field

| Field | Who | Meaning |
|---|---|---|
| `deployment` | both | tailnet name. Cosmetic — it labels logs and audit output |
| `node` | both | this router's name. Cosmetic, but use the name you gave it in the Tailscale console |
| `role` | both | `host` or `remote`. **Exactly one host per deployment.** |
| `targets` | both | bare IPv4 addresses at the host site to make reachable. No `/32`, no port. Same list on every router |
| `exit_node` | remote | the **host router's `100.x` address**. Required |
| `collide` | remote | the host-site range your `targets` live in (e.g. `192.168.1.0/24`). The fix acts only while the remote site's own network uses that same range (design §3.2) and is dormant otherwise, so it is safe to set pre-emptively. Omit it if you don't want that |
| `dns_upstream` | both | optional list. **On a remote, leave it out** — DNS then resolves through the host, which is the whole point (design §3.5). Set it only if you are using the resolver-as-a-target approach below. **On a host**, it lists extra resolvers *on the host's own site* (e.g. the ISP router) used alongside the WAN DHCP resolver — set it when that resolver is a single box such as a Pi-hole. Never a public resolver |
| `tailnet_ip` | both | this router's own `100.x`. Not read by the router; `tsvpn-provision.sh login --wait` records it so `new-remote` can derive a remote's `exit_node` from the host, and `reinstall-remotes` can reach each remote |

Anything else you add (`_comment`, notes of your own) is ignored.

### A remote advertises nothing

Only the host advertises. The self-heal runs
`tailscale set --advertise-routes= --advertise-exit-node=false` on a remote,
and the audit fails if anything reappears.

This is not cosmetic. The GL.iNet Tailscale plugin advertises the router's own
LAN by default, and `tailscale set --exit-node=…` does **not** clear it. The
advertisement then sits unapproved and inert — until somebody approves it in the
console, and that whole site becomes reachable from your tailnet. The VPN is
one-way by design: remote to host, never back.

### Why `targets` goes on every router

The host **advertises** each address as a `/32`; a remote needs the list so its
collision fix knows which addresses to pin to the tunnel. Keep them identical.

### The other way to do DNS

By default the host answers the remote's lookups with its own dnsmasq. You can
instead skip that entirely: advertise the resolver your host site already uses
as a **target**, and point the remote straight at it.

```jsonc
// host                                    // remote
{ "targets": ["192.0.2.10", "192.168.1.1"] }
{ "targets": ["192.0.2.10", "192.168.1.1"],
  "dns_upstream": ["192.168.1.1"] }
```

Add `192.168.1.1/32` to `autoApprovers` like any other target. The result is the
same as far as design §3.5 is concerned — the remote's clients resolve through
the resolver every device at the host site uses, egressing at the host site's IP.
It is the only option on a host with no forwarder, such as Windows.

### Adding a device to reach at the host site

1. Add its address to `targets` in **every** node file for that deployment.
2. Add `"<ip>/32": ["autogroup:admin"]` to `autoApprovers` in the tailnet ACL.
   Without it the route is silently never approved (§2.4).
3. Re-run the installer against every router.

### If you rebuild the host

It gets a **new `100.x`**. Update `exit_node` in every remote's JSON and re-run
the installer against each. Until you do, a remote keeps pinning the dead
address and blackholes all of its internet (§7) — Tailscale failing closed
rather than leaking, but it looks like a dead line. See §9.2.

---

## 5. What the scripts configure

You never need to run this by hand — `tsvpn-selfheal.sh` applies all of it, and
re-applies it on every boot. It is here so you can read what it did, verify it
yourself, or repair a router with nothing but a shell.

### 5.1 Host-side router

Cable into the host site's LAN via its **WAN** port, then over SSH:

```sh
# GL.iNet plugin toggles
uci set tailscale.settings.enabled='1'
uci set tailscale.settings.lan_enabled='1'
uci set tailscale.settings.wan_enabled='1'
uci commit tailscale

# firewall: tailscale0 zone + forwarding both ways to lan and wan
uci set firewall.tailscale0=zone
uci set firewall.tailscale0.name='tailscale0'
uci set firewall.tailscale0.device='tailscale0'
uci set firewall.tailscale0.input='ACCEPT'
uci set firewall.tailscale0.mtu_fix='1'
for pair in lan_tailscale:lan:tailscale0 tailscale_lan:tailscale0:lan \
            wan_tailscale:wan:tailscale0 tailscale_wan:tailscale0:wan; do
  n=${pair%%:*}; rest=${pair#*:}; src=${rest%%:*}; dst=${rest#*:}
  uci set firewall.$n=forwarding
  uci set firewall.$n.src="$src"
  uci set firewall.$n.dest="$dst"
done
uci commit firewall
/etc/init.d/firewall restart

tailscale set --advertise-exit-node --advertise-routes=<TARGET_DEVICE_IP>/32
```

Then give this box its DNS role — it resolves via its own network and serves
those answers to the tailnet, so remote sites get what a device at the host site gets
(design §3.5):

```sh
uci -q delete dhcp.@dnsmasq[0].server
uci -q delete dhcp.@dnsmasq[0].noresolv
uci set dhcp.@dnsmasq[0].localservice='0'
uci commit dhcp && /etc/init.d/dnsmasq restart
```

The host router **keeps** its `*→wan` forwardings — `tailscale0 → wan` is what
carries exit-node traffic out to the internet. Do not apply §5 here.

The target device must be reachable from this router (it sits on the router's WAN
side) and `net.ipv4.ip_forward` must be `1`.

### 5.2 Remote-side router

Cable into their network via its **WAN** port. This is the standard GL.iNet
travel-router topology and it is deliberate: the upstream network arrives on WAN,
the router keeps its own isolated LAN and WiFi for clients, and it NATs those
clients into the tunnel (design §3.3). The site's existing router is never
reconfigured.

> **Common miswire — a fault, not a variant.** Plugging the upstream cable into a
> *LAN* port islands the router: no default route, so it never reaches the
> tailnet, and it starts answering DHCP on their network, breaking other devices.
> Symptoms: the box never appears in the console, and unrelated devices at the
> site start dropping off. No remote recovery — someone must move the cable.

```sh
uci set tailscale.settings.enabled='1'
uci set tailscale.settings.lan_enabled='1'
uci commit tailscale

uci set firewall.tailscale0=zone
uci set firewall.tailscale0.name='tailscale0'
uci set firewall.tailscale0.device='tailscale0'
uci set firewall.tailscale0.input='ACCEPT'
uci set firewall.tailscale0.mtu_fix='1'
uci set firewall.tailscale0.masq='1'          # REQUIRED — design §3.3
uci set firewall.lan_tailscale=forwarding
uci set firewall.lan_tailscale.src='lan'
uci set firewall.lan_tailscale.dest='tailscale0'
uci commit firewall
/etc/init.d/firewall restart

tailscale set --exit-node=<HOST_TAILNET_IP> \
              --exit-node-allow-lan-access \
              --accept-routes
```

`--exit-node-allow-lan-access` keeps the local admin panel and the site's own DNS
reachable while everything else tunnels. Without it you can lock yourself out of
the router you are standing next to.

### 5.3 Leak-tightening the remote

Apply design §3.5 (DNS) and design §3.6 (IPv6) now, then close the remaining escape routes.

**Kill-switch — remove every `*→wan` forwarding.** GL.iNet ships `lan → wan`,
`guest → wan` and `iot → wan`. While an exit node is selected these are inert,
because routing sends everything to table 52 and Tailscale blackholes rather than
leaking if the exit node stops serving (§7). They matter if the exit node is
ever explicitly **deselected**, at which point clients silently fall back to the
site's own uplink.

```sh
i=0
while [ $i -lt 20 ]; do
  d=$(uci -q get firewall.@forwarding[$i].dest)
  [ -z "$d" ] && break
  if [ "$d" = "wan" ]; then
    uci -q delete firewall.@forwarding[$i]      # index does NOT advance: uci renumbers
  else
    i=$((i + 1))
  fi
done
uci commit firewall && /etc/init.d/firewall restart
```

Afterwards only `lan → tailscale0` and `tailscale0 → lan` should remain. Clients
can then reach the internet **only** through the tunnel, and get nothing at all
when it is down — which is the point.

**Guest / IoT SSIDs.** Leaving them `disabled='1'` is not enough on its own; the
kill-switch above is what makes enabling one fail closed instead of silently
bypassing the tunnel.

> All three of these — kill-switch, DNS (design §3.5) and IPv6 (design §3.6) — are re-applied
> by the self-heal on every boot, because a firmware update restores GL.iNet's
> defaults for all of them. Running the commands here by hand configures the box
> now; installing the self-heal is what keeps it configured.

---

## 6. Captive portals

Hotels, airports and conference WiFi intercept your first HTTP request and demand
a click-through. The router has no browser, so it never gets past it — and this
applies to wired hotel-room jacks too, not just WiFi.

The way through is to authenticate on a device that *does* have a browser, then
wear its MAC address. The portal tracks sessions by MAC, so the router inherits
the authenticated session.

**The catch that trips everyone up:** modern phones use a *different, randomised*
MAC for every network. You need the one your phone is using **on that specific
SSID**, not the address printed on the box.

- **iOS** — Settings → Wi-Fi → ⓘ next to the network → *Wi-Fi Address*
- **Android** — Settings → Network → Wi-Fi → the network → Advanced →
  *Randomised MAC*

Full sequence:

1. On your phone, join the network and complete the portal until you have real
   internet.
2. Read the phone's MAC for that network, as above.
3. Join the **router's own WiFi** from the phone — its AP works fine with no
   uplink — and reach it at `192.168.8.1`.
4. Apply the MAC, either way:
   - **GL.iNet UI**, in the phone's browser: the MAC-clone field in the internet
     or network settings. No terminal needed.
   - **SSH**, if you have an SSH app on the phone (Termux on Android; Blink or
     Termius on iOS): `/etc/tsvpn/tsvpn-clone-mac.sh <the-phone-MAC>` (§10).
5. **Turn the phone's WiFi off, or forget that network.** Two interfaces sharing
   one MAC on the same LAN is a conflict and neither will work reliably. This is
   the step people skip, and the failure looks like the portal "not working".
6. Point the router at the uplink — plug in the WAN cable, or join the SSID as a
   repeater.

When you leave, put the real MAC back:

```sh
/etc/tsvpn/tsvpn-clone-mac.sh --reset
```

**What to expect:**

- Sessions are usually time-limited. When it expires you repeat the process — the
  phone re-authenticates, and the MAC you cloned is still the right one.
- Some portals bind to MAC *and* browser cookie, or re-prompt periodically. Those
  cannot be cloned around; you need a device with a browser on the network.
- If you "forget" the network on your phone, it generates a **new** random MAC
  next time. Re-read it rather than reusing the old one.
- Cloning changes only the uplink interface. Your tunnel, LAN and WiFi are
  untouched, so clients behind the router never notice.

---

## 7. Verification and troubleshooting

### The one command that answers the question

```sh
ssh root@<router> '/etc/tsvpn/tsvpn-audit.sh'
```

Read-only, so it is always safe. It checks every requirement in design §3 plus
the installation itself, prints `PASS`/`FAIL`/`WARN` per check, and **exits 1 if
anything failed** — usable from a script as well as by eye.

Run it on **every** router, and on a remote after any change to the host: a
remote's audit is the only thing that proves the path *through* the host.

### Checking by hand

Always **from the remote**, never from the host:

```sh
tailscale exit-node list | sed -n 2,3p
traceroute -n -m 2 -w 2 8.8.8.8 | sed -n 2p
wget -qO- https://ifconfig.me/ip; echo
ip route get <TARGET_DEVICE_IP>
ip route get <HOST_TAILNET_IP>
nslookup github.com 127.0.0.1
ping -c1 -W3 <TARGET_DEVICE_IP>
```

| Check | Expected |
|---|---|
| exit node status | `selected` |
| first hop | `<HOST_TAILNET_IP>` |
| egress IP | the **host site's** public IP |
| target route | `dev tailscale0 table 52` |
| DNS upstream route | `dev tailscale0 table 52` |
| name resolution | answers — the check a route test misses |
| target ping | `OK` |

### The one command that fixes almost everything

```sh
ssh root@<router> '/etc/tsvpn/tsvpn-selfheal.sh'
```

Rebuilds the entire configuration from `node.json` without rebooting, then
audits itself. Idempotent and safe to re-run on either role. Try this before
diagnosing anything.

| Symptom | Likely cause | Fix |
|---|---|---|
| Box offline in console | No uplink | Cable in the **WAN** port (§5); check their DHCP |
| Everything dead after firmware update | `/root` wiped + prefs reset | §8, then re-run the self-heal |
| Still broken after a flash | Self-heal did not run | `cat /var/log/tsvpn-selfheal.log`; if absent, `rc.local` was lost — re-run the installer (§3) |
| Self-heal ran but did nothing | `/etc/tsvpn/node.json` missing | Log names the missing file — re-run the installer (§3) |
| **"No internet", but `ping 8.8.8.8` works and the target is reachable** | dnsmasq has **no upstream**: `server` written as a uci scalar instead of a list, so it is silently dropped | design §3.5 — the self-heal fixes it; confirm with `grep '^server=' /var/etc/dnsmasq.conf.*` |
| Clients get no DNS; the host answers nothing on its `100.x` | `local-service` + a `/32` `tailscale0` on the host | `uci set dhcp.@dnsmasq[0].localservice='0'` on the host (design §3.5) |
| Internet works, target unreachable | Subnet collision rule reverted | Run the route-fix script (design §3.2) |
| Router works, devices behind it don't | `masq` not set | design §3.3 |
| Video stalls, UI loads | MSS/MTU | `uci get firewall.tailscale0.mtu_fix` → `1` |
| **All** internet dead at remote site | Exit node pinned but not advertising | See below — fix the host, or `tailscale set --exit-node=` to restore internet |
| `no exit nodes found` on one node only | ACL doesn't grant it `autogroup:internet` | Fix the tailnet ACL |
| `tailscale` says logged out | Node key revoked or expired | **On-site re-auth** — `tailscale up`, open the URL |
| `ip route get 8.8.8.8` shows `dev eth0` | Client DNS leaking | design §3.5 |
| **"No internet", but `ping 8.8.8.8` works and the target is reachable** | dnsmasq has **no upstream**: `server` written as a uci scalar instead of a list, so it was silently dropped | design §3.5 — `delete` then `add_list`; confirm with `grep '^server=' /var/etc/dnsmasq.conf.*` |
| Remote clients get no DNS; host answers nothing on its `100.x` | `local-service` + a `/32` `tailscale0` on the host | `uci set dhcp.@dnsmasq[0].localservice='0'` on the host (design §3.5) |

### The pinned-exit-node trap

A remote stores its exit node by **node ID**, independently of whether that node
still advertises `0.0.0.0/0`. If the host stops advertising, the remote keeps
routing all traffic at it and Tailscale **blackholes** rather than leaking:

```
traceroute → * * *
curl       → Operation not permitted
```

That looks like a dead WAN at the remote site. It is not — it is a correctly
configured remote pointed at a node that stopped serving.

**The diagnostic trap:** `tailscale status` still prints `hostname … exit node`
next to the peer. That means *"this is the node I selected,"* not *"this node is
offering."* To tell them apart:

```sh
tailscale exit-node list                         # "no exit nodes found" = nobody offering
tailscale status --json | grep ExitNodeOption    # false = not offering
```

`ExitNodeOption: false` + `ExitNode: true` is the signature.

### Stale status text

`tailscale exit-node list` often reads `selected but offline` for a few seconds
after a restart, and sometimes lingers. Trust a traceroute over the status text —
if the first hop is the exit node, it is working.

---

## 8. Firmware updates

**Every firmware update silently breaks this setup.** The box comes back online
and looks healthy in the Tailscale console while the tunnel is not carrying
traffic.

| Thing | Path | Survives? |
|---|---|---|
| Firewall / uci config | `/etc/config/*` | ✅ mostly |
| Tailscale node identity | `/etc/tailscale/tailscaled.state` | ✅ node stays logged in |
| `rc.local` | `/etc/rc.local` | ✅ |
| SSH authorized_keys | `/etc/dropbear/authorized_keys` | ✅ |
| Cron entries | `/etc/crontabs/root` | ✅ |
| **Helper scripts** | `/root/*.sh` | ❌ **always destroyed** |
| **Hotplug hooks** | `/etc/hotplug.d/iface/*` | ❌ whole dir replaced |
| **Route advertisements** | control-plane prefs | ❌ reset to GL.iNet defaults |
| **Exit node selection** | control-plane prefs | ❌ cleared |
| **`firewall.tailscale0.masq`** | `/etc/config/firewall` | ❌ reset to `0` |
| **Kill-switch (§5)** | `/etc/config/firewall` | ❌ `*→wan` forwardings restored |

Two things make this nasty. `/root` is not in GL.iNet's config backup, so
`rc.local` and cron survive and keep calling scripts that no longer exist. And
the GL.iNet Tailscale plugin **re-derives** `--advertise-routes` from its own UI
toggles on first boot — replacing a `/32` with the whole `/24` and dropping
`--advertise-exit-node`.

The self-heal repairs all of it on first boot. Verify anyway.

### Post-update checklist

```sh
ssh root@<router> 'cat /var/log/tsvpn-selfheal.log'   # did it run, did it pass?
ssh root@<router> '/etc/tsvpn/tsvpn-audit.sh'         # independent check
```

If the log is missing entirely, `rc.local` was lost too — re-run the installer
(§3), and treat that as significant: it means the one file this whole design
relies on did not survive.

Then run §7 verification **from the far end** — advertisements only prove out
from the other side of the tunnel.

### Updating a remote router

Survivable, but conditionally:

- ✅ **`/etc` must survive the flash**, keeping `tailscaled.state` so the node
  returns authenticated and you can SSH in over the tunnel to repair it.
- ❌ **Never flash remotely with keep-settings off.** The node drops off the
  tailnet and there is no way back in — a site visit or a factory reset.
- Have the §10 scripts saved **off the router** first.
- `uci show upgrade` may report `keep_config='0'` even on boxes whose `/etc`
  survived; treat that value as unreliable rather than as permission.

Consider disabling automatic firmware updates in the GL.iNet UI. An unattended
update can take the link down for days before anyone notices.

---

## 9. Runbooks

The things you will actually do, in order. Each assumes you have this guide and
that deployment's folder under `networks/`.

### 15.1 Add a remote router to an existing deployment

1. **First-time setup** on the new box — §2 below
   steps 2 and 3: admin password, timezone, SSH key, client WiFi SSID, and
   **authenticate it to the tailnet**. That last step needs a person at the
   router and cannot be done later remotely.
2. **Check for a subnet collision** (design §3.2). If the site's LAN uses the range you
   route into, either change one of them now or set `collide` in the JSON.
3. **Write its JSON** — copy `networks/example-remote.json` into the
   deployment's folder. `role: remote`, the same `targets` as every other
   router, and `exit_node` = the host's `100.x`.
4. **Install:** `./scripts/glinet/tsvpn-push.sh <ROUTER> <node.json>`
5. **Confirm the ACL** grants this node `autogroup:internet`, or it will report
   `no exit nodes found` no matter how healthy the host is (the root README).
6. **Cable it in by the WAN port** at the site (§5) and re-run the audit.

Nothing on the host needs to change. Clients are additive.

### 15.2 Replace the host router

The host's identity is what every remote pins, so this is the disruptive one.

1. **Capture anything you cannot recreate** from the old box while it still
   answers — above all the WiFi keys, which are not in any file here:

   ```sh
   ssh root@<OLD_HOST> 'uci show wireless | grep -E "\.key=|\.ssid="'
   ```

2. **First-time setup** on the new box, including authenticating it. It gets a
   **new `100.x` address and a new node ID**.
3. **Write its JSON** — `role: host`, the same `targets`. Install it:
   `./scripts/glinet/tsvpn-push.sh <NEW_HOST> <host.json>`
4. **Re-check the tailnet ACL.** Route approvals follow node identity, so
   `autoApprovers` must still cover each `<TARGET_DEVICE_IP>/32` (the root README), and key
   expiry must be disabled on the new node.
5. **Update every remote**: change `exit_node` to the new address in each
   remote's JSON and re-run the installer against each one.
6. **Audit every router**, host first.

> Until step 5 is done, each remote keeps pinning the dead address and
> **blackholes all of its internet** — Tailscale failing closed rather than
> leaking, but it looks like a dead line at the remote site. §9.4 is the
> one-command way to give a site its internet back while you work.

### 15.3 Build a whole new deployment

For someone else, on a new tailnet. Roughly 15 minutes per router.

1. **§2 below, all five steps** — new Tailscale
   account and tailnet, both routers' first-run wizard, authenticate both,
   the two console-only settings (**disable key expiry**, add `autoApprovers`),
   and cabling. Do both routers on one desk before deploying either.
2. **Read design §3** and decide two things: which devices at the host site need reaching
   (`targets`, one `/32` each — design §3.1), and whether the two sites' LANs collide
   (design §3.2).
3. **Make the deployment folder** and write one JSON per router:

   ```sh
   mkdir -p "networks/them@example.com"
   cp networks/example-host.json   "networks/them@example.com/their-host.json"
   cp networks/example-remote.json "networks/them@example.com/their-remote.json"
   ```

4. **Install the host first** — a remote's audit checks the path *through* the
   host, so it cannot pass until the host works:

   ```sh
   ./scripts/glinet/tsvpn-push.sh 192.168.8.1 "networks/them@example.com/their-host.json"
   ./scripts/glinet/tsvpn-push.sh 192.168.8.1 "networks/them@example.com/their-remote.json"
   ```

5. **Verify from the remote** (§7) — the only direction that proves anything.
6. **Write the deployment's `README.md`** ([networks/README.md](../../networks/README.md)) while the details are fresh.
7. Deploy the remote router to its site and re-audit from there.

### 15.4 Emergency — a remote site has no internet at all

Almost always a pinned exit node that stopped serving (§7), not a dead line.
Restore service first, diagnose after:

```sh
ssh root@<REMOTE> 'tailscale set --exit-node='
```

That drops the tunnel requirement and the site falls back to its own uplink.
**It also drops the kill-switch's protection and the host site's IP**, so treat it as
a temporary measure: streaming will look local and DNS resolves locally again.

Put it back with `/etc/tsvpn/tsvpn-selfheal.sh` once the host is healthy.

If the site is dark because the *remote* router is misconfigured rather than the
host, the self-heal alone usually fixes it — it is one command and idempotent.

### 15.5 After a firmware update

The box comes back looking healthy in the Tailscale console while the tunnel
carries nothing. The self-heal should have already repaired it; verify rather
than assume (§8):

```sh
ssh root@<ROUTER> 'cat /var/log/tsvpn-selfheal.log'   # did it run, did it pass?
ssh root@<ROUTER> '/etc/tsvpn/tsvpn-audit.sh'         # independent check
```

If the log is missing entirely, `rc.local` was lost too — re-run
`./scripts/glinet/tsvpn-push.sh` and file that away as important, because it means the
one file this design relies on did not survive.

Then verify **from the remote**, never from the host: advertisements only prove
out from the far side of the tunnel (§7).

---

## 10. Script reference

| Script | Runs on | What it does |
|---|---|---|
| **`tsvpn-provision.sh`** | your machine | the turnkey path: discover, node files, bootstrap, tailnet login, install, lockdown, WiFi, test, re-point remotes |
| **`tsvpn-push.sh`** | your machine | copies this folder + a node JSON to a router, runs the installer |
| **`tsvpn-install.sh`** | router | installs everything, generates `rc.local`, applies and audits |
| **`tsvpn-selfheal.sh`** | router | rebuilds the whole configuration (§5). Runs at every boot |
| **`tsvpn-audit.sh`** | router | read-only. Verifies every design requirement, PASS/FAIL, exit 1 on failure |
| **`tsvpn-lib.sh`** | router | reads `node.json`; sourced by the others |
| **`tsvpn-fix-route.sh`** | router | subnet-collision fix (design §3.2). Self-disabling |
| **`tsvpn-clone-mac.sh`** | router | captive-portal MAC cloning (§6) |
| **`tsvpn-persist.sh`** | router | writes a hand-edited `node.json` back into the `rc.local` payload |
| **`tsvpn-test-exit.sh`** | router (remote) | read-only live test: direct vs relayed path, latency, egress, DNS, targets, speed |
| **`tsvpn-speedtest.sh`** | router | throughput pieces (site internet direct, tunnel via iperf3, via exit node) with router CPU load; driven by `tsvpn-provision.sh speed` |
| **`tsvpn-api.sh`** | router | the fixed menu of admin actions behind the page and the host's key |
| **`tsvpn-web.sh`**, **`tsvpn-web-cgi.sh`**, **`tsvpn-web.html`** | router | the admin page: uhttpd on the tailnet address, login/session/lockout, single-file UI |
| **`tsvpn-watchdog.sh`** | router (cron, 3 min) | restarts a hung `tailscaled`, reboots as a last resort (max once per 6 h); snapshots to `/etc/tsvpn/watchdog.log` |

### Day to day

```sh
# is this router correct? read-only, always safe
ssh root@<router> '/etc/tsvpn/tsvpn-audit.sh'

# fix almost anything, without rebooting
ssh root@<router> '/etc/tsvpn/tsvpn-selfheal.sh'

# what happened at last boot?
ssh root@<router> 'cat /var/log/tsvpn-selfheal.log'

# hotel WiFi that wants a click-through (§6)
ssh root@<router> '/etc/tsvpn/tsvpn-clone-mac.sh AA:BB:CC:DD:EE:FF'
ssh root@<router> '/etc/tsvpn/tsvpn-clone-mac.sh --reset'
```

### Where things land

```
/etc/tsvpn/node.json                   the only unique file on the router
/etc/tsvpn/tsvpn-*.sh                  the generic scripts
/etc/rc.local                          generated bootstrap: carries a copy of both
/etc/sysupgrade.conf                   lists /etc/tsvpn/
/etc/hotplug.d/iface/99-tsvpn-route    remote + collide only
/var/log/tsvpn-selfheal.log            what happened at the last boot
```

### Why rc.local carries a copy of everything

A GL.iNet firmware update **destroys `/root` and `/etc/hotplug.d/iface`**, resets
the firewall masquerade and the Tailscale route advertisements, and is *not*
guaranteed to honour `/etc/sysupgrade.conf`. It does preserve `/etc/rc.local`.

So the installer generates an `rc.local` that carries a full copy of
`/etc/tsvpn` and rewrites it on every boot. That is what makes an unattended
firmware update recoverable **with nobody on site**.

> Verified: deleting `/etc/tsvpn`, `/root/*.sh` and `/etc/hotplug.d/iface`
> outright, then running the bootstrap, restores a fully passing configuration
> with no intervention.

> ⚠️ **Never point `rc.local` at a script under `/root`.** That is the one
> arrangement guaranteed to fail — `rc.local` survives a flash and `/root` does
> not, so the boot log fills with `not found` while nothing is repaired.

### Changing settings on the router itself

Normally you edit the JSON in your repo and re-run the installer. When you
cannot reach your repo — a hotel, a phone — edit on the box, then persist it, or
the next flash restores the old values from the `rc.local` payload:

```sh
vi /etc/tsvpn/node.json
/etc/tsvpn/tsvpn-persist.sh     # copy it into the rc.local payload
/etc/tsvpn/tsvpn-selfheal.sh    # apply it
```

The audit warns when those two copies have drifted apart.

### Two things not to break

- The `rc.local` payload uses heredocs terminated by `__TSVPN_*__` markers. A
  script containing its own marker on a line of its own would truncate the file.
  The installer refuses to build one that does.
- `/etc/tsvpn` must never be the only copy. Both the installer and
  `tsvpn-persist.sh` keep `rc.local` in step; the audit flags any drift.

### Installing entirely by hand

The scripts are a convenience, not a dependency. With only a terminal:

```sh
mkdir -p /etc/tsvpn
# paste each tsvpn-*.sh into /etc/tsvpn/ under the same name
chmod +x /etc/tsvpn/*.sh

cat > /etc/tsvpn/node.json <<'JSON'
{ "deployment": "you@example.com", "node": "my-remote", "role": "remote",
  "targets": ["192.0.2.10"], "exit_node": "100.64.0.1" }
JSON

/etc/tsvpn/tsvpn-selfheal.sh     # apply and verify, immediately
sh /etc/tsvpn/tsvpn-install.sh   # generate rc.local so it survives a flash
```

The self-heal alone gives you a working router at once. Without the `rc.local`
step it will not survive a firmware update.

### Working on these routers over SSH

Busybox on GL.iNet has **no `nohup` and no `setsid`**, and its `nc` has no `-z`
or `-w` (a `nc -z` port scan silently prints usage and reports failure — use
`curl` instead). To run a repair that restarts the firewall without it dying
when the SSH session blips:

```sh
ssh root@<ROUTER> '( trap "" HUP; sh /tmp/repair.sh > /tmp/repair.log 2>&1 ) &'
```

Then poll the log on a second connection.

---

## 11. Letting a remote helper in

Sometimes you want someone else to look at a router: a friend who knows OpenWrt,
or a support person. This does **not** mean giving away your tailnet.

**Two separate gates have to open, and people routinely confuse them:**

| Gate | What it grants | Where you do it |
|---|---|---|
| Tailscale **node share** | can *reach* the router over the tunnel | web console |
| A **login credential** | can *act on* the router | password, or an SSH key |

Opening only the first gets them a router they cannot log in to. Opening only the
second is useless because they cannot route to it. You need both — and you close
both when they are done.

**Neither step requires you to be technical.** The share is point-and-click, and
the credential can simply be the router's admin password. Because
`firewall.tailscale0.input='ACCEPT'`, the **GL.iNet web admin UI is reachable
over the tunnel** — verified on both routers — so a helper can just open
`http://<router-tailnet-ip>/` in a browser and log in as they would on site. No
terminal, no keys, on either side.

### Why this is safe to offer — the tailnet is the lock

The credential is not what keeps someone out afterwards. **The tailnet is.**

These routers are not exposed to the internet. There is no port forwarding, no
DMZ, no public address — the only way to reach one remotely is to be on the
tailnet and have that specific node shared with you. So when you remove the
share, a helper who still remembers the root password has nothing to type it
into. The network path is gone.

That is a stronger position than credential-based access control, because:

- It is revoked **centrally**, from the console, without touching the router.
- It works even if you forget to change the password.
- It is **per node** — the share you remove is the only one they had.

And you still have the backstop: change the admin password (System → Admin
Password) and even a future access path is useless to them.

**The limits, so you are not surprised:**

- **The LAN side is unaffected.** Anyone physically at the site, or on that
  router's WiFi, can reach the admin UI at `192.168.8.1` with the password,
  share or no share. Tailscale gates the *remote* path only.
- **Revocation does not undo what they did while inside.** Someone with root
  could have added their own SSH key, a cron job, or a reverse tunnel out. None
  of that is removed by unsharing. For a friend or a support person this is
  hypothetical; for someone you do not trust, it is the reason to prefer a
  `command=` restricted key (Option B) over handing over root at all.
- **Check the session actually dropped.** Removing a share takes effect quickly
  but an established connection may linger briefly. Confirm rather than assume.

After a session where you handed over root, the tidy close is: remove the share,
change the password, and glance at `authorized_keys` to confirm only your own
key is listed.

```sh
ssh root@<ROUTER> 'awk "{print \$3}" /etc/dropbear/authorized_keys'
```

### 1. Share one node, not the tailnet

In the Tailscale console: Machines → select the router → the ⋯ menu → **Share**.
Send the invite to their email or hand them the share link. They accept it into
**their own** tailnet.

- Share **only the router they need**. Sharing the remote router does not give
  them the host, your phone, or your PC.
- Do **not** tick any option offering your node as an exit node. They need to
  reach the router, not route their traffic through your house.
- A shared node is visible to them at its normal `100.x` address.

This is much narrower than adding them as a tailnet user, which would expose
every machine you own.

### 2. Give them a login credential

Two options. Pick on how much you trust them and how cleanly you want to revoke.

#### Option A — the admin password (simplest, non-technical)

Just tell them the GL.iNet admin password. It is the same credential as the web
portal and as `root` over SSH, so it gets them either interface. Nothing to
install, nothing to configure.

What you are accepting:

- **No clean revocation.** The only way to withdraw it is to change the password
  — which also changes the web admin password, and breaks anything else using it.
- **No audit.** Everyone using the password is indistinguishable in the logs.
- **Probably both routers.** If you reused the password, you have handed over the
  other one too.
- **Full root.** It cannot be restricted to particular commands.

Reasonable for a trusted person doing a one-off. **Change the password afterwards**
— that is the revocation step, and it is easy to forget precisely because
nothing appears to be left behind.

#### Option B — their SSH key (revocable, restrictable)

Needs a terminal, but revokes cleanly and can be locked down. Ask for their
**public** key — never accept, or send, a private key.

```sh
ssh root@<ROUTER> 'echo "ssh-ed25519 AAAA...their-key helper-2026-09-06" \
  >> /etc/dropbear/authorized_keys'
```

Put something identifying in the comment — who, and when. That comment is the
only thing that will tell you which line to delete later.

**Narrow it if you can.** `authorized_keys` options restrict a key without
restricting the account:

```sh
# read-only: this key can ONLY run the health check, nothing else
command="tailscale status; ip route get 8.8.8.8",no-port-forwarding ssh-ed25519 AAAA...their-key helper
```

Verified working on these routers' dropbear: the forced command overrides
whatever they type. Genuinely useful for "look at it and tell me what you see."
Without `command=`, a key on a GL.iNet router is **root** — full control, with no
read-only mode.

### What sharing one node still exposes

Both gates are **per node** — a share covers one machine, and an
`authorized_keys` line covers one router. To let someone into two routers you do
all of this twice. That granularity is the point.

But "root on one router" is not the same as "isolated to one router":

- **The routers can reach each other** over the tailnet. Verified: each can ping
  the other's `100.x` address.
- **The admin password is probably the same on both.** Root can read
  `/etc/shadow` and crack it offline at leisure. If you reused the password —
  most people do — that is a path to the other router.
- **A shared router is inside the tunnel.** Root on the remote router can reach
  the target device via the subnet route, and egress through your exit node as
  the host site's IP.
- Root can also `tailscale logout` or rewrite the config, which costs you a site
  visit (§2).

So share with someone you would trust in your house, or use a `command=`
restricted key, which avoids every item above.

If you find yourself doing this repeatedly for the same person, stop using shares
and set up proper ACL access with tags and a user group instead — that is
designed for ongoing multi-node access, whereas shares are designed to be
temporary.

### Making both gates console-only — Tailscale SSH

Tailscale can provide the SSH server itself, with access governed by the
**tailnet policy file instead of `authorized_keys`**. Supported on these routers
(`tailscale up --ssh`; confirmed available on 1.92.5, off by default).

The appeal: once it is set up, granting and revoking a helper is entirely console
and policy work. Nobody has to SSH in to add or delete a key, so the owner can do
it alone. It also gives per-session audit in the console, which
`authorized_keys` cannot.

The catch: **enabling it is a technical, one-time job** — turning it on per
router and writing `ssh` rules into the policy file. It removes the terminal from
the day-to-day grant/revoke, not from the setup.

```sh
tailscale set --ssh          # per router, once
```

Then add `ssh` rules to the policy file naming who may connect as which user.
With no rules, nothing is permitted — it fails closed, so enabling the flag alone
does not open access.

> Verify the behaviour for **externally shared** users before relying on it for
> that case. Sharing and SSH policy are separate systems, and how a shared-in
> user is matched by `ssh` rules is worth confirming on your own tailnet rather
> than assuming. For helpers already inside your tailnet it is straightforward.

Leaving it off is a perfectly reasonable choice — `authorized_keys` is simpler,
has no policy file to get wrong, and works when the control plane is unreachable.

### 3. Revoke when they are done

Two things to close — the share, and the credential. Neither alone is enough.

**Remove the share:** console → Machines → the shared node → ⋯ → remove the
share. Point-and-click, same as granting it.

**Then the credential, depending on which you gave:**

*If you gave the password (Option A)* — change it. In the GL.iNet UI:
System → Admin Password. That is the entire revocation, and it is easy to skip
because nothing visibly remains. Remember it also changes the `root` SSH
password, so update any saved logins of your own. If you reused that password on
the other router, change it there too.

*If you installed their key (Option B)* — delete the line and confirm what is
left:

```sh
ssh root@<ROUTER> 'grep -v "helper-2026-09-06" /etc/dropbear/authorized_keys > /tmp/ak \
  && cat /tmp/ak > /etc/dropbear/authorized_keys && rm /tmp/ak'

ssh root@<ROUTER> 'awk "{print \$3}" /etc/dropbear/authorized_keys'
```

> Revoking the share alone leaves their key on the router — it would work again
> the moment they are re-shared, or from the site's own LAN. Removing the key
> alone leaves them able to reach the router and try password auth. Do both.

A firmware update does **not** clear an added key: `/etc/dropbear/` survives
(§8 of the guide). Revoke deliberately; do not assume it lapses.

---
