#!/bin/sh
# ============================================================
#  tsvpn-install.sh — install or update tsvpn on THIS Mac.
#  Run on the Mac, as root.
#
#    sudo sh tsvpn-install.sh <node.json>
#
#  Or let tsvpn-push.sh do the copy and this step from another
#  machine, if Remote Login is enabled.
#
#  What it does:
#    1. checks prerequisites, changing nothing if any are missing
#    2. copies the generic scripts to /etc/tsvpn/
#    3. installs <node.json> beside them
#    4. installs a LaunchDaemon that re-applies everything at boot
#    5. runs the self-heal, then the audit
#
#  Idempotent. Re-run any time.
#  Needs the standalone Tailscale build, signed in.
# ============================================================
set -e

SRC=$(cd "$(dirname "$0")" && pwd)
NODEJSON=$1
SCRIPTS="tsvpn-lib.sh tsvpn-selfheal.sh tsvpn-audit.sh"
PLIST=/Library/LaunchDaemons/com.tsvpn.selfheal.plist

[ "$(id -u)" = "0" ] || { echo "run as root: sudo sh $0 $*" >&2; exit 1; }

if [ -z "$NODEJSON" ]; then
	if [ -f /etc/tsvpn/node.json ]; then NODEJSON=/etc/tsvpn/node.json
	else sed -n '2,18p' "$0" | sed 's/^#\{1,2\} \{0,1\}//'; exit 2; fi
fi
[ -f "$NODEJSON" ] || { echo "no such file: $NODEJSON" >&2; exit 1; }

# ---------- 1. validate + prerequisites ----------
TSVPN_NODE="$NODEJSON"; export TSVPN_NODE
. "$SRC/tsvpn-lib.sh"
tsvpn_load || exit 1
tsvpn_check || exit 1
echo "node.json valid: role=$ROLE targets=${TARGETS:-<none>}"

TS=$(tsvpn_tailscale) || {
	echo ""
	echo "Tailscale is not installed." >&2
	echo "  Get the STANDALONE build from https://tailscale.com/download/mac" >&2
	echo "  (not the Mac App Store version - see below), then run: tailscale up" >&2
	echo "Nothing has been changed." >&2
	exit 1; }

if tsvpn_is_appstore_build; then
	echo ""
	echo "This Mac has the Mac App Store build of Tailscale." >&2
	echo "" >&2
	echo "  It is sandboxed and CANNOT advertise subnet routes or act as an exit" >&2
	echo "  node, so it cannot be a host however it is configured. Replace it" >&2
	echo "  with the standalone .pkg from https://tailscale.com/download/mac" >&2
	echo "" >&2
	echo "Nothing has been changed." >&2
	exit 1
fi

"$TS" status >/dev/null 2>&1 || {
	echo ""
	echo "Tailscale is installed but this Mac is not signed in." >&2
	echo "  Run '$TS up' first - authenticating is the one step no script can do." >&2
	echo "Nothing has been changed." >&2
	exit 1; }

# ---------- 2. install ----------
mkdir -p /etc/tsvpn
for s in $SCRIPTS; do
	if [ -f "$SRC/$s" ]; then cat "$SRC/$s" > "/etc/tsvpn/$s"
	elif [ -f "/etc/tsvpn/$s" ]; then :
	else echo "missing $s — copy the whole scripts/macos/ folder across" >&2; exit 1; fi
done
[ "$NODEJSON" = "/etc/tsvpn/node.json" ] || cat "$NODEJSON" > /etc/tsvpn/node.json
chmod +x /etc/tsvpn/*.sh
chmod 600 /etc/tsvpn/node.json
chown -R root:wheel /etc/tsvpn
echo "installed /etc/tsvpn/"

# ---------- 3. run at boot ----------
# A LaunchDaemon, not a login item: forwarding and pf must be restored before
# anyone logs in, and on a headless Mac nobody ever does.
cat > "$PLIST" <<'PLISTEOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.tsvpn.selfheal</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/sh</string>
        <string>/etc/tsvpn/tsvpn-selfheal.sh</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/var/log/tsvpn-selfheal.log</string>
    <key>StandardErrorPath</key>
    <string>/var/log/tsvpn-selfheal.log</string>
</dict>
</plist>
PLISTEOF
chown root:wheel "$PLIST"
chmod 644 "$PLIST"
plutil -lint "$PLIST" >/dev/null || { echo "generated plist is malformed; not loading" >&2; exit 1; }

launchctl bootout system/com.tsvpn.selfheal 2>/dev/null || true
if launchctl bootstrap system "$PLIST" 2>/dev/null; then
	echo "LaunchDaemon com.tsvpn.selfheal bootstrapped"
else
	launchctl load -w "$PLIST" 2>/dev/null && echo "LaunchDaemon loaded (legacy launchctl)" \
		|| echo "could not load the LaunchDaemon; it will start at next boot" >&2
fi

# ---------- 4. apply + verify ----------
echo
echo "running the self-heal ..."
/etc/tsvpn/tsvpn-selfheal.sh
