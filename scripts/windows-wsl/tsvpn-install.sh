#!/bin/sh
# ============================================================
#  tsvpn-install.sh — install or update tsvpn on THIS WSL
#  instance. Run inside WSL, as root.
#
#    sudo sh tsvpn-install.sh <node.json>
#
#  There is no push script for this platform: WSL is your own
#  machine, so copy the folder in and run it here.
#
#  Idempotent. Re-run any time.
#  Needs the instance already authenticated: sudo tailscale up
# ============================================================
set -e

SRC=$(cd "$(dirname "$0")" && pwd)
NODEJSON=$1
SCRIPTS="tsvpn-lib.sh tsvpn-selfheal.sh tsvpn-audit.sh"

[ "$(id -u)" = "0" ] || { echo "run as root: sudo sh $0 $*" >&2; exit 1; }

if [ -z "$NODEJSON" ]; then
	if [ -f /etc/tsvpn/node.json ]; then NODEJSON=/etc/tsvpn/node.json
	else sed -n '2,14p' "$0" | sed 's/^#\{1,2\} \{0,1\}//'; exit 2; fi
fi
[ -f "$NODEJSON" ] || { echo "no such file: $NODEJSON" >&2; exit 1; }

command -v python3 >/dev/null 2>&1 || { echo "python3 is required (it reads node.json)" >&2; exit 1; }

# ---------- WSL prerequisites, checked before anything is changed ----------
grep -qi microsoft /proc/version 2>/dev/null || echo "note: this does not look like WSL; scripts/rasp-pi/ is the better fit"

FATAL=""
[ "$(ps -p 1 -o comm= 2>/dev/null)" = "systemd" ] || FATAL="$FATAL systemd"
[ -c /dev/net/tun ] || FATAL="$FATAL tun"
command -v tailscale >/dev/null 2>&1 || FATAL="$FATAL tailscale"

if [ -n "$FATAL" ]; then
	echo
	echo "CANNOT PROCEED. Missing:$FATAL"
	case "$FATAL" in *systemd*)
		echo
		echo "  systemd is not running as PID 1. Without it there is nothing to start"
		echo "  tailscaled at boot. Enable it, then restart the distro from Windows:"
		echo "      printf '[boot]\\nsystemd=true\\n' | sudo tee -a /etc/wsl.conf"
		echo "      wsl --shutdown          (run this in PowerShell, then reopen WSL)";;
	esac
	case "$FATAL" in *tun*)
		echo
		echo "  /dev/net/tun is missing — Tailscale cannot create its interface."
		echo "  Update WSL from PowerShell:  wsl --update";;
	esac
	case "$FATAL" in *tailscale*)
		echo
		echo "  Install Tailscale INSIDE WSL (the Windows client is a separate node):"
		echo "      curl -fsSL https://tailscale.com/install.sh | sh"
		echo "      sudo tailscale up";;
	esac
	echo
	echo "Nothing has been changed."
	exit 1
fi

ROLE=$(python3 - "$NODEJSON" <<'PY'
import json,sys
try: d=json.load(open(sys.argv[1]))
except Exception as e: sys.exit("node.json is not valid JSON: %s"%e)
r=d.get("role")
if r!="host": sys.exit('WSL supports role="host" only; got %r. A WSL instance cannot be a remote — see the README.'%(r,))
for t in d.get("targets",[]):
    if "/" in str(t) or ":" in str(t): sys.exit('target %r must be a bare IPv4 address'%t)
print(r)
PY
)
echo "node.json valid: role=$ROLE"

tailscale status >/dev/null 2>&1 || {
	echo "tailscaled is not responding, or this node is not logged in."
	echo "Run 'sudo tailscale up' first — authenticating is the one step no script can do."
	exit 1; }

command -v dnsmasq >/dev/null 2>&1 || echo "note: dnsmasq absent — see README section 5 before pointing a remote at this host"

# ---------- install ----------
mkdir -p /etc/tsvpn /var/log
for s in $SCRIPTS; do
	if [ -f "$SRC/$s" ]; then cat "$SRC/$s" > "/etc/tsvpn/$s"
	elif [ -f "/etc/tsvpn/$s" ]; then :
	else echo "missing $s — copy the whole scripts/windows-wsl/ folder across" >&2; exit 1; fi
done
[ "$NODEJSON" = "/etc/tsvpn/node.json" ] || cat "$NODEJSON" > /etc/tsvpn/node.json
chmod +x /etc/tsvpn/*.sh
chmod 600 /etc/tsvpn/node.json
echo "installed /etc/tsvpn/"

cat > /etc/systemd/system/tsvpn-selfheal.service <<'UNIT'
[Unit]
Description=tsvpn — rebuild the private-VPN configuration
Wants=network-online.target
After=network-online.target tailscaled.service dnsmasq.service
StartLimitIntervalSec=600
StartLimitBurst=4

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/etc/tsvpn/tsvpn-selfheal.sh
StandardOutput=truncate:/var/log/tsvpn-selfheal.log
StandardError=inherit
Restart=on-failure
RestartSec=60

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable tsvpn-selfheal.service >/dev/null 2>&1
echo "systemd unit installed and enabled"

echo
echo "running the self-heal ..."
/etc/tsvpn/tsvpn-selfheal.sh
