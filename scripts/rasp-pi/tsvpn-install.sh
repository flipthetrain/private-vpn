#!/bin/sh
# ============================================================
#  tsvpn-install.sh — install or update the tsvpn system on THIS
#  machine. Runs ON the Pi, as root.
#
#    sudo sh tsvpn-install.sh <node.json>
#
#  Typical use: copy this whole scripts/rasp-pi/ folder plus the one
#  JSON file for this machine onto the Pi, then run it. Or let
#  tsvpn-push.sh do both steps from your own machine.
#
#  What it does:
#    1. checks prerequisites and tells you exactly what is missing
#    2. copies the generic scripts to /etc/tsvpn/
#    3. installs <node.json> as /etc/tsvpn/node.json
#    4. installs and enables the systemd units that re-apply the
#       configuration at every boot
#    5. runs the self-heal, then the audit
#
#  Idempotent. Re-run it any time, including to change settings.
#  Needs the machine already authenticated to the tailnet:
#      sudo tailscale up
# ============================================================
set -e

SRC=$(cd "$(dirname "$0")" && pwd)
NODEJSON=$1
SCRIPTS="tsvpn-lib.sh tsvpn-selfheal.sh tsvpn-audit.sh tsvpn-fix-route.sh tsvpn-clone-mac.sh tsvpn-setup-ap.sh"

[ "$(id -u)" = "0" ] || { echo "run as root: sudo sh $0 $*" >&2; exit 1; }

if [ -z "$NODEJSON" ]; then
	if [ -f /etc/tsvpn/node.json ]; then
		NODEJSON=/etc/tsvpn/node.json
		echo "no node.json given — reusing the installed /etc/tsvpn/node.json"
	else
		sed -n '2,25p' "$0" | sed 's/^#\{1,2\} \{0,1\}//'
		exit 2
	fi
fi
[ -f "$NODEJSON" ] || { echo "no such file: $NODEJSON" >&2; exit 1; }

# ---------- 1. validate + prerequisites ----------
command -v python3 >/dev/null 2>&1 || { echo "python3 is required (it reads node.json)" >&2; exit 1; }

ROLE=$(python3 - "$NODEJSON" <<'PY'
import json,sys
try: d=json.load(open(sys.argv[1]))
except Exception as e: sys.exit("node.json is not valid JSON: %s"%e)
r=d.get("role")
if r not in ("host","remote"): sys.exit('"role" must be "host" or "remote", got %r'%(r,))
if r=="remote" and not d.get("exit_node"): sys.exit('role=remote needs "exit_node": the host\'s 100.x address')
if r=="host" and d.get("exit_node"): sys.exit('role=host must not set "exit_node"')
for t in d.get("targets",[]):
    if "/" in str(t) or ":" in str(t): sys.exit('target %r must be a bare IPv4 address (no /32, no port)'%t)
print(r)
PY
)
echo "node.json valid: role=$ROLE"

MISSING=""
command -v tailscale >/dev/null 2>&1 || MISSING="$MISSING tailscale"
command -v dnsmasq   >/dev/null 2>&1 || MISSING="$MISSING dnsmasq"
[ "$ROLE" = "remote" ] && { command -v nft >/dev/null 2>&1 || MISSING="$MISSING nftables"; }
command -v traceroute >/dev/null 2>&1 || echo "note: traceroute not installed — one audit check will be skipped"

if [ -n "$MISSING" ]; then
	echo
	echo "MISSING PACKAGES:$MISSING"
	case "$MISSING" in *tailscale*)
		echo "  tailscale: curl -fsSL https://tailscale.com/install.sh | sh   (then: sudo tailscale up)";;
	esac
	OTHER=$(echo "$MISSING" | tr ' ' '\n' | grep -v '^tailscale$' | grep . | tr '\n' ' ')
	[ -n "$OTHER" ] && echo "  then: apt install -y $OTHER"
	echo
	echo "Install those and re-run. Nothing has been changed."
	exit 1
fi

tailscale status >/dev/null 2>&1 || {
	echo "tailscaled is not responding, or this node is not logged in."
	echo "Run 'sudo tailscale up' first — authenticating is the one step no script can do."
	exit 1
}

# dnsmasq and systemd-resolved both want port 53. resolved binds 127.0.0.53 only,
# which does not clash, but a stub listener on 0.0.0.0 would.
if ss -lnup 2>/dev/null | grep -q '0.0.0.0:53 .*systemd-resolve'; then
	echo "WARNING: systemd-resolved is listening on 0.0.0.0:53 and will fight dnsmasq."
	echo "         Set DNSStubListener=no in /etc/systemd/resolved.conf and restart it."
fi

# ---------- 2. install scripts + node.json ----------
mkdir -p /etc/tsvpn
for s in $SCRIPTS; do
	if [ -f "$SRC/$s" ]; then cat "$SRC/$s" > "/etc/tsvpn/$s"
	elif [ -f "/etc/tsvpn/$s" ]; then :
	else echo "missing $s — copy the whole scripts/rasp-pi/ folder across, not just the installer" >&2; exit 1; fi
done
[ "$NODEJSON" = "/etc/tsvpn/node.json" ] || cat "$NODEJSON" > /etc/tsvpn/node.json
chmod +x /etc/tsvpn/*.sh
chmod 600 /etc/tsvpn/node.json
echo "installed /etc/tsvpn/"

# ---------- 3. systemd units ----------
# Debian does not wipe /etc on upgrade, so unlike the GL.iNet build there is no
# payload to restore. What these defend against is a reboot, an nftables reload,
# a `tailscale up` typed without the flags — all silent.
cat > /etc/systemd/system/tsvpn-selfheal.service <<'UNIT'
[Unit]
Description=tsvpn — rebuild the private-VPN configuration
Documentation=file:///etc/tsvpn/
Wants=network-online.target
After=network-online.target tailscaled.service dnsmasq.service
StartLimitIntervalSec=600
StartLimitBurst=4

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/etc/tsvpn/tsvpn-selfheal.sh
# truncate, not append: this log is always "what happened at the last run"
StandardOutput=truncate:/var/log/tsvpn-selfheal.log
StandardError=inherit
# boot races (tailscaled still coming up) are common and self-correcting
Restart=on-failure
RestartSec=60

[Install]
WantedBy=multi-user.target
UNIT

cat > /etc/systemd/system/tsvpn-fix-route.service <<'UNIT'
[Unit]
Description=tsvpn — keep the host-site targets pinned to the tunnel
After=tailscaled.service

[Service]
Type=oneshot
ExecStart=/etc/tsvpn/tsvpn-fix-route.sh
UNIT

cat > /etc/systemd/system/tsvpn-fix-route.timer <<'UNIT'
[Unit]
Description=tsvpn — re-check target routing every 5 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
AccuracySec=30s

[Install]
WantedBy=timers.target
UNIT

systemctl daemon-reload
systemctl enable tsvpn-selfheal.service >/dev/null 2>&1
if [ "$ROLE" = "remote" ]; then
	systemctl enable --now tsvpn-fix-route.timer >/dev/null 2>&1
else
	systemctl disable --now tsvpn-fix-route.timer >/dev/null 2>&1 || true
fi
echo "systemd units installed and enabled"

# ---------- 4. apply + verify ----------
echo
echo "running the self-heal ..."
/etc/tsvpn/tsvpn-selfheal.sh
