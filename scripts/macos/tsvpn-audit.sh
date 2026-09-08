#!/bin/sh
# ============================================================
#  tsvpn-audit.sh — verify every design requirement on this Mac.
#
#  Read-only: it changes nothing, so it is always safe to run,
#  including before this machine has ever joined a tailnet. The
#  Tailscale checks will fail in that state and everything else
#  will still tell you whether the machine is ready.
#
#  Exit status: 0 = everything passed, 1 = at least one FAIL.
#
#  Generic. All values come from /etc/tsvpn/node.json.
# ============================================================
. "${TSVPN_DIR:-/etc/tsvpn}/tsvpn-lib.sh"
tsvpn_load || exit 1

P=0; F=0; W=0
ok(){ echo "  PASS  $1"; P=$((P+1)); }
no(){ echo "  FAIL  $1"; F=$((F+1)); }
wn(){ echo "  WARN  $1"; W=$((W+1)); }
inf(){ echo "        $1"; }

echo "=== tsvpn audit: ${NODE:-$(hostname)} — $(date) ==="
echo
echo "-- identity --"
if [ "$ROLE" = "host" ]; then ok "role = host"
else no "role = $ROLE — macOS supports host only (see README section 9)"; fi
inf "deployment: ${DEPLOYMENT:-<unset>}"
inf "macos     : $(sw_vers -productVersion 2>/dev/null) ($(sw_vers -buildVersion 2>/dev/null)) $(uname -m)"
inf "targets   : ${TARGETS:-<none>}"

echo
echo "-- tailscale --"
TS=$(tsvpn_tailscale)
if [ -n "$TS" ]; then ok "tailscale CLI found ($TS)"; else no "tailscale CLI not found — see README section 2"; fi
if tsvpn_is_appstore_build; then
	no "this is the Mac App Store build — it CANNOT advertise routes or be an exit node"
	inf "replace it with the standalone .pkg from tailscale.com/download/mac"
else
	ok "not the sandboxed App Store build"
fi
TSIP=""
if [ -n "$TS" ]; then
	if "$TS" status >/dev/null 2>&1; then ok "tailscaled responding"
	else no "tailscaled not responding, or this Mac is not signed in — run: $TS up"; fi
	TSIP=$("$TS" ip -4 2>/dev/null | head -1)
fi
[ -n "$TSIP" ] && ok "tailnet address $TSIP" || no "no tailnet address — this Mac has not joined the tailnet yet"
PREFS=""
[ -n "$TS" ] && PREFS=$("$TS" debug prefs 2>/dev/null)

echo
echo "-- installation --"
for f in tsvpn-lib.sh tsvpn-selfheal.sh tsvpn-audit.sh; do
	[ -x "${TSVPN_DIR:-/etc/tsvpn}/$f" ] && ok "$f installed" || no "$f MISSING"
done
if [ -f /Library/LaunchDaemons/com.tsvpn.selfheal.plist ]; then
	ok "LaunchDaemon installed (runs at boot)"
	launchctl print system/com.tsvpn.selfheal >/dev/null 2>&1 \
		&& ok "LaunchDaemon loaded" \
		|| wn "LaunchDaemon present but not loaded — it will load at next boot"
else
	no "LaunchDaemon MISSING — forwarding and NAT will not come back after a reboot"
fi
[ -f "$TSVPN_LOG" ] && inf "last self-heal: $(head -1 "$TSVPN_LOG" 2>/dev/null)" || wn "no $TSVPN_LOG yet (written at boot)"

echo
echo "-- forwarding --"
# macOS clears this on every boot, which is the whole reason for the LaunchDaemon.
[ "$(sysctl -n net.inet.ip.forwarding 2>/dev/null)" = "1" ] \
	&& ok "net.inet.ip.forwarding = 1 (live value — the only one that matters)" \
	|| no "IP forwarding is off — nothing routes through this Mac"
grep -q '^net.inet.ip.forwarding=1' /etc/sysctl.conf 2>/dev/null \
	&& inf "/etc/sysctl.conf also asks for it; honoured on some macOS versions, ignored on others" \
	|| inf "persistence comes from the LaunchDaemon, which re-applies it each boot"

echo
echo "-- nat (pf) --"
# Without this a target replies to a 100.x address it cannot route to, so subnet
# routes fail while the exit node looks perfectly healthy.
EGRESS=$(route -n get default 2>/dev/null | awk '/interface:/{print $2; exit}')
inf "egress interface: ${EGRESS:-<none>}"
[ -f /etc/pf.anchors/tsvpn ] && ok "/etc/pf.anchors/tsvpn present" || no "pf anchor file missing"
PFCONF="${TSVPN_DIR:-/etc/tsvpn}/pf.conf"
if [ -f "$PFCONF" ]; then
	ok "$PFCONF present (generated; Apple's /etc/pf.conf is not modified)"
	grep -q '^nat-anchor "tsvpn"' "$PFCONF" && ok "it declares the tsvpn anchor" \
		|| no "it does not declare the tsvpn anchor — pf would ignore the rule"
	pfctl -n -f "$PFCONF" >/dev/null 2>&1 && ok "it parses" || no "it does NOT parse — run the self-heal"
else
	no "$PFCONF missing — run the self-heal"
fi
grep -q '^nat-anchor "tsvpn"' /etc/pf.conf 2>/dev/null \
	&& wn "Apple's /etc/pf.conf still contains a tsvpn anchor from an older version of these scripts; harmless, but you can remove that line" \
	|| ok "Apple's /etc/pf.conf is unmodified"
pfctl -s info 2>/dev/null | head -1 | grep -qi enabled && ok "pf is enabled" || no "pf is disabled — NAT is not being applied"
if pfctl -a tsvpn -s nat 2>/dev/null | grep -q 'nat on'; then
	ok "NAT rule live in the tsvpn anchor"
	inf "$(pfctl -a tsvpn -s nat 2>/dev/null | head -1)"
else
	no "no NAT rule live in the tsvpn anchor — run the self-heal"
	inf "without it a target replies to a 100.x address it cannot route to, so"
	inf "subnet routes fail while the exit node looks perfectly healthy"
fi

echo
echo "-- host role --"
if [ -n "$PREFS" ]; then
	echo "$PREFS" | grep -q '"0.0.0.0/0"' && ok "advertising exit node 0.0.0.0/0" || no "NOT advertising the exit node"
	for t in $TARGETS; do
		echo "$PREFS" | grep -q "\"$t/32\"" && ok "advertising route $t/32" || no "NOT advertising $t/32"
	done
	echo "$PREFS" | grep -qE '"(192\.168\.[0-9]+|10\.[0-9]+\.[0-9]+)\.0/24"' \
		&& wn "a whole /24 is advertised — design 3.1 wants a /32 per device" \
		|| ok "no whole-LAN route advertised (design 3.1)"
else
	no "could not read Tailscale preferences — is this Mac signed in?"
fi

echo
echo "-- dns for the tailnet (design 3.5) --"
if [ -x /opt/homebrew/sbin/dnsmasq ] || [ -x /usr/local/sbin/dnsmasq ]; then
	inf "dnsmasq is installed; see README section 5"
else
	wn "macOS ships no DNS forwarder, so this host cannot answer lookups for a REMOTE."
	inf "Laptops and phones are unaffected: they get DNS through the exit node."
	inf "For a remote, advertise your site's resolver as a target and point the"
	inf "remote's dns_upstream at it. README section 5."
fi
inf "this Mac resolves via: $(scutil --dns 2>/dev/null | awk '/nameserver\[0\]/{print $3; exit}')"

echo
echo "-- name resolution --"
# dscacheutil uses the system resolver and is always present on macOS.
dscacheutil -q host -a name github.com 2>/dev/null | grep -q ip_address \
	&& ok "this Mac resolves names" || no "name resolution FAILS on this Mac"

echo
echo "-- targets --"
if [ -z "$TARGETS" ]; then
	inf "no targets configured (exit node only — fine if you just want to egress here)"
else
	for t in $TARGETS; do
		ping -c1 -W3000 "$t" >/dev/null 2>&1 && ok "$t reachable from this Mac" \
			|| no "$t NOT reachable from this Mac — a remote will not reach it either"
	done
fi

echo
echo "=== $P passed, $F failed, $W warnings ==="
[ $F -eq 0 ] || exit 1
