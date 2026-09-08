#!/bin/sh
# ============================================================
#  tsvpn-fix-route.sh — subnet-collision fix (design requirement 3.2 in README.md)
#
#  If the REMOTE site's LAN uses the same range the tunnel routes
#  into, GL.iNet installs a priority-0 policy rule pinning that
#  range to the local `main` table, which outranks Tailscale's
#  table 52. Clients then reach a device on THEIR network instead
#  of the one at the host site. This reinserts a /32 rule ahead of it.
#
#  Self-disabling: exits 0 when there is no collision, so it is
#  safe to leave installed and it re-arms itself automatically if
#  the site's router is ever swapped for a colliding one.
#
#  Re-run from an ifup hotplug hook AND cron, because GL.iNet
#  regenerates its rule on every WAN ifup and either trigger alone
#  can be missed.
#
#  Generic. All values come from /etc/tsvpn/node.json.
# ============================================================
. /etc/tsvpn/tsvpn-lib.sh
tsvpn_load || exit 1

[ "$ROLE" = "remote" ] || exit 0
[ -n "$COLLIDE" ] || exit 0
[ -n "$TARGETS" ] || exit 0

# Is the colliding range actually present on this site's network?
LOCAL=$(ip route | awk -v c="^${COLLIDE}" '$0 ~ c {print $1; exit}')
[ -z "$LOCAL" ] && exit 0

# Already ordered correctly for every target?
NEED=0
for t in $TARGETS; do
	ip rule list | head -10 | grep -q "to $t lookup 52" || NEED=1
done
[ $NEED -eq 0 ] && exit 0

ip rule del to "$COLLIDE" lookup main priority 0 2>/dev/null
for t in $TARGETS; do
	ip rule del to "$t/32" lookup 52 priority 0 2>/dev/null
	ip rule add to "$t/32" lookup 52 priority 0 2>/dev/null
done
ip rule add to "$COLLIDE" lookup main priority 0 2>/dev/null

logger -t tsvpn-route "reordered policy rules so $TARGETS use tailscale, not local $COLLIDE"
