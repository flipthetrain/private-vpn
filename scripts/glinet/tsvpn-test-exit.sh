#!/bin/sh
# ============================================================
#  tsvpn-test-exit.sh — end-to-end test of a REMOTE's path
#  through its exit node. Read-only. Runs ON the router:
#
#    ssh root@<router> 'sh -s' < tsvpn-test-exit.sh
#    (or: tsvpn-provision.sh test <router>)
#
#  The audit checks configuration; this measures the live path:
#  direct vs relayed connection, latency, egress IP, DNS, client
#  (LAN-sourced) traffic, each target, and download speed.
#
#  Exit status: 0 = all passed, 1 = at least one FAIL.
#  Generic. All values come from /etc/tsvpn/node.json.
# ============================================================
. /etc/tsvpn/tsvpn-lib.sh
tsvpn_load || exit 1
[ "$ROLE" = remote ] || { echo "tsvpn-test-exit: this is a host; run it on a remote."; exit 0; }

P=0; F=0
ok(){ echo "  PASS  $1"; P=$((P+1)); }
no(){ echo "  FAIL  $1"; F=$((F+1)); }
inf(){ echo "        $1"; }
LANIP=$(ip -4 addr show br-lan 2>/dev/null | sed -n 's/.*inet \([0-9.]*\).*/\1/p' | head -1)

echo "=== exit-node test: $NODE -> $EXIT_NODE — $(date) ==="

PONG=$(tailscale ping -c 3 "$EXIT_NODE" 2>&1 | grep pong | tail -1)
case "$PONG" in
	*"via DERP"*) no "reaches the exit node only via a DERP relay — expect poor video: $PONG" ;;
	*pong*)       ok "direct path to the exit node: ${PONG#pong from }" ;;
	*)            no "no tailscale pong from $EXIT_NODE" ;;
esac
[ "$(tailscale status --json | jsonfilter -e '@.ExitNodeStatus.Online')" = true ] \
	&& ok "exit node online" || no "exit node OFFLINE — every client here is blackholed"
RTT=$(ping -c 5 -q "$EXIT_NODE" 2>/dev/null | sed -n 's/.*= [0-9.]*\/\([0-9.]*\)\/.*/\1/p')
[ -n "$RTT" ] && ok "ping exit node: ${RTT} ms avg" || no "exit node does not answer ping"

HOP=$(traceroute -n -m 1 -w 2 8.8.8.8 2>/dev/null | sed -n 2p | awk '{print $2}')
[ "$HOP" = "$EXIT_NODE" ] && ok "first hop is the exit node" || no "first hop is ${HOP:-<none>}, not $EXIT_NODE"
EG=$(wget -qO- --timeout=10 https://ifconfig.me/ip 2>/dev/null)
[ -n "$EG" ] && inf "egress IP $EG  <- must be the HOST site's public IP" || no "no egress (ifconfig.me unreachable)"

nslookup github.com "${LANIP:-127.0.0.1}" 2>/dev/null | grep -q '^Address.*[0-9]\.[0-9]' \
	&& ok "client DNS resolves via ${LANIP:-127.0.0.1}" || no "client DNS fails"
[ -n "$LANIP" ] && { ping -c 3 -q -I "$LANIP" 1.1.1.1 >/dev/null 2>&1 \
	&& ok "LAN-sourced traffic reaches the internet" || no "LAN-sourced traffic fails (masq?)"; }

for t in $TARGETS; do
	R=$(ip route get "$t" 2>/dev/null | head -1)
	case "$R" in *tailscale0*) ok "$t routes via the tunnel" ;; *) no "$t does NOT route via the tunnel: $R" ;; esac
	ping -c 2 -W 3 -q "$t" >/dev/null 2>&1 && ok "$t answers" || no "$t does not answer"
done

# Speed: count the bytes actually received — a failed download is fast too.
S=$(cut -d' ' -f1 /proc/uptime)
N=$(wget -O - --timeout=60 "https://speed.cloudflare.com/__down?bytes=25000000" 2>/dev/null | wc -c)
E=$(cut -d' ' -f1 /proc/uptime)
if [ "$N" -ge 25000000 ] 2>/dev/null; then
	ok "download $(echo "$N $S $E" | awk '{t=$3-$2; if (t<0.1) t=0.1; printf "%.0f Mbit/s (%d MB in %.1fs)", $1*8/t/1e6, $1/1e6, t}')"
else
	no "speed test download incomplete ($N bytes)"
fi

echo "=== $P passed, $F failed ==="
[ $F -eq 0 ]
