---
name: tsvpn-new-router
description: Build a factory-fresh GL.iNet router into a private-VPN host or remote (client) with minimal manual steps, or replace a host, or repair/re-audit an existing router. Use when the user says they bought/plugged in a new GL.iNet, wants a new remote/client/"stream-<name>" router, a new private-VPN network, a replacement host, or to re-check one. Drives scripts/glinet/tsvpn-provision.sh and prompts the user only for steps a person must do.
---

# New GL.iNet router → private VPN

The repo is the private-vpn repo (the folder holding `scripts/glinet/` and
`networks/`). Find it first: this skill's own folder is `<repo>/.claude/skills/`
(resolve the symlink if it was linked into `~/.claude/skills/`), or check memory.
All commands below run from the repo root.

```
P=scripts/glinet/tsvpn-provision.sh      # every step; run with no args for help
```

Read `scripts/glinet/README.md` sections 2–4 if anything here is unclear: it is
the reference this skill automates. Design rules in `README.md` (top level).

**Ground rules**
- `networks/<tailnet>/` is PRIVATE and git-ignored. Never commit it, never copy
  addresses or names from it into tracked files. `git check-ignore` any new file.
- Prompt the user ONLY at the marked **YOU** steps. Everything else, just do,
  and report what happened in plain words. Batch the YOU steps so they happen in
  as few trips to the phone/console as possible.
- Every `$P` step is idempotent: on failure, fix the cause and re-run that step.
- Writes to a router change a live network. A remote is somebody's only internet
  path: re-installing one drops their clients for a few seconds; say so first if
  it is already deployed at its site.

## 0. Which path?

Look in `networks/` for existing deployments (folders named after a tailnet),
then ask (AskUserQuestion) unless the user already said:

| Path | When | Asks the user for |
|---|---|---|
| **A. Add a remote** | a deployment exists with a host | the new router's **name** (e.g. `vpn-lakehouse`), optional client WiFi name + key |
| **B. New network** | no deployment yet (or a new tailnet) | tailnet account, host name, the **target device IPs** at the host site, whether the site's DNS is a single box (Pi-hole) |
| **C. Replace the host** | host hardware died / rebuilt | nothing new: reuses the host's file |
| **D. Repair / re-audit** | an existing router misbehaves | which router |

Path B builds the host with the steps below and then runs path A once per
remote. Name routers `<prefix>-<site>` in the style of the existing ones.

## 1. Admin machine checks (all paths, silent unless broken)

- `~/.ssh/id_ed25519.pub` exists (else `ssh-keygen -t ed25519`, with the user's OK).
- `python3` and `ssh` are present.
- This machine's Tailscale is on the deployment's tailnet, or 100.x addresses
  will not answer: `tailscale status` must list the deployment's routers. If it
  is on another tailnet, tell the user to run `! sudo tailscale switch <tailnet>`.

## 2. Path B only — one-time tailnet setup (YOU)

1. **YOU:** a Tailscale account for the tailnet (README §2.1). Record the
   tailnet name; it becomes the folder `networks/<tailnet>/`.
2. **YOU:** paste into the tailnet policy file (Access Controls), with one
   route per target (README §2.4):
   ```json
   "autoApprovers": {
     "exitNode": ["autogroup:admin"],
     "routes": { "<TARGET_IP>/32": ["autogroup:admin"] }
   }
   ```
   Skipping this is a silent failure; the host audit catches it ("NOT approved").
3. Ask: the target device IP(s) at the host site (give them DHCP reservations on
   the site router so they never move), and whether the site's DNS server is a
   single box such as a Pi-hole. If yes, pass the ISP router as fallback.
4. `$P new-host <tailnet> <host-name> <target-ip>... [--dns-upstream <isp-router-ip>]`

## 2. Path A — the node file (silent)

`$P new-remote <tailnet> <name>` writes `networks/<tailnet>/<name>.json`,
deriving exit node, targets and collide from the host already there. Show it.

## 3. Unbox and bootstrap (YOU, once, on a phone)

Tell the user, in one message:

> 1. Plug the router's **WAN** port into the network it will run on (for a
>    remote being prepared at your desk: your own network is fine). Never the
>    LAN port into an existing network. Power it on, wait ~2 minutes.
> 2. On your phone, join its WiFi (name and password on the sticker
>    underneath). Stay connected if it warns "no internet".
> 3. Open **http://192.168.8.1**, finish the wizard: set the **admin password**
>    (save it in your password manager) and the **timezone**.
> 4. **System → Upgrade:** install the latest firmware if offered (~5 min).
> 5. **Security → Remote Access Control:** turn on **SSH** (WAN side) and apply.
>    I close this again myself at the end.
> 6. Tell me the admin password (used once to install my key; it stays in this
>    chat's local history, so change it later if that matters to you).

Meanwhile find it: `$P discover` (GL.iNet MACs; the new one is the WAN address
that is not an existing router's). Then:

```
TSVPN_PASSWORD='<pw>' $P bootstrap <wan-ip> networks/<tailnet>/<name>.json
```

It reports model, firmware and Tailscale versions. Firmware older than the
others is fine (self-heal covers 4.8.x without chrony) but recommend step 4.

## 4. Join the tailnet (YOU: one approval)

```
$P login <wan-ip> networks/<tailnet>/<name>.json
```

Give the user the printed URL plus, in the same message: sign in as the
tailnet's account (NOT their everyday one), approve, then **Machines → <name> →
⋯ → Disable key expiry**. When they confirm:

```
$P login <wan-ip> networks/<tailnet>/<name>.json --wait     # records tailnet_ip
```

(With `TSVPN_AUTHKEY` set, login needs no browser; key expiry still needs the
console unless the key is tagged.)

## 5. Install, lock down, verify (silent)

```
$P install  <wan-ip> networks/<tailnet>/<name>.json   # remote: preflights the exit node
$P lockdown <100.x>                                   # closes WAN SSH; tunnel-only admin
$P audit    <100.x>
$P test     <100.x>                                   # remote only: live path + speed
```

Optional: `$P speed <tailnet> <name>` for a throughput report naming the
bottleneck. It saturates the lines for ~1 minute: ask first if the site is in use.

`install` must pass with 0 failed. Expected warnings: "no self-heal log yet"
(until first boot); on a remote prepared at the host's own site, "collision is
ACTIVE" (dormant once at its real site, unless that site uses the same range).
Host: the audit must show the exit node and every route **APPROVED**; if not,
send the user to the console (Machines → host → Edit route settings) or step 2.2.

Then reboot it (`ssh root@<100.x> reboot`), wait for it to return to the tailnet
(~1–2 min) and re-run audit: this proves the boot-time self-heal on this unit.

## 6. Client WiFi (YOU: a name and key)

Ask for the WiFi name and password the site's devices will join (≥ 8 chars).
`$P wifi <100.x> <ssid> <key>` sets `<ssid>` (2.4G) and `<ssid>-5g`. Warn first:
the phone on the sticker WiFi will drop. Remind them to save it in their password
manager.

## 7. Record and hand off

- Update `networks/<tailnet>/README.md` (private): the new router's tailnet IP,
  firmware, WiFi name (not the key), last-verified date and audit counts.
- Remote: tell the user it is ready to ship. At the site: plug **WAN** into
  that site's router, power on, nothing else. From here, after it is placed:
  `$P audit <100.x>` and `$P test <100.x>` confirm it remotely.
- Do not commit anything under `networks/`. Commit script changes only if the
  user asks.

## Path C — replace the host

Build the new host with steps 3–5 using the EXISTING host file (bootstrap,
login --wait records its new `tailnet_ip`). Remove the dead node in the console.
Then `$P reinstall-remotes <tailnet>`: it rewrites every remote's `exit_node` and
re-pushes. Remotes are reachable over the tailnet even while their exit node is
down. Update the ACL if target IPs changed.

## Path D — repair / re-audit

`$P audit <100.x>` first. Most fixes are `$P install <100.x> <file>` (re-applies
everything). Remote with clients complaining: `$P test <100.x>`. Unreachable on
the tailnet: README §"If you cannot reach the router at all" — someone at the
site joins its WiFi; the most common cause is a wrong clock (no RTC; see the
clock section of tsvpn-selfheal.sh) or the uplink cable in a LAN port.
