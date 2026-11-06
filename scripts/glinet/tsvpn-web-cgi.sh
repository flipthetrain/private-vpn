#!/bin/sh
# ============================================================
#  tsvpn-web-cgi.sh — CGI behind the router's admin page
#  (http://<tailnet-ip>:8099/). Runs ON the router under uhttpd.
#
#  Gates, in order:
#   1. uhttpd listens on the tailnet address only, and this refuses
#      any client not from 100.64.0.0/10 — so only tailnet peers.
#      (A device at a REMOTE site reaches the host as that remote's
#      100.x, so it counts as a peer: gate 2 is the real one.)
#   2. Login with the router's admin password (the GL.iNet admin /
#      root password), checked by rpcd exactly as GL/LuCI do. It is
#      never stored. 5 wrong in 10 min locks login for 10 min.
#   3. Session = an rpcd session id in an HttpOnly, SameSite=Strict
#      cookie, 30 min idle timeout. Anything that changes state must be
#      a POST with Content-Type application/json: another website cannot
#      send that cross-site without a CORS preflight, which we never
#      grant, and SameSite=Strict keeps the cookie off it anyway.
#      (uhttpd does not pass custom headers to CGI, so no X- header.)
#  Actions are the fixed menu in tsvpn-api.sh. On the host, target=
#  <100.x> runs the action on that remote through the host's key,
#  which each remote only lets run tsvpn-api.sh.
#  Generic.
# ============================================================
D=/etc/tsvpn
KEY=/etc/dropbear/tsvpn_host_ed25519
FAILS=/tmp/tsvpn-web.fails
. /usr/share/libubox/jshn.sh

out() {   # out <status> <content-type> [extra header]
	printf 'Status: %s\r\nContent-Type: %s\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\n' "$1" "$2"
	[ -n "$3" ] && printf '%s\r\n' "$3"
	printf '\r\n'
}
die() { out "$1" text/plain; echo "$2"; exit 0; }

# --- gate 1: the client must be a machine on the tailnet, on every router ---
case "$REMOTE_ADDR" in
	100.6[4-9].*|100.[7-9][0-9].*|100.1[01][0-9].*|100.12[0-7].*) ;;
	*) die "403 Forbidden" "tailnet only" ;;
esac
. $D/tsvpn-lib.sh; tsvpn_load >/dev/null 2>&1

qs() { echo "$QUERY_STRING" | tr '&' '\n' | sed -n "s/^$1=//p" | head -1; }
ACT=$(qs a); TGT=$(qs t); MODE=$(qs m)
echo "$ACT" | grep -qE '^[a-z-]{1,24}$' || ACT=""
echo "$TGT" | grep -qE '^100\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$' || TGT=""
echo "$MODE" | grep -qE '^[a-z]{1,8}$' || MODE=""

BODY=""
[ "$REQUEST_METHOD" = POST ] && [ "${CONTENT_LENGTH:-0}" -gt 0 ] 2>/dev/null && \
	BODY=$(head -c "$(( CONTENT_LENGTH > 8192 ? 8192 : CONTENT_LENGTH ))")

# --- unauthenticated: the host's public key, for remotes' self-heal ---
if [ "$ACT" = host-pub ]; then
	out "200 OK" text/plain; $D/tsvpn-api.sh host-pub; exit 0
fi

# --- gate 2: login ---
now=$(date +%s)
if [ "$ACT" = login ]; then
	[ "$REQUEST_METHOD" = POST ] || die "405 Method Not Allowed" "POST"
	case "$CONTENT_TYPE" in application/json*) ;; *) die "415 Unsupported Media Type" "application/json only" ;; esac
	touch $FAILS
	recent=$(awk -v n="$now" '$1 > n-600' $FAILS | wc -l)
	[ "$recent" -lt 5 ] || { logger -t tsvpn-web "login locked: $recent failures in 10 min (last from $REMOTE_ADDR)"; die "429 Too Many Requests" "too many wrong passwords; try again in 10 minutes"; }
	PW=$(echo "$BODY" | jsonfilter -e '@.password' 2>/dev/null)
	json_init; json_add_string username root; json_add_string password "$PW"; json_add_int timeout 1800
	R=$(ubus call session login "$(json_dump)" 2>/dev/null)
	SID=$(echo "$R" | jsonfilter -e '@.ubus_rpc_session' 2>/dev/null)
	if echo "$SID" | grep -qE '^[0-9a-f]{32}$'; then
		: > $FAILS
		logger -t tsvpn-web "login from $REMOTE_ADDR"
		out "200 OK" application/json "Set-Cookie: tsvpn=$SID; Path=/; HttpOnly; SameSite=Strict; Max-Age=1800"
		echo '{"ok":true}'
	else
		echo "$now $REMOTE_ADDR" >> $FAILS
		logger -t tsvpn-web "FAILED login from $REMOTE_ADDR"
		sleep 2
		die "401 Unauthorized" "wrong password"
	fi
	exit 0
fi

# --- gate 3: session + anti-CSRF header on everything else ---
SID=$(echo "$HTTP_COOKIE" | tr ';' '\n' | sed -n 's/^ *tsvpn=\([0-9a-f]\{32\}\)$/\1/p' | head -1)
[ -n "$SID" ] && ubus call session list "{\"ubus_rpc_session\":\"$SID\"}" >/dev/null 2>&1 \
	|| die "401 Unauthorized" "log in"

if [ "$ACT" = logout ]; then
	ubus call session destroy "{\"ubus_rpc_session\":\"$SID\"}" >/dev/null 2>&1
	out "200 OK" text/plain "Set-Cookie: tsvpn=; Path=/; Max-Age=0"; echo "logged out"; exit 0
fi

# Changing actions must be POSTs; reads may be GETs.
case "$ACT" in
	status|config-get|peers|audit) ;;
	*) [ "$REQUEST_METHOD" = POST ] || die "405 Method Not Allowed" "POST"
	   case "$CONTENT_TYPE" in application/json*) ;; *) die "415 Unsupported Media Type" "application/json only" ;; esac ;;
esac

# run <action> [args] — here, or on remote $TGT via the host's key
SELF=$(tailscale ip -4 2>/dev/null | head -1)
[ "$TGT" = "$SELF" ] && TGT=""
run() {
	if [ -z "$TGT" ]; then
		$D/tsvpn-api.sh "$@"
	else
		[ "$ROLE" = host ] || { echo "error: only the host can act on other routers"; return; }
		timeout 240 dbclient -y -i $KEY "root@$TGT" "$*" 2>/dev/null \
			|| echo "error: $TGT did not answer (offline, or its self-heal has not fetched this host's key yet)"
	fi
}
runin() {   # runin <action> — same, feeding $BODY on stdin
	if [ -z "$TGT" ]; then echo "$BODY" | $D/tsvpn-api.sh "$1"
	else echo "$BODY" | timeout 120 dbclient -y -i $KEY "root@$TGT" "$1" 2>/dev/null || echo "error: $TGT did not answer"; fi
}

case "$ACT" in
status|config-get)
	out "200 OK" application/json; run "$ACT" ;;
peers)
	# host only: every online Linux peer that accepts this host's key
	out "200 OK" application/json
	[ "$ROLE" = host ] || { echo '[]'; exit 0; }
	printf '['; first=1
	for ip in $(tailscale status 2>/dev/null | awk '$4=="linux" && $5!="offline," {print $1}' | grep -v "^$SELF$"); do
		( r=$(timeout 10 dbclient -y -i $KEY "root@$ip" status 2>/dev/null)
		  echo "$r" | grep -q '^{' && echo "$r" > /tmp/tsvpn-peer.$ip ) &
	done; wait
	for f in /tmp/tsvpn-peer.*; do
		[ -f "$f" ] || continue
		[ $first = 1 ] || printf ','; first=0; cat "$f"; rm -f "$f"
	done
	printf ']\n'
	;;
audit|test|selfheal|restart-tailscale|reboot)
	out "200 OK" text/plain; run "$ACT" ;;
speed)
	out "200 OK" text/plain
	if [ -n "$TGT" ]; then
		# host <-> that remote: its own internet, then the tunnel both ways
		run speed-inet direct 2 8
		for d in down up; do
			$D/tsvpn-api.sh iperf-server 50 >/dev/null
			run iperf "$SELF" "$d" 2 8
		done
	else
		case "$MODE" in tunnel) m=tunnel ;; *) m=direct ;; esac
		$D/tsvpn-api.sh speed-inet "$m" 2 8
	fi
	;;
config-set)
	out "200 OK" text/plain; runin config-set ;;
*)
	die "400 Bad Request" "unknown action" ;;
esac
