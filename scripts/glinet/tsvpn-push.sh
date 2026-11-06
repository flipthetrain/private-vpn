#!/bin/sh
# ============================================================
#  tsvpn-push.sh — convenience wrapper. Copies this scripts/
#  folder plus one node.json to a router and runs the installer
#  there. Run from YOUR machine.
#
#    ./tsvpn-push.sh <router> <node.json>
#
#  e.g.  ./tsvpn-push.sh 192.168.8.1   ../../networks/you@example.com/my-host.json
#        ./tsvpn-push.sh 100.64.0.2    ../../networks/you@example.com/my-remote.json
#
#  <router> is any address that reaches it: 192.168.8.1 when you
#  are on its own WiFi, or its 100.x tailnet address from anywhere.
#
#  This does nothing tsvpn-install.sh cannot do on its own — it
#  just saves you the copy step. If ssh is awkward (a browser
#  terminal, say), copy the files across by hand and run
#  tsvpn-install.sh on the router instead.
# ============================================================
set -e

ROUTER=$1
NODEJSON=$2
SSH=${TSVPN_SSH:-ssh}
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPTS="tsvpn-lib.sh tsvpn-selfheal.sh tsvpn-audit.sh tsvpn-fix-route.sh tsvpn-clone-mac.sh tsvpn-persist.sh tsvpn-test-exit.sh tsvpn-speedtest.sh tsvpn-watchdog.sh tsvpn-api.sh tsvpn-web.sh tsvpn-web-cgi.sh tsvpn-web.html tsvpn-install.sh"
STAGE=/tmp/tsvpn-install

if [ -z "$ROUTER" ] || [ -z "$NODEJSON" ]; then
	sed -n '2,20p' "$0" | sed 's/^#\{1,2\} \{0,1\}//'
	exit 2
fi
[ -f "$NODEJSON" ] || { echo "no such file: $NODEJSON" >&2; exit 1; }
for s in $SCRIPTS; do
	[ -f "$HERE/$s" ] || { echo "missing $HERE/$s" >&2; exit 1; }
done

echo "copying to $ROUTER:$STAGE ..."
$SSH "root@$ROUTER" "mkdir -p $STAGE"
for s in $SCRIPTS; do
	$SSH "root@$ROUTER" "cat > $STAGE/$s" < "$HERE/$s"
done
$SSH "root@$ROUTER" "cat > $STAGE/node.json" < "$NODEJSON"

echo
$SSH "root@$ROUTER" "sh $STAGE/tsvpn-install.sh $STAGE/node.json"
