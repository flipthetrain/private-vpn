#!/bin/sh
# ============================================================
#  tsvpn-audit.sh — verify EVERY design requirement on this box.
#
#  Read-only: it changes nothing, so it is always safe to run.
#  Role-aware. Covers the design requirements (README.md 3.1-3.6)
#  and the installation itself.
#
#  Exit status: 0 = everything passed, 1 = at least one FAIL.
#  Run it after any change, and after any OS upgrade.
#
#  Generic. All values come from /etc/tsvpn/node.json.
# ============================================================
. /etc/tsvpn/tsvpn-lib.sh
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
ok "role = $ROLE"
inf "deployment: ${DEPLOYMENT:-<unset>}"
inf "os        : $(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown}")  $(uname -m)"
inf "model     : $(tr -d '\0' < /proc/device-tree/model 2>/dev/null || echo 'not a Pi')"
inf "tailscale : $(tailscale version 2>/dev/null | head -1)"
inf "targets   : ${TARGETS:-<none>}"
inf "uplink    : ${WAN_IFACE:-<none>}"
[ "$ROLE" = "remote" ] && inf "exit node : ${EXIT_NODE:-<none>}"
[ "$ROLE" = "remote" ] && inf "lan       : $LAN_IFACE $LAN_CIDR"

echo
echo "-- installation --"
for f in tsvpn-lib.sh tsvpn-selfheal.sh tsvpn-audit.sh tsvpn-clone-mac.sh tsvpn-fix-route.sh; do
	[ -x "/etc/tsvpn/$f" ] && ok "/etc/tsvpn/$f present" || no "/etc/tsvpn/$f MISSING"
done
if have systemctl; then
	systemctl is-enabled tsvpn-selfheal.service >/dev/null 2>&1 \
		&& ok "tsvpn-selfheal.service enabled (runs at boot)" \
		|| no "tsvpn-selfheal.service NOT enabled — this will not survive a reboot"
	if [ "$ROLE" = "remote" ]; then
		systemctl is-enabled tsvpn-fix-route.timer >/dev/null 2>&1 \
			&& ok "tsvpn-fix-route.timer enabled" \
			|| wn "tsvpn-fix-route.timer not enabled — the collision fix has no backstop"
	fi
else
	wn "no systemctl — cannot confirm this survives a reboot"
fi
[ -f "$TSVPN_LOG" ] && inf "last self-heal: $(head -1 "$TSVPN_LOG" 2>/dev/null)" || wn "no $TSVPN_LOG yet (written at boot)"

echo
echo "-- tailscale --"
if tailscale status >/dev/null 2>&1; then ok "tailscaled responding"
else no "tailscaled not responding — everything below is unreliable"; fi
TSIP=$(tailscale ip -4 2>/dev/null | head -1)
[ -n "$TSIP" ] && ok "tailnet address $TSIP" || no "no tailnet address — logged out? run 'tailscale up'"
PREFS=$(tailscale debug prefs 2>/dev/null)

echo
echo "-- forwarding --"
[ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null)" = "1" ] && ok "net.ipv4.ip_forward = 1" || no "ip_forward is not 1 — nothing routes through this box"
if [ -f /etc/sysctl.d/99-tsvpn.conf ]; then ok "forwarding persisted in /etc/sysctl.d/99-tsvpn.conf"
else wn "forwarding not persisted — it will revert on reboot unless set elsewhere"; fi

echo
if [ "$ROLE" = "host" ]; then
	echo "-- host role --"
	echo "$PREFS" | grep -q '"0.0.0.0/0"' && ok "advertising exit node 0.0.0.0/0" || no "NOT advertising the exit node"
	for t in $TARGETS; do
		echo "$PREFS" | grep -q "\"$t/32\"" && ok "advertising route $t/32" || no "NOT advertising $t/32"
	done
	echo "$PREFS" | grep -qE '"(192\.168\.[0-9]+|10\.[0-9]+\.[0-9]+)\.0/24"' \
		&& wn "a whole /24 is advertised — design §3.1 wants a /32 per device" \
		|| ok "no whole-LAN route advertised (design §3.1)"
	# Tailscale does its own SNAT for exit-node and subnet-route traffic on Linux
	# when netfilter mode is on. If it has been turned off, nothing else puts it back.
	if echo "$PREFS" | grep -q '"NoSNAT": true'; then
		no "NoSNAT is set — subnet-route replies will not come back"
	else
		ok "SNAT for subnet routes left on (Tailscale handles it)"
	fi
	echo
	echo "-- host dns (design §3.5: resolves via its own network, serves the tailnet) --"
	if have dnsmasq; then
		if [ -f /etc/dnsmasq.d/tsvpn.conf ]; then ok "/etc/dnsmasq.d/tsvpn.conf present"
		else no "/etc/dnsmasq.d/tsvpn.conf missing — clients will get no DNS"; fi
		grep -q "^no-resolv" /etc/dnsmasq.d/tsvpn.conf 2>/dev/null \
			&& no "no-resolv set on the host — it must use the network it is on" \
			|| ok "no-resolv absent (forwards to this network's resolver)"
		systemctl is-active dnsmasq >/dev/null 2>&1 && ok "dnsmasq running" || no "dnsmasq not running"
		if [ -n "$TSIP" ]; then
			(ss -lnu 2>/dev/null | grep -q "$TSIP:53" || ss -lnu 2>/dev/null | grep -q "0.0.0.0:53") \
				&& ok "listening for DNS on the tailnet address" \
				|| no "not listening on $TSIP:53 — remote sites cannot resolve"
		fi
	else
		no "dnsmasq not installed — a remote cannot resolve through this host (design §3.5)"
	fi
	inf "upstream: $(sed -n 's/^nameserver //p' /etc/resolv.conf 2>/dev/null | tr '\n' ' ')"
else
	echo "-- remote role --"
	EID=$(echo "$PREFS" | sed -n 's/.*"ExitNodeID": "\([^"]*\)".*/\1/p')
	[ -n "$EID" ] && ok "exit node pinned (ExitNodeID=$EID)" || no "no exit node selected — traffic would leave from THIS site"
	echo "$PREFS" | grep -q '"RouteAll": true' && ok "accept-routes on" || no "accept-routes off — subnet routes will not appear"
	# One-way by design: a remote must never offer routes back to the tailnet.
	ADV=$(echo "$PREFS" | sed -n '/"AdvertiseRoutes"/,/]/p' | grep -o '"[0-9][^"]*"' | tr -d '"' | tr '\n' ' ')
	[ -z "$ADV" ] && ok "advertises nothing (one-way: remote -> host)" \
		|| no "ADVERTISING $ADV — approve that in the console and this site becomes reachable from the tailnet"
	echo "$PREFS" | grep -q '"ExitNodeAllowLANAccess": true' && ok "exit-node-allow-lan-access on (you keep local admin access)" || wn "allow-lan-access off — you can lock yourself out of a box you are standing next to"

	echo
	echo "-- nat and kill-switch --"
	if have nft; then
		NAT=$(nft list table ip tsvpn_nat 2>/dev/null)
		echo "$NAT" | grep -q 'oifname "tailscale0".*masquerade' \
			&& ok "masquerade out of tailscale0 (design §3.3 — or nothing behind this box works)" \
			|| no "no masquerade into the tunnel — this box works, clients behind it do not"
		FW=$(nft list table inet tsvpn 2>/dev/null)
		echo "$FW" | grep -q "oifname \"$WAN_IFACE\" .*drop" \
			&& ok "kill-switch: forwarding to $WAN_IFACE is dropped" \
			|| no "KILL-SWITCH MISSING — clients can reach the internet outside the tunnel"
		echo "$FW" | grep -q "oifname \"tailscale0\" accept" \
			&& ok "forwarding into the tunnel allowed" \
			|| no "no forward rule into tailscale0 — clients cannot reach the tunnel"
	else
		no "nft not found — cannot verify NAT or the kill-switch"
	fi

	echo
	echo "-- remote dns (design §3.5: resolves through the host) --"
	CONF=/etc/dnsmasq.d/tsvpn.conf
	if [ -f "$CONF" ]; then
		ok "$CONF present"
		grep -q "^no-resolv" "$CONF" && ok "no-resolv set (cannot fall back to this site's resolver)" \
			|| no "no-resolv NOT set — clients can leak to the local ISP resolver"
		SRV=$(sed -n 's/^server=//p' "$CONF" | tr '\n' ' ')
		if [ -z "$SRV" ]; then
			no "dnsmasq has NO upstream — every name lookup times out while direct-IP traffic works"
		else
			ok "dnsmasq upstream: $SRV"
			for s in $SRV; do
				[ "$s" = "$EXIT_NODE" ] && ok "upstream is the host — answers come from the host site's resolver" \
					|| wn "upstream $s is not the host ($EXIT_NODE) — resolver egress may not match client egress"
				R=$(ip route get "$s" 2>/dev/null | head -1)
				case "$R" in *tailscale0*) ok "upstream $s routes via the tunnel" ;; *) no "upstream $s does NOT route via the tunnel: $R" ;; esac
			done
		fi
		systemctl is-active dnsmasq >/dev/null 2>&1 && ok "dnsmasq running" || no "dnsmasq not running — clients get no DNS or DHCP"
	else
		no "$CONF missing — clients get no DNS"
	fi

	echo
	echo "-- ipv6 leak (design §3.6) --"
	grep -q "^no-dhcpv6\|^dhcp-range=.*,ra-only\|^enable-ra" "$CONF" 2>/dev/null \
		&& wn "dnsmasq may be advertising IPv6 — confirm the tunnel carries v6" \
		|| ok "dnsmasq is not handing out IPv6"
	if ip -6 route show default 2>/dev/null | grep -q .; then
		echo "$PREFS" | grep -q '"::/0"' && ok "a v6 default route exists and the exit node carries v6" \
			|| wn "a v6 default route exists — confirm the tunnel carries v6, or clients leak over it"
	else
		ok "no IPv6 default route"
	fi
	[ "$(sysctl -n net.ipv6.conf.$LAN_IFACE.accept_ra 2>/dev/null)" = "0" ] \
		&& ok "no RA accepted on $LAN_IFACE" || wn "RA not disabled on $LAN_IFACE"

	echo
	echo "-- target routing (design §3.2) --"
	for t in $TARGETS; do
		ip rule list 2>/dev/null | grep -q "to $t lookup 52" \
			&& ok "$t pinned to table 52 ahead of any local route" \
			|| wn "$t not pinned — fine unless this site's LAN overlaps it (run tsvpn-fix-route.sh)"
	done

	echo
	echo "-- live path --"
	HOP=$(traceroute -n -m 2 -w 2 8.8.8.8 2>/dev/null | sed -n 2p | awk '{print $2}')
	[ -n "$HOP" ] && { [ "$HOP" = "$EXIT_NODE" ] && ok "first hop is the exit node ($HOP)" || no "first hop is $HOP, expected $EXIT_NODE"; } \
		|| wn "traceroute unavailable — install traceroute for this check"
	R=$(ip route get 8.8.8.8 2>/dev/null | head -1)
	case "$R" in *"dev tailscale0"*) ok "default traffic uses tailscale0" ;; *) no "default traffic is NOT tunnelled: $R" ;; esac
	EGRESS=$(curl -s --max-time 10 https://ifconfig.me/ip 2>/dev/null)
	[ -n "$EGRESS" ] && inf "egress IP: $EGRESS  <- must be the HOST site's public IP, not this site's" || wn "could not determine the egress IP"
	# A LAN client is masqueraded; this box itself is not. Test that path too,
	# because a missing masquerade is invisible from the box's own traffic.
	if [ -n "$LAN_ADDR" ] && ip -4 addr show "$LAN_IFACE" 2>/dev/null | grep -q "$LAN_ADDR"; then
		ping -c1 -W3 -I "$LAN_ADDR" 8.8.8.8 >/dev/null 2>&1 \
			&& ok "LAN-sourced traffic reaches the internet (masquerade works)" \
			|| no "LAN-sourced traffic fails — check the masquerade (design §3.3)"
	else
		wn "$LAN_IFACE has no address $LAN_ADDR — is the LAN/AP up? (see tsvpn-setup-ap.sh)"
	fi
fi

echo
echo "-- name resolution (the check a route test misses) --"
# getent uses the system resolver and ships with glibc. dig and nslookup are NOT
# installed on a default image, so testing with them reports a failure that is
# really a missing package. Note dig needs @server, not a bare argument.
getent hosts github.com >/dev/null 2>&1 && ok "this box resolves names" || no "name resolution FAILS on this box"
if [ "$ROLE" = "remote" ] && [ -n "$LAN_ADDR" ]; then
	if have dig; then
		R=$(dig +short +time=3 +tries=1 @"$LAN_ADDR" github.com 2>/dev/null)
	elif have nslookup; then
		R=$(nslookup github.com "$LAN_ADDR" 2>/dev/null | sed -n "s/^Address: //p")
	else
		R=""; NOTOOL=1
	fi
	if [ -n "${NOTOOL:-}" ]; then
		wn "cannot test what clients see: install dnsutils to check $LAN_ADDR answers"
	elif [ -n "$R" ]; then
		ok "clients can resolve via $LAN_ADDR"
	else
		no "clients CANNOT resolve via $LAN_ADDR — this presents to the user as 'no internet'"
	fi
fi

echo
echo "-- targets --"
if [ -z "$TARGETS" ]; then
	inf "no targets configured"
else
	for t in $TARGETS; do
		if [ "$ROLE" = "remote" ]; then
			R=$(ip route get "$t" 2>/dev/null | head -1)
			case "$R" in *tailscale0*) ok "$t routes via the tunnel" ;; *) no "$t does NOT route via the tunnel: $R" ;; esac
		fi
		ping -c1 -W3 "$t" >/dev/null 2>&1 && ok "$t reachable" || no "$t NOT reachable"
	done
fi

echo
echo "=== $P passed, $F failed, $W warnings ==="
[ $F -eq 0 ] || exit 1
