#!/bin/sh
# ============================================================
#  tsvpn-audit.sh — verify every design requirement on this WSL
#  instance. Read-only: it changes nothing, always safe to run.
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
have(){ command -v "$1" >/dev/null 2>&1; }

echo "=== tsvpn audit: ${NODE:-$(hostname)} — $(date) ==="
echo
echo "-- identity --"
if [ "$ROLE" = "host" ]; then ok "role = host"
else no "role = $ROLE — WSL supports host only (a remote needs devices to route through it)"; fi
inf "deployment: ${DEPLOYMENT:-<unset>}"
inf "distro    : $(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown}")"
inf "tailscale : $(tailscale version 2>/dev/null | head -1)"
inf "targets   : ${TARGETS:-<none>}"

echo
echo "-- wsl environment --"
wsl_is_wsl && ok "running under WSL" || wn "this does not look like WSL — scripts/pi5/ is the better fit"
wsl_has_systemd && ok "systemd is PID 1 (services can start at boot)" \
	|| no "systemd is NOT PID 1 — nothing will start tailscaled automatically. Set systemd=true in /etc/wsl.conf, then 'wsl --shutdown'"
wsl_has_tun && ok "/dev/net/tun present" || no "/dev/net/tun missing — Tailscale cannot create its interface. Run 'wsl --update' from Windows"
MODE=$(wsl_net_mode)
case "$MODE" in
	mirrored) ok "networking mode: mirrored (this instance shares the Windows host's addresses)" ;;
	nat)      ok "networking mode: nat (outbound works; nothing on the LAN can route TO this instance)" ;;
	*)        wn "networking mode: $MODE — could not determine" ;;
esac
inf "NOTE: the tunnel is only up while this distro is running. 'wsl --shutdown',"
inf "      closing every shell, or Windows sleeping will take this host offline."

echo
echo "-- installation --"
for f in tsvpn-lib.sh tsvpn-selfheal.sh tsvpn-audit.sh; do
	[ -x "${TSVPN_DIR:-/etc/tsvpn}/$f" ] && ok "$f installed" || no "$f MISSING"
done
if have systemctl; then
	systemctl is-enabled tsvpn-selfheal.service >/dev/null 2>&1 \
		&& ok "tsvpn-selfheal.service enabled (runs at boot)" \
		|| no "tsvpn-selfheal.service NOT enabled — this will not survive a restart"
fi
[ -f "$TSVPN_LOG" ] && inf "last self-heal: $(head -1 "$TSVPN_LOG" 2>/dev/null)" || wn "no $TSVPN_LOG yet (written at boot)"

echo
echo "-- tailscale --"
tailscale status >/dev/null 2>&1 && ok "tailscaled responding" || no "tailscaled not responding — everything below is unreliable"
TSIP=$(tailscale ip -4 2>/dev/null | head -1)
[ -n "$TSIP" ] && ok "tailnet address $TSIP" || no "no tailnet address — run 'sudo tailscale up'"
PREFS=$(tailscale debug prefs 2>/dev/null)

echo
echo "-- forwarding --"
[ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null)" = "1" ] && ok "net.ipv4.ip_forward = 1" || no "ip_forward is not 1 — nothing routes through this host"
[ -f /etc/sysctl.d/99-tsvpn.conf ] && ok "forwarding persisted in /etc/sysctl.d/99-tsvpn.conf" || wn "forwarding not persisted — it will revert on restart"

echo
echo "-- host role --"
echo "$PREFS" | grep -q '"0.0.0.0/0"' && ok "advertising exit node 0.0.0.0/0" || no "NOT advertising the exit node"
for t in $TARGETS; do
	echo "$PREFS" | grep -q "\"$t/32\"" && ok "advertising route $t/32" || no "NOT advertising $t/32"
done
echo "$PREFS" | grep -qE '"(192\.168\.[0-9]+|10\.[0-9]+\.[0-9]+)\.0/24"' \
	&& wn "a whole /24 is advertised — design 3.1 wants a /32 per device" \
	|| ok "no whole-LAN route advertised (design 3.1)"
if echo "$PREFS" | grep -q '"NoSNAT": true'; then
	no "NoSNAT is set — subnet-route replies will not come back"
else
	ok "SNAT for subnet routes left on (Tailscale handles it)"
fi

echo
echo "-- dns for the tailnet (design 3.5) --"
if have dnsmasq; then
	[ -f /etc/dnsmasq.d/tsvpn.conf ] && ok "/etc/dnsmasq.d/tsvpn.conf present" || no "dnsmasq config missing — a remote would get no DNS"
	grep -q "^no-resolv" /etc/dnsmasq.d/tsvpn.conf 2>/dev/null \
		&& no "no-resolv set on a host — it must resolve via the network it is on" \
		|| ok "no-resolv absent (forwards to this machine's own resolver)"
	systemctl is-active dnsmasq >/dev/null 2>&1 && ok "dnsmasq running" || no "dnsmasq not running"
	if [ -n "$TSIP" ]; then
		(ss -lnu 2>/dev/null | grep -q "$TSIP:53" || ss -lnu 2>/dev/null | grep -q "0.0.0.0:53") \
			&& ok "listening for DNS on the tailnet address" \
			|| no "not listening on $TSIP:53 — a remote cannot resolve through this host"
	fi
else
	wn "dnsmasq not installed — fine for travelling laptops and phones, which get DNS"
	inf "through the exit node. NOT enough for a remote router: either install"
	inf "dnsmasq, or advertise your site's resolver as a target and point the"
	inf "remote's dns_upstream at it (README section 5)."
fi
inf "this machine resolves via: $(sed -n 's/^nameserver //p' /etc/resolv.conf 2>/dev/null | tr '\n' ' ')"

echo
echo "-- name resolution --"
# getent uses the system resolver and ships with glibc; dig and nslookup are
# NOT installed on a default Ubuntu image, so testing with them reports a
# failure that is really just a missing package.
getent hosts github.com >/dev/null 2>&1 && ok "this machine resolves names" || no "name resolution FAILS here"

echo
echo "-- targets --"
if [ -z "$TARGETS" ]; then
	inf "no targets configured (exit node only — fine if you just want to egress here)"
else
	for t in $TARGETS; do
		ping -c1 -W3 "$t" >/dev/null 2>&1 && ok "$t reachable from this machine" \
			|| no "$t NOT reachable — a remote will not reach it either"
	done
fi

echo
echo "=== $P passed, $F failed, $W warnings ==="
[ $F -eq 0 ] || exit 1
