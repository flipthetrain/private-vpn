# private-vpn

Take your network with you. Being away should be indistinguishable from being
there — the same devices, the same services, the same subscriptions, whether you
are in your own living room or on someone else's WiFi three states over.

Two things break when you leave. Your own devices stop answering, because they
only listen on their local network: media servers, tuners, NAS, cameras,
printers. And your subscriptions notice — licensed content binds to your
household IP address, so it refuses to play, quietly degrades, or loses track of
your hardware. This repairs both by putting your traffic back on your own
connection, so nothing has to know you left.

Usually that network is your home. It does not have to be — the same thing works
for a small office or a workshop — so throughout this repo it is called the
**host site**, whatever it happens to be.

The same tunnel makes hotel, airport and overseas WiFi safe to use. Everything
leaves your device encrypted and lands on a machine you own — no browsing, no
DNS lookups, nothing in cleartext for the local network to read or tamper with,
and no VPN company in the middle to trust instead. You stay perfectly
identifiable to the services you use, which is the entire point, while staying
opaque to whatever network you happen to be sitting on.

Built on [Tailscale](https://tailscale.com). No port forwarding, no DMZ, no
dynamic DNS, and neither site's existing router is reconfigured.

## What this assumes you can do

This is not a consumer appliance. The scripts do all the fiddly configuration
for you and check their own work, but they start from a machine that is already
on your tailnet, and they are driven from a terminal. Specifically, it is
assumed you can:

- **Create a Tailscale account and sign a machine in.** Making the tailnet,
  running `tailscale up`, opening the login URL it prints, and approving the
  machine in the console. Also finding a machine's `100.x` address there, and
  editing the tailnet's access-control policy to paste in a few lines of JSON
  (§4). None of this is hard, but none of it is automated here — signing in is
  the one step that cannot be.
- **Use SSH.** Connect to a machine, type a command, read what comes back. Copy
  files to it. Ideally set up a key so you are not retyping a password.
- **Read and edit a small JSON file.** Changing three or four values between
  quotes, and keeping the commas where they were.
- **Know your own network.** Which address range the host site uses, the
  address of the device there you want to reach, and the same for the site the
  remote will live at — that matters, because if the two ranges are the same
  there is a collision to deal with (§3.2).
- **Get physical access to each machine once**, at the beginning. Signing in to
  the tailnet has to happen at the machine. After that everything is remote.
- **Have administrative access**: the router's admin password, or `sudo` on a Pi.

If some of that is unfamiliar, your platform's README walks each step with the
exact commands — start with its Quick start and work down.

**Assumed about the hardware**, too: the host and the remote each attach to
their site's existing network by a normal uplink, and get an ordinary address by
DHCP. Nothing needs a static address, a port forwarded, a firewall rule, or any
change to the existing router at either site.

## Terminology

Three words, used consistently everywhere in this repo:

| Term | What it is |
|---|---|
| **host** | the machine at the **host site** — your house, office, wherever your own devices live. Advertises the exit node and the routes to those devices. Exactly one per deployment |
| **remote** | a machine at **another site**, which sends everything through the host. As many as you like |
| **client** | an ordinary device — a TV, a console, a phone, a laptop — that attaches to a remote over WiFi or its LAN port, and needs no configuration of its own |

A laptop or phone running the Tailscale app is also a client, and does not need
a remote at all — it can select the host as its exit node directly.

## The 30-second version

The **host** stays at the host site on your tailnet and does two jobs: it
advertises itself as an **exit node**, so your traffic leaves from the host
site's connection and IP-locked services stay happy; and it advertises **subnet
routes** to whichever devices there you want reachable.

From there you either run the Tailscale app on your own laptop or phone and pick
that exit node, or park a **remote** somewhere for gear that cannot run
Tailscale — TVs, sticks, consoles — which just joins its WiFi and inherits
everything.

You usually need both mechanisms: the exit node makes cloud services see the
host site's public IP, and the subnet route makes the private address they hand back
actually reachable (§2).

## What's in this repo

| Path | What it is |
|---|---|
| **this file** | the design: what gets built, and why each requirement exists. Platform-independent |
| **[`scripts/`](scripts/)** | one folder per hardware platform, and the contract they all implement |
| **[`scripts/glinet/`](scripts/glinet/)** | GL.iNet travel routers — host + remote. **Field-verified**, in service |
| **[`scripts/rasp-pi/`](scripts/rasp-pi/)** | Raspberry Pi / Debian — host + remote. Written, not run on hardware |
| **[`scripts/macos/`](scripts/macos/)** | macOS — **host only** |
| **[`scripts/windows-ps/`](scripts/windows-ps/)** | Windows 10/11 (PowerShell) — **host only** |
| **[`scripts/windows-wsl/`](scripts/windows-wsl/)** | Ubuntu under WSL2 — **host only** |
| **[`networks/`](networks/)** | your deployments: one small JSON file per machine. Git-ignored |

## Getting started

Three steps, whatever the hardware:

**1. Write one small JSON file per machine.** This is the entire configuration —
everything else is generic and identical everywhere.

```json
{
  "deployment": "you@example.com",
  "node": "my-remote",
  "role": "remote",
  "targets": ["192.0.2.10"],
  "exit_node": "100.64.0.1"
}
```

Copy [`networks/example-host.json`](networks/example-host.json) or
[`networks/example-remote.json`](networks/example-remote.json) into
`networks/<your-tailnet>/` and edit. See
[`networks/README.md`](networks/README.md).

**2. Get the machine onto your tailnet.** Sign in once, on the machine itself.
This is the one step no script can do.

**3. Copy the scripts across and run the installer.** It configures everything
and then verifies its own work.

The step-by-step for your hardware, from unboxing to troubleshooting:

| Your hardware | Read |
|---|---|
| GL.iNet travel router | [`scripts/glinet/README.md`](scripts/glinet/README.md) |
| Raspberry Pi / Debian | [`scripts/rasp-pi/README.md`](scripts/rasp-pi/README.md) |
| macOS | [`scripts/macos/README.md`](scripts/macos/README.md) |
| Windows 10/11 | [`scripts/windows-ps/README.md`](scripts/windows-ps/README.md) |
| Ubuntu under WSL2 | [`scripts/windows-wsl/README.md`](scripts/windows-wsl/README.md) |

Only GL.iNet and Raspberry Pi can be a **remote**. macOS, Windows and WSL are
**host only**, for reasons their READMEs set out.

---

# The design

Everything below is about *what must be true*, not about any particular box.
Each platform's README shows the concrete commands that make it true there.

## 1. What this builds

```
        REMOTE SITE                                  HOST SITE
   ──────────────────────────────        ────────────────────────────────

   clients that can't run                    ISP router
   Tailscale (TV, console, stick)                │
          │                                      ├── <TARGET_DEVICE>
          │ join its own LAN / WiFi              │   <TARGET_DEVICE_IP>
          ▼                                      │
       remote                                    │ uplink
     • selects that exit node                    ▼
     • --accept-routes                         host
          │                                  • advertises exit node 0.0.0.0/0
          │ uplink                           • advertises <TARGET_DEVICE_IP>/32
          ▼                                      │
   their ISP router                              │
          │                                      │
          └────► Tailscale tunnel ───────────────┘
                 traffic flows this way ──►      │
                                                 ▼
                                          internet egress =
                                          the HOST site's public IP
```

Both machines attach to their site's existing network by their **uplink** — the
WAN port on a travel router, the ethernet port on a Pi — and serve clients on
their own LAN/WiFi. Neither ISP router is reconfigured.

**Use this when** remote devices must believe they are on the host network. Two
distinct needs, often both at once:

1. **Reach things at the host site** — media servers, tuners, NAS, cameras,
   printers; anything that only answers on the host's own LAN. That is the
   **subnet route**, and
   you can advertise as many devices as you like (§3.1).
2. **Appear to be at the host site** — streaming and licensing services that geo-lock or
   IP-lock to your household and refuse or degrade elsewhere. That is the **exit
   node**, and it works because your traffic genuinely leaves from your own
   residential connection rather than a datacentre address.

### Two deployment shapes

| | **Fixed remote site** | **Travelling** |
|---|---|---|
| Example | a relative's house, a second home | hotel, family visit, on the road |
| What you deploy | a remote | nothing — just the Tailscale app |
| Serves | devices that *cannot* run Tailscale: TVs, sticks, consoles | your own laptop, phone, tablet |
| Read | all of this, then your platform's README | §5 below |

The host is identical for both, so building it for one gives you the other for
free. If you only ever travel with your own devices you need just the host and
§5 — no remote at all.

**Don't use this when** a plain Tailscale client would do and you do not care
where your traffic appears to come from.

## 2. The two mechanisms

Independent, separately approved, and easy to confuse.

| | **Subnet route** | **Exit node** |
|---|---|---|
| Advertises | `<TARGET_DEVICE_IP>/32` | `0.0.0.0/0` + `::/0` |
| Gives you | reachability of specific addresses at the host site | *all* traffic egressing from the host site |
| Flag | `--advertise-routes=` | `--advertise-exit-node` |
| Needed for | talking to the device | making cloud services *think* you are at the host site |

### Why you usually need both

The subnet route alone suffices for a device you address directly. You also need
the exit node whenever **cloud discovery** is involved: the app asks a vendor API
"what is registered to my public IP?", and the answer is only right if your
traffic egresses from the host site's IP. The vendor hands back a *private*
address, which the subnet route then carries.

### It only goes one way

**Only the host advertises anything.** A remote selects the exit node and accepts
routes; it offers nothing back. So devices at the host site cannot reach devices
behind a remote, and that is deliberate — you are extending your own network
outward, not merging someone else's into it.

Two things enforce it, independently:

- a remote **NATs its clients** into the tunnel (§3.3), so they have no presence
  on the tailnet at all
- nothing installs a route to a remote's LAN, because nothing advertises one

Watch for the second one drifting. Some router firmware advertises the box's own
LAN by default, and `tailscale set --exit-node=…` does **not** clear an existing
advertisement. It then sits unapproved and inert — until somebody clicks approve
in the console, at which point that whole site becomes reachable from your
tailnet. Every platform's self-heal clears advertisements on a remote explicitly,
and its audit fails if one reappears.

If you ever do want it bidirectional, the knob is: advertise the remote's LAN,
approve it, and drop the masquerade. That is a real change in exposure, not a
toggle.

## 3. Design requirements

Six things that must be true. Each is a deliberate part of the design, not a
workaround — and **each fails silently if missed**.

### 3.1 Advertise the narrowest route that works

A `/32` per device, never the whole `/24`. A whole-LAN route exposes every device
at the host site to the remote site, and makes subnet collisions (§3.2) far more
likely.

### 3.2 Avoid — or absorb — subnet collisions

If the remote site's LAN uses the same range you are routing into
(`192.168.1.0/24` is the classic), the local route wins over the tunnel and
clients silently reach a device on **their own network** instead of the one at
the host site.

The fix is to pin each target `/32` to the tunnel's routing table ahead of
whatever sends that range to the local one. Both platforms implement this, and
both re-apply it on a timer, because the rule that causes the problem tends to
be regenerated whenever the uplink comes up.

Cleanest prevention is to avoid the collision entirely by giving one site a
different LAN range. Keep the fix in place regardless: it does nothing when
there is no collision, and it is already there if a site's own router is later
swapped for a colliding one.

### 3.3 The remote must NAT its clients into the tunnel

Client traffic that enters the tunnel still carrying a private source address
arrives at the host from a range the host routes to its **own** LAN, and is
dropped. The remote must masquerade its clients to its own tailnet address
first.

Symptom if missing, and it is a distinctive one: **the remote itself works over
the tunnel, and nothing behind it does.**

> On the host, do **not** add a second layer of NAT. Something already handles
> it there — the host's own WAN zone, or `tailscaled` itself — and doubling up
> breaks return traffic rather than fixing anything.

### 3.4 MSS/MTU clamping

The tunnel's MTU is smaller than the LAN's. Without clamping, small packets get
through and large ones do not.

Symptom if missing: **interfaces load, video and large transfers stall.** It
looks like a slow connection rather than a broken one, which is what makes it
hard to spot.

### 3.5 DNS must resolve through the host

Services detect consumer VPNs by correlating **the resolver's egress IP with the
client's egress IP**. A mismatch is the tell, and it is the one people leave
behind after getting the traffic path right.

The rule is the same as for every other packet: **nothing resolves locally.** A
client's lookup takes the same path its traffic does.

```
client → remote's resolver → tunnel → host's resolver → the HOST site's resolver
```

The host resolves via **the network it is plugged into** — the same resolver
every other device at the host site uses — and serves those answers to the tailnet. The
remote forwards to the host and to nothing else. So a lookup made at the remote
site is answered by the host site's resolver and egresses at the host site's IP,
exactly as it would from a sofa there. No public resolver appears anywhere in
the chain, so
there is no second egress path for anyone to correlate.

| Machine | Must | Must not |
|---|---|---|
| **remote** | forward only to the host | be able to fall back to this site's resolver |
| **host** | forward to its own network's resolver, and answer queries arriving over the tunnel | pin a hardcoded public resolver |

Refusing the local fallback is the load-bearing half. It means **DNS fails
closed**: a broken tunnel costs clients their DNS entirely, rather than leaking
to the local resolver and quietly giving you away. Each machine's own lookups
may still go direct — that carries no client traffic and keeps the box
manageable on-site when the tunnel is down.

### Two ways to satisfy this

The requirement is about *where the query comes out*, not about which software
answers it. So there are two valid arrangements:

| | How | Use when |
|---|---|---|
| **Host resolves** | the host runs a forwarder (dnsmasq) on its tailnet address; the remote points at the host | the host is a router or a Linux box — the default on GL.iNet and Pi |
| **Resolver as a target** | advertise the host site's own resolver as a `/32` target; the remote's `dns_upstream` points straight at it | the host has no forwarder — Windows — or you would rather not run one |

Both end with the remote's clients resolving through the host site's own
resolver, at the host site's IP. The second needs no software on the host at
all: the resolver is just another device you have made reachable, exactly like
a media server. It costs one extra `autoApprovers` entry.

Travelling laptops and phones need neither: with an exit node selected,
Tailscale routes their DNS through the exit node itself.

### 3.6 No IPv6 unless the tunnel carries it

If the LAN hands out IPv6 that the tunnel does not carry, clients leak over v6
while v4 looks perfect. Unless you have verified v6 egress through the exit
node, do not hand out IPv6 addresses on the remote's LAN, and make sure the
kill-switch (§3.3's companion) covers v6 as well as v4.

## 4. Tailnet settings

Two settings live only in the Tailscale console, and **both fail silently** if
skipped: nothing errors, the feature simply never works. They are per-tailnet,
not per-platform.

### Disable key expiry — per machine

Machines → select it → ⋯ → **Disable key expiry**.

Do this for **every** machine. By default node keys expire in about six months,
and re-authenticating requires being at the machine. A remote whose key expires
means a site visit.

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
the console, and re-approved whenever a machine is rebuilt. Approval failures are
**silent** — no warning anywhere, the route simply never appears at the far end.

Add one `routes` entry per device you intend to reach. **Adding a device later
means coming back here**; forgetting that you must is what costs an afternoon.

## 5. Using it from your own laptop or phone

**Devices that cannot run Tailscale** (TVs, sticks, consoles, IoT): connect them
to a **remote's** WiFi or LAN ports. They inherit the tunnel with no
configuration of their own. That is the entire reason a remote exists.

**Devices that can**: install the Tailscale app and sign in. To also use the
exit node:

```sh
tailscale set --exit-node=<HOST_TAILNET_IP> --exit-node-allow-lan-access
tailscale set --exit-node=            # turn it back off
tailscale set --accept-routes         # needed to reach advertised subnet routes
```

On Windows and macOS the exit node is a tray or menu-bar picker; on iOS and
Android it is on the app's main screen.

### Before you do anything sensitive on a strange network

Banking, email, work — anything you would not do on a stranger's network.

1. Turn on **Exit Node** → your host.
2. **Check it took effect**: search *"what is my IP"*. It should show **the host
   site's address** — the one you would see sitting there. If it shows the
   café's, the tunnel is not on. Stop.

That is the whole routine. Everything then leaves your device sealed until it
reaches the host, including the lookups your browser makes to find websites in
the first place — the part most setups leak, and the part a hostile network
watches (§3.5).

**What it protects you from:** everyone else on that network, and whoever runs
it. They see one encrypted connection to the host and nothing else.

**What it does not do:** it does not make you anonymous. Your bank still knows
exactly who you are — and will be *happier*, because you are arriving from your
usual address instead of a strange country, which is what usually triggers
the frozen-account phone call.

> **Exit node availability is ACL-gated.** A node not granted
> `autogroup:internet` reports `no exit nodes found` even when the host is
> perfectly healthy and other machines are using it. Check the ACL before
> debugging the host.

---

## Keeping it working

Every platform here installs the same two things, because the failure mode is
always the same: **the configuration goes away quietly and nothing tells you.**

- **A self-heal** that rebuilds the entire configuration from that machine's
  JSON, runs at every boot, and is safe to run by hand at any time. It is also
  the provisioner — there is no separate "configure" step.
- **An audit** that checks every requirement in §3, prints PASS/FAIL, and exits
  non-zero if anything failed. Read-only, so it is always safe to run.

```sh
<platform path>/tsvpn-audit.sh      # is this machine correct?
<platform path>/tsvpn-selfheal.sh   # fix almost anything, without rebooting
```

What they are defending against differs by platform — a router firmware update
actively destroys the setup, while a Debian box merely reboots or gets a package
reinstalled — but the symptom is identical: the machine looks healthy in the
Tailscale console while the tunnel carries nothing.

**Always verify from a remote, never from the host.** Advertisements only prove
out from the far side of the tunnel.
