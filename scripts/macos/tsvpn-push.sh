#!/bin/sh
# ============================================================
#  tsvpn-push.sh — convenience wrapper. Copies this scripts/macos/
#  folder plus one node.json to a Mac and runs the installer.
#  Run from YOUR machine.
#
#    ./tsvpn-push.sh <[user@]host> <node.json>
#
#  e.g.  ./tsvpn-push.sh admin@192.168.1.20 ../../networks/you@example.com/mac-host.json
#        ./tsvpn-push.sh admin@100.64.0.4   ../../networks/you@example.com/mac-host.json
#
#  Needs Remote Login enabled on the Mac:
#    System Settings > General > Sharing > Remote Login
#
#  Uses sudo there, so it may prompt for that user's password.
#  If Remote Login is off, copy the folder over by any means and
#  run tsvpn-install.sh on the Mac instead.
# ============================================================
set -e

TARGET=$1
NODEJSON=$2
SSH=${TSVPN_SSH:-ssh}
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPTS="tsvpn-lib.sh tsvpn-selfheal.sh tsvpn-audit.sh tsvpn-install.sh"
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
