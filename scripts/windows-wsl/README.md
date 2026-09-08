# scripts/windows-wsl/ — WSL (Ubuntu)

The implementation for **Ubuntu running under WSL2 on Windows**. For other
hardware see [`../README.md`](../README.md) — the design is shared, the scripts
are not.

> ## ⚠️ Partly verified
>
> - **Verified on real WSL2 (Ubuntu 24.04, systemd, NAT mode):**
>   `tsvpn-lib.sh` and `tsvpn-audit.sh` were executed. Config parsing, role
>   refusal, the WSL environment probes, Tailscale detection and the audit's
>   exit code all behave correctly.
> - **Not verified:** `tsvpn-install.sh` and `tsvpn-selfheal.sh`. They need root
>   and would reconfigure the machine, so they were not run.
>
> The audit is read-only and always safe. Run it first.

## Contents

| | |
|---|---|
| [§1 Is WSL the right place for this?](#1-is-wsl-the-right-place-for-this) | read this before anything else |
| [§2 Requirements](#2-requirements) | |
| [§3 First-time setup](#3-first-time-setup) | |
| [§4 Installing](#4-installing) | |
| [§5 DNS](#5-dns) | |
| [§6 What the scripts configure](#6-what-the-scripts-configure) | |
| [§7 Verification and troubleshooting](#7-verification-and-troubleshooting) | |
| [§8 Why there is no remote role](#8-why-there-is-no-remote-role) | |

---

## 1. Is WSL the right place for this?

**Be honest with yourself about this one.** WSL can be a host, and the scripts
work, but it is the most fragile option in this repo. The tunnel is up only
while the distro is running, and the distro stops when:

- you run `wsl --shutdown`, or Windows updates WSL
- Windows sleeps, hibernates, or reboots
- the last shell closes, on older WSL builds without systemd

A host that is down takes every remote depending on it dark, with no warning
beyond things quietly not working. **If anyone but you depends on this
deployment, do not host it on WSL** — use [`../glinet/`](../glinet/) or
[`../pi5/`](../pi5/).

Where WSL genuinely fits: you already develop in WSL, the machine is on anyway,
and you want your own laptop and phone to egress from the host site while
travelling. For that it is fine and costs you nothing extra.

> **WSL and the Windows Tailscale client are two different nodes.** Installing
> Tailscale inside WSL creates a second machine on your tailnet, with its own
> `100.x` address. That is intended — the WSL instance is the host, not Windows.
> If you would rather Windows itself were the host, use
> [`../windows-ps/`](../windows-ps/) instead. Do not try to do both.

## 2. Requirements

- **WSL2** with **Ubuntu** (tested against 24.04). WSL1 will not work — no TUN.
- **systemd enabled**, so tailscaled starts on its own:

  ```sh
  printf '[boot]\nsystemd=true\n' | sudo tee -a /etc/wsl.conf
  ```
  then, from PowerShell: `wsl --shutdown`, and reopen your shell.
- **`/dev/net/tun`** — present on current WSL. If missing, `wsl --update`.
- **Tailscale installed inside WSL**:

  ```sh
  curl -fsSL https://tailscale.com/install.sh | sh
  sudo tailscale up
  ```
- `dnsmasq` only if a remote will resolve through this host (§5).

The installer checks all of this and stops without changing anything if
something is missing.

> **A WSL quirk worth knowing:** the `tailscale` CLI fails when the working
> directory is a Windows path (`/mnt/c`, `/mnt/d`) — it cannot resolve its own
> cwd. `tsvpn-lib.sh` moves to `/` when it detects this, so the scripts are
> unaffected, but you will hit it running `tailscale` by hand from a project
> folder. `cd ~` first.

## 3. First-time setup

1. **Tailscale account and tailnet** — see the
   [root README](../../README.md#4-tailnet-settings).
2. **`sudo tailscale up`** inside WSL, and approve the machine. Name it
   something that makes clear it is the WSL instance, not Windows.
3. **Console settings**: disable key expiry, and add `autoApprovers` for each
   address you intend to reach. Both fail silently if skipped.
4. **Stop Windows sleeping**, or accept the host goes down with it:

   ```powershell
   powercfg /change standby-timeout-ac 0
   ```

## 4. Installing

Copy this folder and your JSON into WSL, then:

```sh
sudo sh tsvpn-install.sh my-host.json
```

There is **no push script** — WSL is your own machine, so run it here.

### The node file

```json
{
  "deployment": "you@example.com",
  "node": "wsl-host",
  "role": "host",
  "targets": ["192.0.2.10"]
}
```

`role` must be `host` (§8). Full field reference:
[`../../networks/README.md`](../../networks/README.md).

**Idempotent** — re-run any time. It ends by auditing itself.

## 5. DNS

If a remote router will forward its clients' lookups here, install dnsmasq:

```sh
sudo apt install dnsmasq
sudo /etc/tsvpn/tsvpn-selfheal.sh
```

The self-heal binds it to `tailscale0` and — deliberately — sets **no**
`no-resolv` and **no** `server=`. It forwards to whatever this instance
resolves with, which under WSL is the Windows host, which uses the host site's
own resolver. So a lookup made at a remote site is answered by the same resolver
every device at the host site uses, and egresses at the same address. That is
design §3.5 satisfied.

If you only use laptops and phones, skip this: they get DNS through the exit
node and never touch this host's resolver.

Alternatively — and this works on any platform — advertise your site's resolver
as a target and point the remote's `dns_upstream` at it directly. See
[`../windows-ps/README.md` §5](../windows-ps/README.md#5-dns--read-this-before-adding-a-remote),
which explains that approach in full.

## 6. What the scripts configure

`tsvpn-selfheal.sh` applies all of it, at every boot and on demand.

- **IP forwarding**, persisted in `/etc/sysctl.d/99-tsvpn.conf`. Traffic
  forwarded out of WSL is NAT'd again by Windows, which is why exit-node egress
  and subnet routes both come out with the host site's address.
- **`dnsmasq` on `tailscale0`**, if installed (§5).
- **`tailscale set --advertise-exit-node --advertise-routes=…`**, re-applied
  every boot because a bare `tailscale up` silently clears it.
- **`tsvpn-selfheal.service`**, a systemd oneshot at boot with
  `Restart=on-failure`, since races with tailscaled starting are common and
  self-correcting.

Log: `/var/log/tsvpn-selfheal.log`, truncated each run.

No firewall or NAT rules of our own: on Linux `tailscaled` installs the SNAT for
exit-node and subnet-route traffic itself. Adding a second layer breaks return
traffic rather than fixing anything.

## 7. Verification and troubleshooting

```sh
sudo /etc/tsvpn/tsvpn-audit.sh      # read-only, always safe
sudo /etc/tsvpn/tsvpn-selfheal.sh   # fixes almost everything
```

The audit reports the WSL specifics — systemd, `/dev/net/tun`, and the
networking mode — because those are what actually break here.

| Symptom | Likely cause | Fix |
|---|---|---|
| Host offline, nothing obviously wrong | the distro is not running | open a WSL shell; check Windows did not sleep |
| Nothing starts after a Windows reboot | systemd not enabled | §2; `wsl --shutdown` and reopen |
| Tailscale cannot start | `/dev/net/tun` missing | `wsl --update` from PowerShell |
| `tailscale` command errors oddly | cwd is a `/mnt/...` path | `cd ~` first |
| Targets unreachable, exit node fine | forwarding off, or the target does not answer from this machine | `sysctl net.ipv4.ip_forward`; ping the target from WSL directly |
| Remote's clients resolve nothing | no dnsmasq here | §5 |

### Networking mode

`wslinfo --networking-mode` reports `nat` or `mirrored`.

- **nat** (default): WSL is behind a NAT Windows manages. Outbound works, so
  hosting works. Nothing on your LAN can reach *into* WSL.
- **mirrored** (Windows 11): WSL shares the Windows host's addresses. Also fine,
  and slightly more direct for subnet routes.

Either is supported. The audit reports which you have because it changes what to
expect when debugging.

## 8. Why there is no remote role

A remote is the box other devices connect to — a TV joining its WiFi, a console
on its LAN port. Those devices need to route through it.

**They cannot route to a WSL instance.** In NAT mode it sits behind a NAT that
Windows manages, with no route in from the LAN and no way to hand one out. It
cannot run the DHCP server for a network it is not on, and it has no radio to
put an access point on.

This is a structural limit, not a missing feature, so the scripts refuse
`role: remote` outright. For a remote, use [`../glinet/`](../glinet/) or
[`../pi5/`](../pi5/).
