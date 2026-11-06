#!/bin/sh
# ============================================================
#  tsvpn-audit.sh — verify EVERY design requirement on this box.
#
#  Read-only: it changes nothing, so it is always safe to run.
#  Role-aware. Covers the design requirements (README.md 3.1-3.6) and the install itself.
#
#  Exit status: 0 = everything passed, 1 = at least one FAIL.
#  Run it on both routers after any change, and after every
#  firmware update.
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

DNSCONF=$(ls /var/etc/dnsmasq.conf.* 2>/dev/null | head -1)

echo "=== tsvpn audit: ${NODE:-$(uci -q get system.@system[0].hostname)} — $(date) ==="
echo
echo "-- identity --"
ok "role = $ROLE"
inf "deployment: ${DEPLOYMENT:-<unset>}"
inf "gl firmware $(cat /etc/glversion 2>/dev/null)  tailscale $(tailscale version 2>/dev/null | head -1)"
inf "targets   : ${TARGETS:-<none>}"
[ "$ROLE" = "remote" ] && inf "exit node : ${EXIT_NODE:-<none>}"

echo
echo "-- installation --"
for f in tsvpn-lib.sh tsvpn-selfheal.sh tsvpn-audit.sh tsvpn-clone-mac.sh; do
	[ -x "/etc/tsvpn/$f" ] && ok "/etc/tsvpn/$f present" || no "/etc/tsvpn/$f MISSING"
done
if [ "$ROLE" = "remote" ] && [ -n "$COLLIDE" ]; then
	[ -x /etc/tsvpn/tsvpn-fix-route.sh ] && ok "/etc/tsvpn/tsvpn-fix-route.sh present" || no "/etc/tsvpn/tsvpn-fix-route.sh MISSING"
fi
grep -q TSVPN-BOOTSTRAP /etc/rc.local 2>/dev/null && ok "rc.local bootstrap armed (survives firmware updates)" || no "rc.local bootstrap MISSING — re-run tsvpn-install.sh"
if grep -q "__TSVPN_NODE__" /etc/rc.local 2>/dev/null; then
	sed -n '/^cat > \/etc\/tsvpn\/node.json <<.__TSVPN_NODE__.$/,/^__TSVPN_NODE__$/p' /etc/rc.local \
		| sed '1d;$d' > /tmp/tsvpn-node-check.$$ 2>/dev/null
	if cmp -s /tmp/tsvpn-node-check.$$ "$TSVPN_NODE"; then
		ok "rc.local carries a matching copy of node.json"
	else
		wn "rc.local's embedded node.json DIFFERS from the live one — run tsvpn-persist.sh"
	fi
	rm -f /tmp/tsvpn-node-check.$$
else
	no "rc.local carries no node.json payload — a flash that wipes /etc/tsvpn is unrecoverable remotely"
fi
[ -x /etc/tsvpn/tsvpn-watchdog.sh ] && grep -q tsvpn-watchdog /etc/crontabs/root 2>/dev/null \
	&& ok "tailscale watchdog armed (cron, every 3 min)" || no "tailscale watchdog NOT armed — a hung tailscaled needs someone to pull the power"
[ -s /etc/tsvpn/watchdog.log ] && wn "watchdog has acted: $(grep -c '^==' /etc/tsvpn/watchdog.log) time(s), last: $(grep '^==' /etc/tsvpn/watchdog.log | tail -1 | cut -c4-60) — see /etc/tsvpn/watchdog.log"
grep -q "/etc/tsvpn" /etc/sysupgrade.conf 2>/dev/null && ok "/etc/tsvpn listed in sysupgrade.conf" || wn "/etc/tsvpn not in sysupgrade.conf (bootstrap still covers it)"
[ -f "$TSVPN_LOG" ] && inf "last self-heal: $(head -1 "$TSVPN_LOG" 2>/dev/null)" || wn "no $TSVPN_LOG yet (written at boot)"

echo
echo "-- admin page (tailnet + admin password) --"
TIP=$(tailscale ip -4 2>/dev/null | head -1)
LIS=$(netstat -lnt 2>/dev/null | awk '$4 ~ /:8099$/ {print $4}' | tr '\n' ' ')
case "$LIS" in
	"$TIP:8099 ") ok "admin page on $TIP:8099 only (tailnet address)" ;;
	"") no "admin page not listening — /etc/init.d/tsvpn-web restart" ;;
	*) no "admin page listening on: $LIS — must be the tailnet address only" ;;
esac
[ "$(uci -q get firewall.tsvpn_lan_no_tailnet.target)" = REJECT ] && ok "LAN devices cannot reach tailnet addresses (only tailnet machines can)" \
	|| no "LAN devices can reach 100.x — remote-site devices could reach admin logins"
if [ "$ROLE" = host ]; then
	[ -s /etc/dropbear/tsvpn_host_ed25519.pub ] && ok "dashboard key present" || no "no dashboard key (/etc/dropbear/tsvpn_host_ed25519)"
else
	grep -q 'command="/etc/tsvpn/tsvpn-api.sh".* tsvpn-host$' /etc/dropbear/authorized_keys 2>/dev/null \
		&& ok "host dashboard key installed, restricted to tsvpn-api.sh" || wn "host dashboard key not installed — the host's dashboard cannot reach this router"
fi

echo
echo "-- clock (no RTC: TLS to the control plane fails if the clock is wrong) --"
if [ -f /etc/config/chrony ]; then
	[ "$(uci -q get chrony.@makestep[0].limit)" = "-1" ] && ok "chrony may step the clock at any time" || no "chrony makestep limit is not -1 — a late sync only slews, a weeks-old clock stays wrong"
	[ "$(uci -q get chrony.tsvpn_google.nts)" = "no" ] && [ "$(uci -q get chrony.tsvpn_cf.nts)" = "no" ] \
		&& ok "plain NTP sources by IP present (no DNS or certs needed)" || no "no plain-IP NTP source — clock recovery depends on DNS"
	chronyc tracking 2>/dev/null | grep -q "Leap status *: Normal" && ok "clock synced ($(date))" || no "clock NOT synced ($(date)) — tailscale TLS will fail if it is far off"
else
	# Older firmware: busybox ntpd (sysntpd). It has no status query, so check
	# the config and that the daemon is running with the IP sources.
	NTPS=$(uci -q get system.ntp.server)
	echo " $NTPS " | grep -q " 216.239.35.0 " && echo " $NTPS " | grep -q " 162.159.200.1 " \
		&& ok "plain NTP sources by IP present in system.ntp (no chrony on this firmware)" \
		|| no "no plain-IP NTP source in system.ntp — clock recovery depends on DNS"
	pgrep -f "ntpd.*-p 216.239.35.0" >/dev/null && ok "sysntpd running with the IP sources ($(date))" \
		|| no "sysntpd not running with the IP sources — clock can drift or stay wrong after a cold boot"
fi

echo
echo "-- tailscale --"
tailscale status >/dev/null 2>&1 && ok "tailscaled responding" || no "tailscaled not responding — everything below is unreliable"
# `tailscale ip` keeps answering with the cached address while the node is
# logged out or stuck before login (seen 2026-11: NoState for days, behind a
# bad clock), so check the backend state itself.
BSTATE=$(tailscale status --json 2>/dev/null | jsonfilter -e '@.BackendState' 2>/dev/null)
[ "$BSTATE" = "Running" ] && ok "backend state Running" || no "backend state is ${BSTATE:-<unknown>}, not Running — the node is off the tailnet"
TSIP=$(tailscale ip -4 2>/dev/null | head -1)
[ -n "$TSIP" ] && ok "tailnet address $TSIP" || no "no tailnet address — node logged out, needs ON-SITE re-auth (first-time setup: scripts/glinet/README.md section 2)"
PREFS=$(tailscale debug prefs 2>/dev/null)
TSPID=$(pidof tailscaled | cut -d' ' -f1)
if [ -n "$TSPID" ] && tr '\0' '\n' < /proc/$TSPID/environ 2>/dev/null | grep -q '^GOMEMLIMIT='; then
	ok "tailscaled memory-capped ($(tr '\0' '\n' < /proc/$TSPID/environ | grep ^GOMEMLIMIT=), using $(awk '/VmRSS/{print int($2/1024)}' /proc/$TSPID/status) MB)"
else
	no "tailscaled has no GOMEMLIMIT — under load it can exhaust memory and hang (2026-11-06)"
fi
MA=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo)
[ "${MA:-0}" -ge 60 ] && ok "memory available: ${MA} MB" || wn "only ${MA} MB memory available — close to the edge"

echo
echo "-- firewall (sections 3.3, 3.4) --"
[ "$(uci -q get firewall.tailscale0.input)" = "ACCEPT" ] && ok "tailscale0 input ACCEPT (admin over the tunnel)" || no "tailscale0 input not ACCEPT — you lose remote admin"
[ "$(uci -q get firewall.tailscale0.mtu_fix)" = "1" ] && ok "mtu_fix=1 (3.4)" || no "mtu_fix not set — UIs load, video and large transfers stall"
[ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null)" = "1" ] && ok "ip_forward=1" || no "ip_forward is not 1 — nothing routes"
FWD=""; i=0
while [ $i -lt 20 ]; do
	d=$(uci -q get firewall.@forwarding[$i].dest); [ -z "$d" ] && break
	FWD="$FWD $(uci -q get firewall.@forwarding[$i].src)->$d"; i=$((i+1))
done
inf "forwardings:$FWD"
OPEN=""
for r in $(uci show firewall | sed -n "s/^firewall\.\([^.=]*\)=rule$/\1/p"); do
	[ "$(uci -q get firewall.$r.src)" = wan ] && [ "$(uci -q get firewall.$r.target)" = ACCEPT ] || continue
	case " $(uci -q get firewall.$r.dest_port) " in *" 22 "*|*" 80 "*|*" 443 "*) OPEN="$OPEN $r" ;; esac
done
[ -z "$OPEN" ] && ok "no admin port open on WAN (admin only via the tunnel)" \
	|| wn "admin port open on WAN:$OPEN — left from provisioning? tsvpn-provision.sh lockdown <100.x>"

echo
if [ "$ROLE" = "host" ]; then
	echo "-- host role (host role) --"
	[ -z "$(uci -q get firewall.tailscale0.masq)" ] && ok "tailscale0 masq NOT set (correct: the wan zone already SNATs)" || no "tailscale0 masq set on the host — breaks return traffic"
	echo "$FWD" | grep -q "tailscale0->wan" && ok "tailscale0->wan present (carries exit-node egress)" || no "tailscale0->wan MISSING — exit node selected but no internet flows"
	echo "$FWD" | grep -q "wan->tailscale0" && ok "wan->tailscale0 present (return path from targets)" || no "wan->tailscale0 missing"
	[ "$(uci -q get firewall.@zone[1].masq)" = "1" ] && ok "wan zone masq=1" || wn "wan zone masq not 1 — check zone ordering"
	echo "$PREFS" | grep -q '"0.0.0.0/0"' && ok "advertising exit node 0.0.0.0/0" || no "NOT advertising the exit node"
	for t in $TARGETS; do
		echo "$PREFS" | grep -q "\"$t/32\"" && ok "advertising route $t/32" || no "NOT advertising $t/32"
	done
	# Advertised is not approved: without an ACL autoApprover the console must
	# approve each one, and nothing errors if nobody does.
	ALLOWED=" $(tailscale status --json 2>/dev/null | jsonfilter -e '@.Self.AllowedIPs[*]' | tr '\n' ' ') "
	case "$ALLOWED" in *" 0.0.0.0/0 "*) ok "exit node APPROVED in the console" ;; *) no "exit node advertised but NOT approved — console: Edit route settings, or add autoApprovers.exitNode" ;; esac
	for t in $TARGETS; do
		case "$ALLOWED" in *" $t/32 "*) ok "route $t/32 APPROVED" ;; *) no "route $t/32 NOT approved — console, or autoApprovers.routes" ;; esac
	done
	echo "$PREFS" | grep -qE '"192\.168\.[0-9]+\.0/24"|"10\.[0-9]+\.[0-9]+\.0/24"' && wn "a whole /24 is advertised — section 3.1 wants /32 per device" || ok "no whole-LAN route advertised (3.1)"
	echo
	echo "-- host dns (section 3.5: resolves via its own network) --"
	[ "$(uci -q get dhcp.@dnsmasq[0].localservice)" = "0" ] && ok "localservice=0 (answers tailnet peers over a /32)" || no "localservice not 0 — remote routers get NO DNS from this host"
	grep -q "^no-resolv" "$DNSCONF" 2>/dev/null && no "no-resolv set on the host — it must use its own network's resolver" || ok "no-resolv absent (uses the WAN DHCP resolver)"
	SRV=$(grep "^server=" "$DNSCONF" 2>/dev/null | sed 's/^server=//' | sort | tr '\n' ' ')
	WANT=$(for s in $DNS_UPSTREAM; do echo "$s"; done | sort | tr '\n' ' ')
	if [ "$SRV" = "$WANT" ]; then
		[ -n "$SRV" ] && ok "site-local fallback resolver(s) from node.json: $SRV" || ok "no hardcoded upstream"
	else
		wn "dnsmasq upstreams ($SRV) differ from node.json dns_upstream ($WANT)"
	fi
	inf "upstream: $(sed -n 's/^nameserver //p' /tmp/resolv.conf.d/resolv.conf.auto 2>/dev/null | tr '\n' ' ')"
else
	echo "-- remote role --"
	[ "$(uci -q get firewall.tailscale0.masq)" = "1" ] && ok "tailscale0 masq=1 (3.3 — or nothing behind this router works)" || no "masq NOT set — this router works, clients behind it do not"
	echo "$FWD" | grep -q -- "->wan" && no "KILL-SWITCH BREACHED: a *->wan forwarding exists ($FWD)" || ok "kill-switch intact: no *->wan forwarding (section 8)"
	echo "$FWD" | grep -q "lan->tailscale0" && ok "lan->tailscale0 present" || no "lan->tailscale0 missing — clients cannot reach the tunnel"
	EID=$(echo "$PREFS" | sed -n 's/.*"ExitNodeID": "\([^"]*\)".*/\1/p')
	[ -n "$EID" ] && ok "exit node pinned (ExitNodeID=$EID)" || no "no exit node selected — traffic would leave from THIS site"
	[ "$(tailscale status --json 2>/dev/null | jsonfilter -e '@.ExitNodeStatus.Online' 2>/dev/null)" = "true" ] \
		&& ok "exit node is online" || no "exit node is OFFLINE — the kill-switch blackholes every client at this site"
	echo "$PREFS" | grep -q '"RouteAll": true' && ok "accept-routes on" || no "accept-routes off — subnet routes will not appear"
	# One-way by design: a remote must never offer routes back to the tailnet.
	ADV=$(echo "$PREFS" | sed -n '/"AdvertiseRoutes"/,/]/p' | grep -o '"[0-9][^"]*"' | tr -d '"' | tr '\n' ' ')
	[ -z "$ADV" ] && ok "advertises nothing (one-way: remote -> host)" \
		|| no "ADVERTISING $ADV — approve that in the console and this site becomes reachable from the tailnet"

	echo
	echo "-- remote dns (section 3.5: resolves through the host) --"
	grep -q "^no-resolv" "$DNSCONF" 2>/dev/null && ok "no-resolv set (cannot fall back to this site's resolver)" || no "no-resolv NOT set — clients can leak to the local ISP resolver"
	SRV=$(grep "^server=" "$DNSCONF" 2>/dev/null | sed 's/^server=//' | tr '\n' ' ')
	if [ -z "$SRV" ]; then
		no "dnsmasq has NO upstream — every name lookup times out while direct-IP traffic works"
		inf "cause: 'server' written as a uci scalar; it must be delete + add_list (section 3.5)"
	else
		ok "dnsmasq upstream: $SRV"
		for s in $SRV; do
			[ "$s" = "$EXIT_NODE" ] && ok "upstream is the host — answers come from the host site's resolver" \
				|| wn "upstream $s is not the host ($EXIT_NODE) — resolver egress may not match client egress"
			R=$(ip route get "$s" 2>/dev/null | head -1)
			case "$R" in *tailscale0*) ok "upstream $s routes via the tunnel" ;; *) no "upstream $s does NOT route via the tunnel: $R" ;; esac
		done
	fi

	echo
	echo "-- ipv6 leak (section 3.6) --"
	[ "$(uci -q get dhcp.lan.ra)" = "disabled" ] && ok "router advertisements disabled" || no "RA not disabled — clients can leak over v6 while v4 looks perfect"
	[ "$(uci -q get dhcp.lan.dhcpv6)" = "disabled" ] && ok "dhcpv6 disabled" || no "dhcpv6 not disabled — v6 leak possible"
	ip -6 route show default 2>/dev/null | grep -q . && wn "a v6 default route exists — confirm the tunnel carries v6" || ok "no v6 default route"

	echo
	echo "-- subnet collision (section 3.2) --"
	if [ -n "$COLLIDE" ]; then
		[ -x /etc/tsvpn/tsvpn-fix-route.sh ] && ok "fix-route script present (collide=$COLLIDE)" || no "collide set but the fix script is missing"
		[ -x /etc/hotplug.d/iface/99-tsvpn-route ] && ok "ifup hotplug hook present" || no "hotplug hook missing — the fix will not re-run on WAN ifup"
		grep -q tsvpn-fix-route /etc/crontabs/root 2>/dev/null && ok "cron backstop present" || no "cron backstop missing"
		if ip route | grep -q "^${COLLIDE%%/*}"; then
			wn "collision is ACTIVE on this site — checking target routing below"
		else
			inf "no local $COLLIDE route; the fix is dormant, which is correct here"
		fi
	else
		inf "no collide set — nothing to check"
	fi

	echo
	echo "-- live path --"
	HOP=$(traceroute -n -m 2 -w 2 8.8.8.8 2>/dev/null | sed -n 2p | awk '{print $2}')
	[ "$HOP" = "$EXIT_NODE" ] && ok "first hop is the exit node ($HOP)" || no "first hop is ${HOP:-<none>}, expected $EXIT_NODE"
	R=$(ip route get 8.8.8.8 2>/dev/null | head -1)
	case "$R" in *"dev tailscale0"*) ok "default traffic uses tailscale0" ;; *) no "default traffic is NOT tunnelled: $R" ;; esac
	# resolve via dnsmasq (as clients do): GL points the router's own
	# resolv.conf at the site resolver, which may be broken
	EGIP=$(nslookup ifconfig.me 127.0.0.1 2>/dev/null | sed -n 's/^Address [0-9]*: \([0-9.]*\)$/\1/p' | head -1)
	EGRESS=$(curl -s ${EGIP:+--resolve ifconfig.me:443:$EGIP} --max-time 10 https://ifconfig.me/ip 2>/dev/null)
	[ -n "$EGRESS" ] && inf "egress IP: $EGRESS  <- must be the HOST site's public IP, not this site's" || wn "could not determine the egress IP"
	# A LAN client is masqueraded; this router itself is not. Test that path too,
	# because masq problems are invisible from the router's own traffic.
	LANIP=$(ip -4 addr show br-lan 2>/dev/null | sed -n 's/.*inet \([0-9.]*\).*/\1/p' | head -1)
	if [ -n "$LANIP" ]; then
		ping -c1 -W3 -I "$LANIP" 8.8.8.8 >/dev/null 2>&1 && ok "LAN-sourced traffic reaches the internet (masq works)" || no "LAN-sourced traffic fails — check masq (3.3)"
	fi
fi

echo
echo "-- name resolution (the check a route test misses) --"
nslookup github.com 127.0.0.1 >/dev/null 2>&1 && ok "this router resolves names" || no "name resolution FAILS on this router"
if [ "$ROLE" = "remote" ] && [ -n "$LANIP" ]; then
	nslookup github.com "$LANIP" >/dev/null 2>&1 && ok "clients can resolve via $LANIP" || no "clients CANNOT resolve via $LANIP — this presents as 'no internet'"
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
