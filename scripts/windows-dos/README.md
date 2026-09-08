# scripts/windows-dos/ — native Windows

The implementation for **Windows 10/11 running the Tailscale Windows client**.
For other hardware see [`../README.md`](../README.md) — the design is shared,
the scripts are not.

> **"dos" means the native Windows side**, as opposed to
> [`../windows-wsl/`](../windows-wsl/). The scripts are **PowerShell**, not
> `.bat`: `cmd.exe` cannot parse JSON, query network adapters, or register a
> scheduled task, so a batch implementation would be a worse tool for the same
> job. PowerShell 5.1 ships with every supported Windows, so there is nothing
> to install.

> ## ⚠️ Partly verified
>
> - **Verified on real Windows 11 Pro:** `tsvpn-lib.ps1` and `tsvpn-audit.ps1`
>   were executed. Config parsing, role refusal, target validation, adapter and
>   service queries, Tailscale detection and the audit's exit code all behave
>   correctly.
> - **Not verified:** `tsvpn-install.ps1` and `tsvpn-selfheal.ps1`. They need
>   Administrator and would reconfigure the machine, so they were not run.
>   Enabling IP forwarding and RRAS (§6.1) is the least certain part.
>
> The audit is read-only and always safe. Run it first, and let it tell you
> what is actually true.

## Contents

| | |
|---|---|
| [§1 What Windows is good for here](#1-what-windows-is-good-for-here) | and what it is not |
| [§2 Requirements](#2-requirements) | |
| [§3 First-time setup](#3-first-time-setup) | |
| [§4 Installing](#4-installing) | the one command |
| [§5 DNS — read this before adding a remote](#5-dns--read-this-before-adding-a-remote) | the one real gap |
| [§6 What the scripts configure](#6-what-the-scripts-configure) | |
| [§7 Verification and troubleshooting](#7-verification-and-troubleshooting) | |
| [§8 Bring-up checklist](#8-bring-up-checklist) | **read this for the first machine** |
| [§9 Why there is no remote role](#9-why-there-is-no-remote-role) | |

---

## 1. What Windows is good for here

**As a host — yes.** A desktop that is on anyway makes a perfectly good exit
node and subnet router. You get your household IP while travelling, and you can
reach devices at the host site from your laptop or phone. No extra hardware.

Its weakness is that it is a general-purpose computer: it sleeps, it reboots for
updates, and someone might turn it off. A host that is asleep is a host that is
down, and every remote depending on it goes dark. If anyone else relies on this
deployment, put the host on hardware that stays up — see
[`../glinet/`](../glinet/) or [`../pi5/`](../pi5/).

**As a remote — no.** Not supported, and the scripts refuse it rather than
half-doing it. See §9.

## 2. Requirements

- **Windows 10 or 11**, any edition. PowerShell 5.1 (built in) is enough.
- **[Tailscale for Windows](https://tailscale.com/download/windows)**, signed in.
- **Administrator** to install. The audit runs fine without it.

Nothing else to install.

> **If you edit these scripts**, keep them **pure ASCII**. Windows PowerShell 5.1
> reads a file without a byte-order mark as ANSI, so a UTF-8 em dash decodes into
> a stray `”` — which PowerShell treats as a quote character, and the script
> stops parsing. This bit during development; it is why there is not a single
> curly quote or dash in the `.ps1` files.

## 3. First-time setup

1. **Tailscale account and tailnet** — sign up at
   [tailscale.com](https://tailscale.com); the free tier is enough. Note the
   tailnet name and the MagicDNS suffix.
2. **Install Tailscale and sign in.** Give the machine a recognisable name in
   the console — it is what you will look for when something breaks. This is the
   one step no script can do.
3. **Tailnet settings that only exist in the console.** Both fail silently if
   skipped; they are per-tailnet, not per-platform, so they are described once in
   the [root README](../../README.md#4-tailnet-settings): **disable key expiry**,
   and add **`autoApprovers`** for each address you intend to reach.
4. **Stop the machine sleeping**, or accept that the tunnel drops when it does:

   ```powershell
   powercfg /change standby-timeout-ac 0
   powercfg /change hibernate-timeout-ac 0
   ```

## 4. Installing

Copy this folder and your JSON onto the machine, open **PowerShell as
Administrator**, and run:

```powershell
cd C:\path\to\windows-dos
.\tsvpn-install.ps1 -NodeJson .\my-host.json
```

If PowerShell refuses to run the script, it is the execution policy:

```powershell
powershell -ExecutionPolicy Bypass -File .\tsvpn-install.ps1 -NodeJson .\my-host.json
```

There is **no push script** for this platform — Windows has no SSH server by
default, so there is nothing to push to.

**Idempotent.** Re-run any time: to change a setting, to repair, or after a
Tailscale upgrade. It ends by auditing itself and exits non-zero on failure.

### The node file

```json
{
  "deployment": "you@example.com",
  "node": "my-host",
  "role": "host",
  "targets": ["192.0.2.10"]
}
```

`role` must be `host`. `targets` are bare IPv4 addresses at the host site to
make reachable — no `/32`, no port. Full field reference:
[`../../networks/README.md`](../../networks/README.md).

Installed to `C:\ProgramData\tsvpn\`, with `node.json` locked down to
Administrators and SYSTEM.

## 5. DNS — read this before adding a remote

**Windows client editions ship no DNS forwarder.** A GL.iNet or Pi host runs
dnsmasq so a remote can forward its clients' lookups through the tunnel. Windows
has nothing equivalent, and installing a third-party DNS server is more than
this repo should be doing for you.

What that does and does not affect:

| Who | Affected? |
|---|---|
| Your laptop or phone using the exit node | **No.** Tailscale routes their DNS through the exit node itself |
| A **remote router** with clients behind it | **Yes.** It has nothing to forward to |

If you only travel with your own devices, ignore this section entirely.

### If you do want a remote, point it at your site's resolver

Do not install a DNS server. Advertise the resolver your host site already uses
as a **target**, and point the remote at it directly:

```jsonc
// on the Windows host — 192.168.1.1 is your router, which is already a resolver
{ "role": "host", "targets": ["192.0.2.10", "192.168.1.1"] }

// on the remote
{ "role": "remote", "targets": ["192.0.2.10", "192.168.1.1"],
  "exit_node": "100.64.0.1", "dns_upstream": ["192.168.1.1"] }
```

Then add `192.168.1.1/32` to `autoApprovers` in the tailnet ACL like any other
target.

This satisfies the design exactly, and is arguably cleaner than running dnsmasq:
the remote's clients resolve through **the same resolver every device at the
host site uses**, and the query egresses from the host site's IP. Resolver
egress and client egress match, which is the whole point of design §3.5. It
works on any platform — GL.iNet and Pi hosts can use it too.

The catch: your router must answer DNS from the host machine's subnet (nearly
all home routers do), and it is one more `/32` to approve.

## 6. What the scripts configure

`tsvpn-selfheal.ps1` applies all of it and re-applies at every boot. This
section is so you can read what it did.

### 6.1 IP forwarding — the least certain part

A host forwards exit-node and subnet-route traffic. Windows needs this in three
places, and they do different jobs:

| What | Why |
|---|---|
| `Set-NetIPInterface -Forwarding Enabled` on the Tailscale and physical adapters | takes effect immediately |
| `IPEnableRouter=1` in the registry | what survives a reboot |
| the **RemoteAccess** (RRAS) service running | what actually moves packets between interfaces |

The self-heal does all three, and the audit checks all three separately, because
any one alone silently half-works. On client editions RRAS is usually disabled;
the script enables and starts it, and reports rather than fails if it cannot.

**Exit-node use does not depend on RRAS.** If RRAS will not start, egress still
works and only subnet routes suffer — which is why the audit reports them
separately.

### 6.2 Advertisements

```powershell
tailscale set --advertise-exit-node --advertise-routes=<targets as /32s>
```

Re-applied every boot, because a `tailscale up` typed without the flags, or a
client upgrade, silently clears them.

### 6.3 Staying configured

A scheduled task, `tsvpn-selfheal`, running as SYSTEM at startup with a
one-minute delay so tailscaled is up first. A scheduled task rather than a
service because the work is a short one-shot, which is exactly what a startup
trigger is for.

Log: `C:\ProgramData\tsvpn\selfheal.log`.

## 7. Verification and troubleshooting

```powershell
# is this machine correct? read-only, always safe, works without admin
C:\ProgramData\tsvpn\tsvpn-audit.ps1

# fix almost anything (needs admin)
C:\ProgramData\tsvpn\tsvpn-selfheal.ps1
```

| Symptom | Likely cause | Fix |
|---|---|---|
| Everything dark at a remote site | this host asleep, rebooted, or off | wake it; then §3 step 4 |
| Exit node works, targets unreachable | RRAS not running, or forwarding off | §6.1; check the three items separately |
| Advertisements empty after an update | Tailscale client upgrade reset preferences | run the self-heal |
| Script "cannot be loaded because running scripts is disabled" | execution policy | use the `-ExecutionPolicy Bypass` form in §4 |
| Remote's clients resolve nothing | this host has no DNS forwarder | §5 |
| Audit says forwarding off right after a reboot | registry value applied, per-interface not yet | the scheduled task fixes it a minute in; check the log |

## 8. Bring-up checklist

For the first Windows host, since the installer has not been run on hardware.
Do it at the machine, not over Remote Desktop — enabling forwarding and RRAS
can disturb networking.

1. `tailscale status` shows a `100.x` address.
2. Run the **audit** first, before installing. It is read-only and tells you the
   starting state. Expect failures — nothing is configured yet.
3. Run the installer from an elevated PowerShell.
4. Run the audit again. Expect all PASS except possibly RRAS.
5. From another tailnet device, select this machine as exit node and confirm
   your public IP becomes the host site's.
6. From another tailnet device, `ping` one of your targets. **If this fails but
   step 5 worked, it is RRAS or forwarding** (§6.1) — that is the split this
   design expects you to hit.
7. Reboot. Wait two minutes. Run the audit again — this proves the scheduled
   task works, which is the whole basis of it staying configured.

## 9. Why there is no remote role

A remote is a router for other devices: NAT, DHCP, a DNS forwarder, and a
**kill-switch** that drops forwarded traffic when the tunnel is down.

Windows can be coaxed into the first three with Internet Connection Sharing. It
cannot do the fourth. Windows Firewall filters traffic **to and from** the
machine; it does not reliably filter traffic being **routed through** it. So the
kill-switch could not be made trustworthy.

A kill-switch you cannot trust is worse than none. It fails open, silently, and
the devices behind it keep working — while leaking out the local uplink with the
site's own IP and the site's own DNS. That is exactly the failure this design
exists to prevent, and it is undetectable from the couch.

So the scripts refuse `role: remote` outright rather than shipping something
that appears to work. For a remote, use [`../glinet/`](../glinet/) or
[`../pi5/`](../pi5/) on hardware built for it.
