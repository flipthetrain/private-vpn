#!/bin/sh
# ============================================================
#  tsvpn-push.sh — convenience wrapper. Copies this scripts/pi5/
#  folder plus one node.json to a Pi and runs the installer there.
#  Run from YOUR machine.
#
#    ./tsvpn-push.sh <[user@]host> <node.json>
#
#  e.g.  ./tsvpn-push.sh pi@192.168.1.50 ../../networks/you@example.com/pi-host.json
#        ./tsvpn-push.sh pi@100.64.0.3   ../../networks/you@example.com/pi-remote.json
#
#  <host> is any address that reaches it: a LAN address while you
#  are next to it, or its 100.x tailnet address from anywhere.
#
#  Uses sudo on the Pi, so it may prompt for that user's password
#  (the session is interactive for exactly that reason).
#
#  This does nothing tsvpn-install.sh cannot do on its own — it
#  just saves you the copy step.
# ============================================================
set -e

TARGET=$1
NODEJSON=$2
SSH=${TSVPN_SSH:-ssh}
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPTS="tsvpn-lib.sh tsvpn-selfheal.sh tsvpn-audit.sh tsvpn-fix-route.sh tsvpn-clone-mac.sh tsvpn-setup-ap.sh tsvpn-install.sh"
STAGE=/tmp/tsvpn-install

if [ -z "$TARGET" ] || [ -z "$NODEJSON" ]; then
	sed -n '2,20p' "$0" | sed 's/^#\{1,2\} \{0,1\}//'
	exit 2
fi
[ -f "$NODEJSON" ] || { echo "no such file: $NODEJSON" >&2; exit 1; }
for s in $SCRIPTS; do
	[ -f "$HERE/$s" ] || { echo "missing $HERE/$s" >&2; exit 1; }
done

echo "copying to $TARGET:$STAGE ..."
$SSH "$TARGET" "mkdir -p $STAGE"
for s in $SCRIPTS; do
	$SSH "$TARGET" "cat > $STAGE/$s" < "$HERE/$s"
done
$SSH "$TARGET" "cat > $STAGE/node.json" < "$NODEJSON"
$SSH "$TARGET" "chmod +x $STAGE/*.sh"

echo
$SSH -t "$TARGET" "sudo sh $STAGE/tsvpn-install.sh $STAGE/node.json"
