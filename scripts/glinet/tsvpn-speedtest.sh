#!/bin/sh
# ============================================================
#  tsvpn-speedtest.sh — throughput measurements, run ON a router.
#  Usually driven from your machine by `tsvpn-provision.sh speed`,
#  which combines them into one report and names the bottleneck.
#
#    tsvpn-speedtest.sh inet <direct|tunnel> [streams] [seconds]
#        internet download + upload. direct = out of THIS site's own
#        uplink (bypasses the tunnel; a remote's own internet speed).
#        tunnel = the normal route (on a remote: via the exit node,
#        i.e. what its clients get; on a host the two are the same).
#    tsvpn-speedtest.sh iperf-server [seconds]
#        one-shot iperf3 server on the tailnet address (host side).
#    tsvpn-speedtest.sh iperf <server-100.x> <down|up> [streams] [seconds]
#        raw tunnel throughput to the host, no internet involved.
#        down = host -> this router (the direction video flows).
#
#  Prints human lines plus `RESULT key=value` lines for the driver.
#  Also reports this router's CPU load during each test: at ~100 %
#  the ROUTER, not the line, is the limit (WireGuard runs on the CPU).
#
#  Uses Cloudflare's speed endpoints (as speed.cloudflare.com does).
#  A single request is capped below 100 MB, so each stream repeats
#  50 MB requests until its time is up. Uploads send a file held in
#  RAM, because piping /dev/zero through curl is CPU-bound here.
#
#  Changes nothing on the router. Generic.
# ============================================================
CF=https://speed.cloudflare.com
CHUNK=50000000
UPSZ=10000000
# GL firmware points the router's OWN resolv.conf at the site's DHCP resolver,
# not at dnsmasq. Resolve once via dnsmasq (127.0.0.1) and pin it with
# --resolve, so a broken site resolver cannot fail the test.
res() { nslookup "$1" 127.0.0.1 2>/dev/null | sed -n 's/^Address [0-9]*: \([0-9.]*\)$/\1/p' | head -1; }
CFIP=$(res speed.cloudflare.com)
PIN=${CFIP:+--resolve speed.cloudflare.com:443:$CFIP}
# Download fallback: Cloudflare rate-limits an IP that tests a lot (HTTP 429).
# A big plain-HTTP file then: one request covers a whole timed stream, and
# no HTTPS means the router's CPU measures the line, not the TLS.
FB_HOST=ash-speed.hetzner.com
FB_URL=http://$FB_HOST/1GB.bin
FBIP=$(res $FB_HOST)
FBPIN=${FBIP:+--resolve $FB_HOST:80:$FBIP}
DLSRC=cloudflare
memok() {   # refuse to load a router that is already short of memory
	a=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo)
	[ "${a:-0}" -ge "${1:-80}" ] || { echo "   SKIPPED: only ${a} MB available (need ${1:-80})"; return 1; }
}
WAN=$(uci -q get network.wan.device || echo eth0)

now()  { cut -d' ' -f1 /proc/uptime; }
cpu()  { awk '/^cpu /{print $2+$3+$4+$7+$8, $5+$6}' /proc/stat; }  # busy idle
cpupct() {   # cpupct "<busy0 idle0>" "<busy1 idle1>"
	echo "$1 $2" | awk '{b=$3-$1; i=$4-$2; if (b+i>0) printf "%.0f", 100*b/(b+i); else print 0}'
}
mbps() { echo "$1 $2" | awk '{t=$2; if (t<0.1) t=0.1; printf "%.0f", $1*8/t/1e6}'; }

# stream <down|up> <secs> <ifopt> — one worker; prints bytes moved
stream() {
	end=$(echo "$(now) $2" | awk '{print $1+$2}'); tot=0
	while :; do
		left=$(echo "$end $(now)" | awk '{printf "%d", $1-$2}')
		[ "$left" -ge 1 ] || break
		if [ "$1" = down ] && [ "$DLSRC" = hetzner ]; then
			n=$(curl -s $FBPIN $3 -o /dev/null --max-time "$left" -w '%{http_code} %{size_download}' "$FB_URL" 2>/dev/null)
		elif [ "$1" = down ]; then
			n=$(curl -s $PIN $3 -o /dev/null --max-time "$left" -w '%{http_code} %{size_download}' "$CF/__down?bytes=$CHUNK" 2>/dev/null)
		else
			n=$(curl -s $PIN $3 -o /dev/null --max-time "$left" -X POST --data-binary @/tmp/tsvpn-up.bin \
				-w '%{http_code} %{size_upload}' "$CF/__up" 2>/dev/null)
		fi
		# any status but 200 (403 too big, 429 rate-limited) ends this stream:
		# never retry a refusal in a tight loop
		c=${n%% *}; n=${n##* }
		[ "$c" = 200 ] || break
		[ "$n" -gt 0 ] 2>/dev/null || break
		tot=$((tot + n))
	done
	echo "$tot"
}

# run <down|up> <streams> <secs> <ifopt> — prints "<mbit/s> <cpu%> <bytes>"
run() {
	c0=$(cpu); t0=$(now)
	i=0; while [ $i -lt "$2" ]; do stream "$1" "$3" "$4" > /tmp/tsvpn-sp.$i & i=$((i+1)); done
	wait
	t1=$(now); c1=$(cpu)
	b=$(cat /tmp/tsvpn-sp.* 2>/dev/null | awk '{s+=$1} END{printf "%d", s}'); rm -f /tmp/tsvpn-sp.*
	echo "$(mbps "$b" "$(echo "$t1 $t0" | awk '{print $1-$2}')") $(cpupct "$c0" "$c1") $b"
}

case "$1" in
inet)
	MODE=${2:-tunnel}; P=${3:-4}; S=${4:-10}
	IFOPT=""; [ "$MODE" = direct ] && IFOPT="--interface $WAN"
	K=$MODE; [ "$MODE" = tunnel ] && K=exit
	memok 80 || { echo "RESULT ${K}_down=-1 ${K}_up=-1"; exit 0; }
	EG=$(curl -s $IFOPT --max-time 8 https://ifconfig.me/ip)
	echo "-- internet, $MODE (${P} streams x ${S}s, egress ${EG:-?}) --"
	head -c $UPSZ /dev/zero > /tmp/tsvpn-up.bin
	[ -n "$CFIP" ] || echo "   note: could not resolve the test server via dnsmasq; using the system resolver"
	# probe at the real request size: the limiter lets small requests through
	code=$(curl -s $PIN $IFOPT -o /dev/null --max-time 3 -w '%{http_code}' "$CF/__down?bytes=$CHUNK")
	[ "$code" = 200 ] || DLSRC=hetzner
	echo "   download source: $DLSRC$( [ "$DLSRC" = hetzner ] && echo " (Cloudflare answered HTTP $code)")"
	set -- $(run down "$P" "$S" "$IFOPT"); [ "$3" -gt 0 ] || set -- -1 "$2"; echo "   download $1 Mbit/s   (router CPU $2%)"
	echo "RESULT ${K}_down=$1 ${K}_down_cpu=$2"
	set -- $(run up "$P" "$S" "$IFOPT");   [ "$3" -gt 0 ] || set -- -1 "$2"; echo "   upload   $1 Mbit/s   (router CPU $2%)"
	echo "RESULT ${K}_up=$1 ${K}_up_cpu=$2"
	rm -f /tmp/tsvpn-up.bin
	;;
iperf-server)
	memok 80 || exit 1
	killall iperf3 2>/dev/null; sleep 1   # a leftover server would hold the port
	IP=$(tailscale ip -4 | head -1)
	# -1: exits after one test. The timeout stops a forgotten server.
	( timeout "${2:-60}" iperf3 -s -1 -B "$IP" >/dev/null 2>&1 & )
	sleep 1; echo "iperf3 server on $IP:5201 (one test)"
	;;
iperf)
	H=$2; DIR=${3:-down}; P=${4:-4}; S=${5:-10}
	R=""; [ "$DIR" = down ] && R="-R"
	c0=$(cpu)
	J=$(iperf3 -c "$H" $R -P "$P" -t "$S" -J 2>/dev/null)
	c1=$(cpu)
	BPS=$(echo "$J" | jsonfilter -e '@.end.sum_received.bits_per_second' 2>/dev/null)
	RT=$(echo "$J" | jsonfilter -e '@.end.sum_sent.retransmits' 2>/dev/null)
	M=$(echo "${BPS:-0}" | awk '{printf "%.0f", $1/1e6}')
	C=$(cpupct "$c0" "$c1")
	echo "-- tunnel only, $DIR (host $( [ "$DIR" = down ] && echo '->' || echo '<-' ) this router; ${P} streams x ${S}s) --"
	[ "$M" -gt 0 ] && echo "   $M Mbit/s   (router CPU $C%, retransmits ${RT:-?})" || echo "   FAILED: $(echo "$J" | jsonfilter -e '@.error' 2>/dev/null)"
	[ "$M" -gt 0 ] || M=-1
	echo "RESULT tunnel_$DIR=$M tunnel_${DIR}_cpu=$C"
	;;
*)
	sed -n '2,28p' "$0" | sed 's/^#\{1,2\} \{0,1\}//'; exit 2 ;;
esac
