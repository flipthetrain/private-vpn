#!/bin/sh
# ============================================================
#  tsvpn-fix-route.sh — make sure the host-site targets always go
#  down the tunnel (design requirement 3.2 in README.md).
#
#  On a remote, Tailscale sends unmarked traffic to table 52 via
#  an `ip rule` at priority ~5270. Anything that puts the target's
#  range in a table ahead of that wins instead, and clients
#  silently reaches a device on ITS OWN network rather than the
#  one at the host site. --exit-node-allow-lan-access deliberately creates
#  exactly that kind of rule for local subnets, so a remote site
#  whose LAN overlaps the range you route into is a real conflict.
#
#  The fix is to pin each target /32 to table 52 at a priority
#  ahead of everything except `local`.
#
#  Installed unconditionally on a remote: when there is no
#  collision these rules are a no-op (table 52 already routes the
#  target down the tunnel), and when a site is later swapped for a
#  colliding one they are already in place.
#
#  Idempotent. Re-run from the self-heal and from a systemd timer.
#  Generic. All values come from /etc/tsvpn/node.json.
# ============================================================
. /etc/tsvpn/tsvpn-lib.sh
tsvpn_load || exit 1

[ "$ROLE" = "remote" ] || exit 0
[ -n "$TARGETS" ] || exit 0

PRIO=1000

# Table 52 only exists once tailscaled is up and routing.
ip route show table 52 >/dev/null 2>&1 || exit 0

changed=0
for t in $TARGETS; do
	if ! ip rule list | grep -q "^$PRIO:.*to $t lookup 52"; then
		# delete any stale copy first so repeated runs cannot stack duplicates
		while ip rule del to "$t/32" lookup 52 priority $PRIO 2>/dev/null; do :; done
		ip rule add to "$t/32" lookup 52 priority $PRIO 2>/dev/null && changed=1
	fi
done

if [ $changed -eq 1 ]; then
	logger -t tsvpn-route "pinned $TARGETS to table 52 at priority $PRIO"
fi
exit 0
