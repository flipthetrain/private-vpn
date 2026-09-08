# scripts/

One folder per hardware platform. The **design** is platform-independent and
lives in [`../README.md`](../README.md);
the **implementation** is not, so each platform gets its own set rather than one
set of omnipotent scripts riddled with `if`s.

| Folder | Platform | Status |
|---|---|---|
| [`glinet/`](glinet/) | GL.iNet travel routers, firmware 4.x (tested: GL-MT3000) | **in service** |
| `pi5/` | Raspberry Pi 5 | planned |

Pick the folder that matches the box in front of you and read its `README.md`.

---

## Why per-platform, not one script set

Almost everything the GL.iNet scripts do exists *because of how GL.iNet firmware
behaves* — a firmware update wipes `/root`, replaces `/etc/hotplug.d/iface`,
resets the firewall masquerade, and re-derives the Tailscale route
advertisements from its own UI toggles. A Pi running Debian has none of those
problems and none of those tools: no `uci`, no `/etc/config/firewall`, no
vendor plugin. It has systemd, `nftables` and a package manager instead.

Trying to serve both from one file would mean a script that is mostly branches,
where neither path is easy to read and only one is ever tested. Two honest
implementations of the same contract are easier to verify by hand — which is the
whole point of this repo.

---

## The contract every platform implements

Anything under `scripts/` should satisfy the same interface, so the guide, the
network files and your habits transfer unchanged between platforms.

### 1. One JSON file per router

The only thing unique to a box. Same schema everywhere:

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

`role` is `host` or `remote`; `exit_node` and `collide` are remote-only.
Templates: [`../networks/example-host.json`](../networks/example-host.json),
[`../networks/example-remote.json`](../networks/example-remote.json).

### 2. The same script names and jobs

| Script | Job |
|---|---|
| `tsvpn-push.sh` | from your machine: copy this folder + a node JSON to the box, run the installer |
| `tsvpn-install.sh` | on the box: install everything, arrange for it to survive an OS/firmware update, apply, audit |
| `tsvpn-selfheal.sh` | on the box: rebuild the whole configuration from `node.json`. Idempotent, runs at boot |
| `tsvpn-audit.sh` | on the box: read-only; verify every requirement in README.md §3. Exit 1 on any failure |
| `tsvpn-clone-mac.sh` | on the box: captive-portal MAC cloning (the platform README's captive-portal section) |

### 3. The same behaviour

- **`node.json` is the only unique file.** Everything else is byte-identical
  across every router of every deployment on that platform.
- **The self-heal is also the provisioner.** Configuring a new box is: write the
  JSON, run the installer. There is no separate configuration step.
- **Idempotent.** Re-running anything is always safe.
- **The audit is the definition of correct**, and it verifies the design
  requirements — not the implementation's own choices. A passing audit on a Pi
  should mean the same thing as a passing audit on a GL.iNet.
- **It must survive an unattended OS or firmware update** with nobody on site.
  *How* is platform-specific: GL.iNet embeds a copy of everything in
  `/etc/rc.local`, because that is the one file its updates preserve. A Pi would
  use a systemd unit and ordinary package management.

### 4. The same install shape

```sh
./scripts/<platform>/tsvpn-push.sh <box> networks/<tailnet>/<node>.json
```

---

## Adding a platform

1. Read README.md §3 — the six design requirements are what you are implementing.
   They are stated in terms of routing, NAT, DNS and firewall behaviour, not in
   terms of any particular tool.
2. Copy the contract above, not the code.
3. Write `tsvpn-audit.sh` **first**. It is the specification, and it tells you
   when the rest is done.
4. Keep every address out of the scripts. If you find yourself wanting one, it
   belongs in `node.json`.
