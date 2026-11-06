#!/bin/sh
# ============================================================
#  tsvpn-provision.sh — turn a factory-fresh GL.iNet into a
#  host or remote, from YOUR machine, one step at a time.
#
#  Each step is idempotent and safe to re-run. Steps stop at the
#  points where a person has to do something, and say what.
#
#    discover                              find GL.iNet routers on this network
#    new-host   <tailnet> <name> <target-ip>... [--dns-upstream <ip>]...
#    new-remote <tailnet> <name>           derive from the host already in networks/<tailnet>/
#    bootstrap  <addr> <node.json>         key login, hostname, Tailscale on
#    login      <addr> <node.json> [--wait]  join the tailnet; prints the approval URL
#    install    <addr> <node.json>         preflight + tsvpn-push.sh (self-heal + audit)
#    lockdown   <100.x>                    close WAN-side SSH; admin only via the tunnel
#    wifi       <addr> <ssid> <key>        set the client WiFi (2.4G = ssid, 5G = ssid-5g)
#    test       <addr>                     end-to-end exit-node test (remote)
#    speed      <tailnet> [node...] [--secs N] [--streams N]
#                                          throughput: host internet, each remote's
#                                          own internet, the tunnel, and what its
#                                          clients can get; names the bottleneck
#    audit      <addr>                     run the installed audit
#    reinstall-remotes <tailnet>           re-push every remote (after a host rebuild)
#
#  <addr> is anything that reaches the router: its WAN address on the
#  site network (only after WAN SSH is enabled, see below), 192.168.8.1
#  from its own LAN/WiFi, or its 100.x tailnet address.
#
#  Environment (all optional):
#    TSVPN_PASSWORD   router admin password; used ONCE by bootstrap to
#                     install your key. Never written anywhere.
#    TSVPN_AUTHKEY    Tailscale auth key; login then needs no browser.
#    TSVPN_PUBKEY     public key to install (default ~/.ssh/id_ed25519.pub)
#
#  Needs on this machine: ssh, python3. The step-by-step guide is
#  scripts/glinet/README.md "Quick start"; Claude Code users can run the
#  repo's tsvpn-new-router skill instead.
# ============================================================
set -e

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
NETS="$REPO/networks"
PUBKEY=${TSVPN_PUBKEY:-$HOME/.ssh/id_ed25519.pub}
SSHO="-o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new"

die()  { echo "error: $*" >&2; exit 1; }
say()  { echo "==> $*"; }
todo() { echo; echo ">>> YOU: $*"; echo; }
rsh()  { a=$1; shift; ssh $SSHO -o BatchMode=yes "root@$a" "$@"; }

# jget <file> <key> — top-level JSON value (lists joined by spaces)
jget() {
	python3 -c 'import json,sys
v=json.load(open(sys.argv[1])).get(sys.argv[2],"")
print(" ".join(v) if isinstance(v,list) else v)' "$1" "$2"
}
# jset <file> <key> <value> — set a top-level string, keep the rest
jset() {
	python3 -c 'import json,sys
f,k,v=sys.argv[1:4]; d=json.load(open(f)); d[k]=v
open(f,"w").write(json.dumps(d,indent=2)+"\n")' "$1" "$2" "$3"
}
need_json() { [ -f "$1" ] || die "no such node file: $1"; }
host_json() {   # host_json <tailnet> — the one role=host file in that deployment
	for f in "$NETS/$1"/*.json; do
		[ -f "$f" ] && [ "$(jget "$f" role)" = host ] && { echo "$f"; return 0; }
	done
	return 1
}

cmd=$1; [ -n "$cmd" ] && shift
case "$cmd" in

discover)
	# GL.iNet OUIs. The router drops WAN input, so it may not answer ping;
	# a sweep still populates the neighbour table, which is what we read.
	OUI='94[:-]83[:-]c4|e4[:-]95[:-]6e'
	if command -v powershell.exe >/dev/null 2>&1; then
		# WSL: the LAN is only visible from the Windows side.
		powershell.exe -NoProfile -Command '
			$ips = Get-NetIPAddress -AddressFamily IPv4 | ? { $_.PrefixLength -eq 24 -and $_.IPAddress -notmatch "^(127|169|172\.(1[6-9]|2|3[01]))\." }
			foreach ($ip in $ips) { $n = ($ip.IPAddress -split "\.")[0..2] -join "."
				$t = 1..254 | % { (New-Object Net.NetworkInformation.Ping).SendPingAsync("$n.$_", 300) }
				[Threading.Tasks.Task]::WaitAll($t) }
			arp -a' 2>/dev/null | tr -d '\r' | grep -iE "$OUI" || true
	else
		NET=$(ip -4 route | awk '/proto kernel/ && $1 ~ /\/24$/ {print $1; exit}')
		[ -n "$NET" ] && for i in $(seq 1 254); do ping -c1 -W1 "${NET%.*}.$i" >/dev/null 2>&1 & done; wait
		ip neigh | grep -iE "$OUI" || true
	fi
	echo "(GL.iNet MACs above. A router's LAN side is MAC+1 of its WAN side and answers as 192.168.8.1.)"
	;;

new-host)
	TN=$1; NAME=$2; shift 2 || die "usage: new-host <tailnet> <name> <target-ip>... [--dns-upstream <ip>]..."
	T=""; D=""
	while [ $# -gt 0 ]; do
		case "$1" in
			--dns-upstream) D="$D $2"; shift 2 ;;
			*) T="$T $1"; shift ;;
		esac
	done
	mkdir -p "$NETS/$TN"
	host_json "$TN" >/dev/null && die "$TN already has a host: $(host_json "$TN") — use reinstall-remotes after rebuilding it"
	F="$NETS/$TN/$NAME.json"
	python3 -c 'import json,sys
tn,name,t,d,f=sys.argv[1:6]
o={"deployment":tn,"node":name,"role":"host","targets":t.split()}
if d.split(): o["dns_upstream"]=d.split()
open(f,"w").write(json.dumps(o,indent=2)+"\n")' "$TN" "$NAME" "$T" "$D" "$F"
	say "wrote $F"; cat "$F"
	;;

new-remote)
	TN=$1; NAME=$2
	[ -n "$NAME" ] || die "usage: new-remote <tailnet> <name>"
	H=$(host_json "$TN") || die "no host in $NETS/$TN — build the host first (new-host)"
	EX=$(jget "$H" tailnet_ip)
	if [ -z "$EX" ]; then   # fall back to what an existing remote already uses
		for f in "$NETS/$TN"/*.json; do
			[ "$(jget "$f" role)" = remote ] && { EX=$(jget "$f" exit_node); break; }
		done
	fi
	[ -n "$EX" ] || die "the host's 100.x is unknown: add \"tailnet_ip\" to $H (login --wait does this)"
	TG=$(jget "$H" targets)
	# collide = the host-site range the targets live in (dormant unless the
	# remote's own LAN uses it too). Prefer an existing remote's value.
	CO=""
	for f in "$NETS/$TN"/*.json; do
		[ "$(jget "$f" role)" = remote ] && CO=$(jget "$f" collide) && [ -n "$CO" ] && break
	done
	[ -n "$CO" ] || CO="$(echo "$TG" | awk '{print $1}' | cut -d. -f1-3).0/24"
	F="$NETS/$TN/$NAME.json"
	[ -f "$F" ] && die "$F already exists"
	python3 -c 'import json,sys
tn,name,t,ex,co,f=sys.argv[1:7]
o={"deployment":tn,"node":name,"role":"remote","targets":t.split(),"exit_node":ex,"collide":co}
open(f,"w").write(json.dumps(o,indent=2)+"\n")' "$TN" "$NAME" "$TG" "$EX" "$CO" "$F"
	say "wrote $F"; cat "$F"
	;;

bootstrap)
	A=$1; J=$2; need_json "$J"
	NAME=$(jget "$J" node)
	[ -f "$PUBKEY" ] || die "no public key at $PUBKEY (ssh-keygen -t ed25519, or set TSVPN_PUBKEY)"
	if ! rsh "$A" true 2>/dev/null; then
		if [ -z "$TSVPN_PASSWORD" ]; then
			todo "SSH on $A is closed. On the router's admin page (http://192.168.8.1 from its WiFi):
     1. finish the setup wizard (admin password, timezone)
     2. System > Upgrade: install the latest firmware
     3. Security > Remote Access Control: enable SSH (WAN). Apply.
   then re-run with TSVPN_PASSWORD=<admin password>."
			die "key login refused; set TSVPN_PASSWORD to install the key"
		fi
		say "installing $(basename "$PUBKEY") with the admin password (used once)"
		T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
		printf '#!/bin/sh\nprintf "%%s\\n" "$TSVPN_PASSWORD"\n' > "$T/ap"; chmod 700 "$T/ap"
		K=$(cat "$PUBKEY")
		SSH_ASKPASS="$T/ap" SSH_ASKPASS_REQUIRE=force DISPLAY=none setsid -w \
			ssh $SSHO -o PubkeyAuthentication=no "root@$A" \
			"mkdir -p /etc/dropbear; touch /etc/dropbear/authorized_keys; grep -qF '$K' /etc/dropbear/authorized_keys || echo '$K' >> /etc/dropbear/authorized_keys; chmod 600 /etc/dropbear/authorized_keys" \
			|| die "password login failed"
		rm -rf "$T"; trap - EXIT
		rsh "$A" true || die "key still refused after install"
	fi
	say "key login OK"
	rsh "$A" "
		uci set system.@system[0].hostname='$NAME'; uci commit system; echo '$NAME' > /proc/sys/kernel/hostname
		uci set tailscale.settings.enabled=1; uci set tailscale.settings.lan_enabled=1; uci commit tailscale
		tailscale status >/dev/null 2>&1 || { /etc/init.d/tailscale restart; sleep 8; }
		echo \"model     : \$(cat /tmp/sysinfo/model)\"
		echo \"firmware  : \$(cat /etc/glversion)   tailscale \$(tailscale version | head -1)\"
		echo \"timezone  : \$(uci -q get system.@system[0].zonename)\"
		echo \"hostname  : \$(uci get system.@system[0].hostname)\""
	;;

login)
	A=$1; J=$2; WAIT=$3; need_json "$J"
	NAME=$(jget "$J" node)
	st() { rsh "$A" "tailscale status --json 2>/dev/null | jsonfilter -e '@.BackendState'" 2>/dev/null; }
	if [ "$(st)" != Running ]; then
		if [ -n "$TSVPN_AUTHKEY" ]; then
			say "logging in with TSVPN_AUTHKEY"
			printf '%s' "$TSVPN_AUTHKEY" | rsh "$A" "umask 077; cat > /tmp/tsvpn-ak; tailscale login --hostname='$NAME' --auth-key=file:/tmp/tsvpn-ak --timeout=60s; rm -f /tmp/tsvpn-ak"
		else
			rsh "$A" "(tailscale login --hostname='$NAME' --timeout=900s > /tmp/tsvpn-login.log 2>&1 &) ; sleep 6"
			URL=$(rsh "$A" "tailscale status --json | jsonfilter -e '@.AuthURL'")
			[ -n "$URL" ] || URL=$(rsh "$A" "grep -o 'https://login.tailscale.com/[^ ]*' /tmp/tsvpn-login.log | head -1")
			todo "approve this router — sign in as $(jget "$J" deployment):
     $URL
   then in the console: Machines > $NAME > ... > Disable key expiry."
		fi
	fi
	if [ "$WAIT" = "--wait" ]; then
		i=0; while [ "$(st)" != Running ] && [ $i -lt 180 ]; do sleep 5; i=$((i+1)); done
	fi
	S=$(st)
	[ "$S" = Running ] || { echo "state: ${S:-unknown} — re-run 'login $A $J --wait' after approving"; exit 3; }
	IP=$(rsh "$A" "tailscale ip -4" | head -1)
	say "$NAME is on the tailnet at $IP"
	jset "$J" tailnet_ip "$IP"
	say "recorded tailnet_ip in $J"
	;;

install)
	A=$1; J=$2; need_json "$J"
	if [ "$(jget "$J" role)" = remote ]; then
		EX=$(jget "$J" exit_node)
		say "preflight: is $EX on this tailnet and offering an exit node?"
		rsh "$A" "tailscale status --json" | python3 -c 'import json,sys
ex=sys.argv[1]; d=json.load(sys.stdin)
for p in (d.get("Peer") or {}).values():
    if ex in [i.split("/")[0] for i in p.get("TailscaleIPs",[])]:
        print("    %s  online=%s  exit-node-offered=%s" % (p["HostName"], p.get("Online"), p.get("ExitNodeOption")))
        sys.exit(0 if p.get("ExitNodeOption") else 2)
print("    %s is not a peer of this router — wrong tailnet, or the host is not built yet" % ex); sys.exit(1)' "$EX" \
		|| die "fix the exit node first (if it offers but is not approved: console > host > Edit route settings)"
	fi
	"$HERE/tsvpn-push.sh" "$A" "$J"
	;;

lockdown)
	A=$1
	case "$A" in 100.*) ;; *) die "lockdown must run over the tailnet (100.x), or you would lock yourself out" ;; esac
	rsh "$A" '
		n=0
		for r in $(uci show firewall | sed -n "s/^firewall\.\([^.=]*\)=rule$/\1/p"); do
			[ "$(uci -q get firewall.$r.src)" = wan ] || continue
			[ "$(uci -q get firewall.$r.target)" = ACCEPT ] || continue
			case " $(uci -q get firewall.$r.dest_port) " in *" 22 "*|*" 80 "*|*" 443 "*)
				echo "    closing WAN rule $r ($(uci -q get firewall.$r.proto)/$(uci -q get firewall.$r.dest_port))"
				uci delete firewall.$r; n=$((n+1)) ;;
			esac
		done
		uci commit firewall; /etc/init.d/firewall reload >/dev/null 2>&1
		echo "    $n rule(s) closed; admin is now only via the tailnet"'
	;;

wifi)
	A=$1; SSID=$2; KEY=$3
	[ -n "$KEY" ] || die "usage: wifi <addr> <ssid> <key>"
	[ ${#KEY} -ge 8 ] || die "WiFi key must be at least 8 characters"
	say "setting client WiFi to '$SSID' / '$SSID-5g' (anyone on the old WiFi is dropped)"
	rsh "$A" "uci set wireless.wifi2g.ssid='$SSID'; uci set wireless.wifi5g.ssid='$SSID-5g'
		uci set wireless.wifi2g.key='$KEY'; uci set wireless.wifi5g.key='$KEY'
		uci commit wireless; (sleep 1; wifi reload) >/dev/null 2>&1 &"
	;;

test)
	rsh "$1" 'sh -s' < "$HERE/tsvpn-test-exit.sh"
	;;

audit)
	rsh "$1" /etc/tsvpn/tsvpn-audit.sh
	;;

speed)
	TN=$1; shift || die "usage: speed <tailnet> [node...] [--secs N] [--streams N]"
	H=$(host_json "$TN") || die "no host in $NETS/$TN"
	HIP=$(jget "$H" tailnet_ip); [ -n "$HIP" ] || die "no tailnet_ip in $H"
	SECS=8; STR=4; ONLY=""
	while [ $# -gt 0 ]; do
		case "$1" in --secs) SECS=$2; shift 2 ;; --streams) STR=$2; shift 2 ;; *) ONLY="$ONLY $1"; shift ;; esac
	done
	ST="$HERE/tsvpn-speedtest.sh"
	sp() { a=$1; shift; rsh "$a" "sh -s -- $*" < "$ST"; }   # never depends on the installed copy
	# The host carries every remote's internet: stop the moment it struggles.
	alive() {
		rsh "$HIP" "tailscale status --json | jsonfilter -e '@.BackendState'" 2>/dev/null | grep -q Running && return 0
		echo; echo "!!! host $HIP stopped answering — aborting the speed test. Remotes depend on it."
		echo "!!! the watchdog restarts tailscale within ~6 min; else power-cycle the host."; exit 4
	}
	val() { echo "$1" | tr ' ' '\n' | sed -n "s/^$2=//p" | tail -1; }
	echo "Saturates each line for ~$((SECS * 6))s per remote: video at that site will stutter meanwhile."
	echo "Uses roughly 1-2 GB of data per remote (matters on a capped plan)."
	echo
	say "host $(jget "$H" node) — its own internet"
	O=$(sp "$HIP" inet direct "$STR" "$SECS"); echo "$O" | grep -v '^RESULT'
	HR=$(echo "$O" | sed -n 's/^RESULT //p' | tr '\n' ' ')
	for f in "$NETS/$TN"/*.json; do
		[ "$(jget "$f" role)" = remote ] || continue
		N=$(jget "$f" node); RIP=$(jget "$f" tailnet_ip)
		[ -z "$ONLY" ] || echo " $ONLY " | grep -q " $N " || continue
		[ -n "$RIP" ] || { echo "skip $N: no tailnet_ip"; continue; }
		echo; say "remote $N ($RIP)"
		alive
		O=$(sp "$RIP" inet direct "$STR" "$SECS")
		for d in down up; do
			alive; sp "$HIP" iperf-server $((SECS + 30)) >/dev/null
			O="$O
$(sp "$RIP" iperf "$HIP" "$d" "$STR" "$SECS")"
		done
		alive
		O="$O
$(sp "$RIP" inet tunnel "$STR" "$SECS")"
		alive
		echo "$O" | grep -v '^RESULT'
		R=$(echo "$O" | sed -n 's/^RESULT //p' | tr '\n' ' ')
		python3 - "$N" "$HR" "$R" <<'PY'
import sys
name, hr, rr = sys.argv[1:4]
kv = lambda t: dict(x.split("=", 1) for x in t.split() if "=" in x)
h, r = kv(hr), kv(rr)
g = lambda d, k: int(d.get(k, 0) or 0)
pegged = lambda d, k: g(d, k + "_cpu") >= 85      # CPU-bound test = a floor, not the line rate
fmt = lambda d, k: "FAILED" if g(d, k) < 0 else ((">=" if pegged(d, k) else "") + str(g(d, k)))
print()
print("   %-40s %8s %8s" % ("SUMMARY " + name + " (Mbit/s)", "down", "up"))
for label, d, k in [("host internet (router-measured)", h, "direct"),
                    (name + "'s own internet, direct", r, "direct"),
                    ("tunnel only, host <-> " + name, r, "tunnel"),
                    ("router's own traffic via exit node *", r, "exit")]:
    print("   %-40s %8s %8s" % (label, fmt(d, k + "_down"), fmt(d, k + "_up")))
# Clients do their own HTTPS, so the router only forwards + encrypts: the
# tunnel figure, capped by the remote's own line and the host's, is their ceiling.
for dirn in ("down", "up"):
    c = {"tunnel": g(r, "tunnel_" + dirn), name + "'s own internet": g(r, "direct_" + dirn),
         "host internet": g(h, "direct_" + dirn)}
    if c["tunnel"] <= 0:
        print("   => %s: tunnel test FAILED, no conclusion (re-run: speed <tailnet> %s)" % (dirn, name))
        continue
    c = {k: v for k, v in c.items() if v > 0}
    lim = min(c, key=c.get); v = c[lim]
    why = lim
    if lim == "tunnel" and (g(r, "tunnel_%s_cpu" % dirn) >= 85):
        why = "router CPU (WireGuard encryption)"
    if dirn == "down":
        print("   => clients can get about %d Mbit/s down; limit: %s" % (v, why))
        print("      room for ~%d simultaneous 4K streams (25 Mbit/s) or ~%d HD (8 Mbit/s)" % (v // 25, v // 8))
    else:
        print("   => clients can send about %d Mbit/s up; limit: %s" % (v, why))
print("   * the router doing HTTPS + encryption at once; understates what clients get")
print("   The host forwards ALL remotes through one CPU: their total is about the tunnel")
print("   figure, so remotes streaming at once share it, and none can saturate the host's line.")
PY
	done
	;;

reinstall-remotes)
	TN=$1; H=$(host_json "$TN") || die "no host in $NETS/$TN"
	EX=$(jget "$H" tailnet_ip); [ -n "$EX" ] || die "no tailnet_ip in $H"
	for f in "$NETS/$TN"/*.json; do
		[ "$(jget "$f" role)" = remote ] || continue
		IP=$(jget "$f" tailnet_ip)
		[ "$(jget "$f" exit_node)" = "$EX" ] || { jset "$f" exit_node "$EX"; say "$(basename "$f"): exit_node -> $EX"; }
		[ -n "$IP" ] || { echo "skip $(basename "$f"): no tailnet_ip recorded"; continue; }
		say "reinstalling $(jget "$f" node) at $IP"
		"$HERE/tsvpn-push.sh" "$IP" "$f" | tail -3 || echo "    FAILED — check it is online in the console; the tailnet still reaches a remote whose exit node is down"
	done
	;;

*)
	sed -n '2,36p' "$0" | sed 's/^#\{1,2\} \{0,1\}//'
	exit 2
	;;
esac
