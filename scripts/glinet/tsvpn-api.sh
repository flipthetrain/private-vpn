#!/bin/sh
# ============================================================
#  tsvpn-api.sh — the fixed menu of things the web page (and the
#  host's dashboard) may do on this router. Runs ON the router.
#
#    tsvpn-api.sh <action> [args]          called by the web CGI
#    (no args, via SSH)                    reads $SSH_ORIGINAL_COMMAND
#
#  The host's dashboard key is installed on each remote with
#  command="/etc/tsvpn/tsvpn-api.sh": that key can run ONLY these
#  actions, never a shell. Nothing from a caller is ever eval'd;
#  every argument is checked against a strict pattern first.
#
#  Actions:
#    status                     one-line JSON health summary
#    audit | test               tsvpn-audit.sh / tsvpn-test-exit.sh output
#    speed-inet <direct|tunnel> [streams] [secs]
#    iperf-server [secs]        host only
#    iperf <host-100.x> <down|up> [streams] [secs]
#    selfheal                   re-apply everything (detached; returns at once)
#    restart-tailscale | reboot (detached)
#    config-get                 node.json + client WiFi name
#    config-set                 JSON on stdin: targets, exit_node, collide,
#                               dns_upstream, wifi_ssid, wifi_key
#    host-pub                   this host's dashboard public key
#  Generic.
# ============================================================
D=/etc/tsvpn
. $D/tsvpn-lib.sh
tsvpn_load >/dev/null 2>&1

[ $# -eq 0 ] && [ -n "$SSH_ORIGINAL_COMMAND" ] && set -- $SSH_ORIGINAL_COMMAND

isip()  { echo "$1" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; }
isnet() { echo "$1" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$'; }
isnum() { echo "$1" | grep -qE '^[0-9]{1,3}$' && [ "$1" -ge "$2" ] && [ "$1" -le "$3" ]; }
bad()   { echo "error: $*"; exit 2; }
detach(){ ( sleep 1; "$@" >/dev/null 2>&1 ) </dev/null >/dev/null 2>&1 & }
jstr()  { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

A=$1; shift 2>/dev/null
case "$A" in
status)
	ST=$(timeout 15 tailscale status --json 2>/dev/null)
	BS=$(echo "$ST" | jsonfilter -e '@.BackendState' 2>/dev/null)
	EXON=$(echo "$ST" | jsonfilter -e '@.ExitNodeStatus.Online' 2>/dev/null)
	PID=$(pidof tailscaled | cut -d' ' -f1)
	RSS=$([ -n "$PID" ] && awk '/VmRSS/{print int($2/1024)}' /proc/$PID/status)
	MA=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo)
	if [ -f /etc/config/chrony ]; then
		chronyc tracking 2>/dev/null | grep -q 'Leap status *: Normal' && CLK=synced || CLK=unsynced
	else
		pgrep -f 'ntpd.*-p 216.239.35.0' >/dev/null && CLK=sysntpd || CLK=unknown
	fi
	WD=$(grep -c '^==' $D/watchdog.log 2>/dev/null); WD=${WD:-0}
	LAST=$(head -1 /var/log/tsvpn-selfheal.log 2>/dev/null | sed 's/^== tsvpn self-heal: //; s/ ==$//')
	printf '{"node":"%s","role":"%s","deployment":"%s","tailnet_ip":"%s","backend":"%s",' \
		"$(jstr "$NODE")" "$ROLE" "$(jstr "$DEPLOYMENT")" "$(tailscale ip -4 2>/dev/null | head -1)" "${BS:-down}"
	printf '"exit_node":"%s","exit_online":"%s","uptime_s":%s,"load":"%s","mem_avail_mb":%s,"tailscaled_mb":%s,' \
		"$EXIT_NODE" "${EXON:-}" "$(cut -d. -f1 /proc/uptime)" "$(cut -d' ' -f1-3 /proc/loadavg)" "${MA:-0}" "${RSS:-0}"
	printf '"clock":"%s","time":"%s","firmware":"%s","tailscale":"%s","model":"%s","watchdog_events":%s,' \
		"$CLK" "$(date '+%Y-%m-%d %H:%M:%S %Z')" "$(cat /etc/glversion 2>/dev/null)" \
		"$(tailscale version 2>/dev/null | head -1)" "$(jstr "$(cat /tmp/sysinfo/model 2>/dev/null)")" "$WD"
	printf '"wifi_ssid":"%s","last_selfheal":"%s","targets":"%s"}\n' \
		"$(jstr "$(uci -q get wireless.wifi2g.ssid)")" "$(jstr "$LAST")" "$(jstr "$TARGETS")"
	;;
audit) $D/tsvpn-audit.sh 2>&1 ;;
test)  $D/tsvpn-test-exit.sh 2>&1 ;;
speed-inet)
	case "$1" in direct|tunnel) ;; *) bad "mode must be direct or tunnel" ;; esac
	S=${2:-2}; T=${3:-8}
	isnum "$S" 1 8 || bad "streams 1-8"; isnum "$T" 3 30 || bad "seconds 3-30"
	sh $D/tsvpn-speedtest.sh inet "$1" "$S" "$T" 2>&1
	;;
iperf-server)
	[ "$ROLE" = host ] || bad "host only"
	T=${1:-60}; isnum "$T" 10 120 || bad "seconds 10-120"
	sh $D/tsvpn-speedtest.sh iperf-server "$T" 2>&1
	;;
iperf)
	isip "$1" || bad "server must be an IPv4 address"
	case "$2" in down|up) ;; *) bad "direction down|up" ;; esac
	S=${3:-2}; T=${4:-8}
	isnum "$S" 1 8 || bad "streams 1-8"; isnum "$T" 3 30 || bad "seconds 3-30"
	sh $D/tsvpn-speedtest.sh iperf "$1" "$2" "$S" "$T" 2>&1
	;;
selfheal)
	detach sh -c "$D/tsvpn-selfheal.sh > /var/log/tsvpn-selfheal.log 2>&1"
	echo "self-heal started; results in about a minute (re-run the audit)"
	;;
restart-tailscale)
	detach /etc/init.d/tailscale restart
	echo "restarting tailscale; this router is unreachable for ~15 s"
	;;
reboot)
	detach reboot
	echo "rebooting; back in about 1-2 minutes"
	;;
config-get)
	printf '{"node":%s,"wifi_ssid":"%s"}\n' "$(cat $TSVPN_NODE)" "$(jstr "$(uci -q get wireless.wifi2g.ssid)")"
	;;
config-set)
	IN=$(head -c 4096)
	j() { echo "$IN" | jsonfilter -e "$1" 2>/dev/null; }
	NT=$(j '@.targets[*]' | tr '\n' ' '); NX=$(j '@.exit_node'); NC=$(j '@.collide')
	ND=$(j '@.dns_upstream[*]' | tr '\n' ' '); WS=$(j '@.wifi_ssid'); WK=$(j '@.wifi_key')
	for t in $NT $ND; do isip "$t" || bad "not an IPv4 address: $t"; done
	[ "$ROLE" = remote ] && { isip "$NX" || bad "remote needs exit_node (100.x)"; }
	[ -z "$NC" ] || isnet "$NC" || bad "collide must look like 192.168.1.0/24"
	if [ -n "$WS" ]; then
		echo "$WS" | grep -qE '^[A-Za-z0-9 ._-]{1,28}$' || bad "WiFi name: 1-28 of letters, digits, space . _ -"
		echo "$WK" | grep -qE '^[A-Za-z0-9!#%+,./:=?@^_~-]{8,63}$' || bad "WiFi key: 8-63 chars, no quotes, spaces or \\ \$ \` ; & |"
	fi
	arr() { o=""; for v in $1; do o="${o:+$o,}\"$v\""; done; echo "[$o]"; }
	NEW="{\n  \"deployment\": \"$(jstr "$DEPLOYMENT")\",\n  \"node\": \"$(jstr "$NODE")\",\n  \"role\": \"$ROLE\",\n  \"targets\": $(arr "$NT")"
	[ "$ROLE" = remote ] && NEW="$NEW,\n  \"exit_node\": \"$NX\""
	[ -n "$NC" ] && NEW="$NEW,\n  \"collide\": \"$NC\""
	[ -n "$ND" ] && NEW="$NEW,\n  \"dns_upstream\": $(arr "$ND")"
	TI=$(tsvpn_get '@.tailnet_ip'); [ -n "$TI" ] && NEW="$NEW,\n  \"tailnet_ip\": \"$TI\""
	printf '%b' "$NEW\n}\n" > /tmp/tsvpn-node.new   # %b: expand \n, never treat input as a format
	jsonfilter -i /tmp/tsvpn-node.new -e '@.role' >/dev/null 2>&1 || bad "generated node.json does not parse"
	cp $TSVPN_NODE $TSVPN_NODE.bak-web; cat /tmp/tsvpn-node.new > $TSVPN_NODE; rm -f /tmp/tsvpn-node.new
	$D/tsvpn-persist.sh >/dev/null 2>&1 || { cp $TSVPN_NODE.bak-web $TSVPN_NODE; bad "persist failed; restored the old node.json"; }
	if [ -n "$WS" ]; then
		uci set wireless.wifi2g.ssid="$WS"; uci set wireless.wifi5g.ssid="$WS-5g"
		uci set wireless.wifi2g.key="$WK"; uci set wireless.wifi5g.key="$WK"
		uci commit wireless; detach wifi reload
		echo "client WiFi set to '$WS' / '$WS-5g' (devices on it must rejoin)"
	fi
	echo "node.json saved (previous: node.json.bak-web) and persisted into rc.local"
	detach sh -c "$D/tsvpn-selfheal.sh > /var/log/tsvpn-selfheal.log 2>&1"
	echo "self-heal started to apply it; re-run the audit in about a minute"
	;;
host-pub)
	[ "$ROLE" = host ] && cat /etc/dropbear/tsvpn_host_ed25519.pub 2>/dev/null
	;;
*)
	bad "unknown action '$A'"
	;;
esac
