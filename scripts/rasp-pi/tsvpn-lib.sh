#!/bin/sh
# ============================================================
#  tsvpn-lib.sh — shared config reader (Raspberry Pi / Debian)
#
#  Sourced by every other tsvpn script. Reads the ONE file that
#  is unique to this machine: /etc/tsvpn/node.json. Everything
#  else in /etc/tsvpn is identical on every node of every
#  deployment.
#
#  Generic. Do not put site values in here.
# ============================================================

TSVPN_DIR=${TSVPN_DIR:-/etc/tsvpn}
TSVPN_NODE=${TSVPN_NODE:-$TSVPN_DIR/node.json}
TSVPN_LOG=${TSVPN_LOG:-/var/log/tsvpn-selfheal.log}

# tsvpn_get <dotted.key> — read one value, empty if absent.
# Kept for ad-hoc use; tsvpn_load is what the scripts actually call.
tsvpn_get() {
	python3 - "$TSVPN_NODE" "$1" <<-'PY' 2>/dev/null
	import json,sys
	d=json.load(open(sys.argv[1]))
	for k in sys.argv[2].split('.'):
	    if not isinstance(d,dict): d=None; break
	    d=d.get(k)
	if d is None: pass
	elif isinstance(d,list): print(' '.join(str(x) for x in d))
	else: print(d)
	PY
}

# tsvpn_load — populate the shell variables every script uses.
# Returns 1 if node.json is missing or unusable, which is always fatal.
tsvpn_load() {
	if [ ! -f "$TSVPN_NODE" ]; then
		echo "tsvpn: no $TSVPN_NODE — this machine has no identity." >&2
		echo "tsvpn: create it (see scripts/rasp-pi/README.md) or re-run tsvpn-install.sh." >&2
		return 1
	fi

	_vars=$(python3 - "$TSVPN_NODE" <<-'PY'
	import json,sys,shlex
	try:
	    d=json.load(open(sys.argv[1]))
	except Exception as e:
	    sys.stderr.write("tsvpn: %s is not valid JSON: %s\n"%(sys.argv[1],e)); sys.exit(1)
	if not isinstance(d,dict):
	    sys.stderr.write("tsvpn: top level of node.json must be an object\n"); sys.exit(1)
	q=lambda v: shlex.quote(str(v))
	def lst(k):
	    v=d.get(k) or []
	    if isinstance(v,str): v=[v]
	    return ' '.join(str(x) for x in v)
	out={
	 'DEPLOYMENT': d.get('deployment',''),
	 'NODE':       d.get('node',''),
	 'ROLE':       d.get('role',''),
	 'TARGETS':    lst('targets'),
	 'EXIT_NODE':  d.get('exit_node',''),
	 'COLLIDE':    d.get('collide',''),
	 'DNS_UPSTREAM': lst('dns_upstream'),
	 # --- Raspberry Pi specific, all optional ---
	 'WAN_IFACE':  d.get('wan_iface',''),
	 'LAN_IFACE':  d.get('lan_iface',''),
	 'LAN_CIDR':   d.get('lan_cidr',''),
	}
	for k,v in out.items(): print("%s=%s"%(k,q(v)))
	PY
	) || return 1
	eval "$_vars"
	unset _vars

	if [ -z "$ROLE" ]; then
		echo "tsvpn: $TSVPN_NODE has no \"role\" (expected \"host\" or \"remote\")." >&2
		return 1
	fi
	case "$ROLE" in
		host|remote) ;;
		*) echo "tsvpn: role \"$ROLE\" is not \"host\" or \"remote\"." >&2; return 1 ;;
	esac

	# A remote node resolves through the host by default, so a lookup made at the
	# remote site is answered by the HOST site's resolver and egresses at the
	# host site's IP. Only override dns_upstream if you know why.
	if [ "$ROLE" = "remote" ] && [ -z "$DNS_UPSTREAM" ]; then
		DNS_UPSTREAM="$EXIT_NODE"
	fi

	# Interface defaults. WAN is whatever currently carries the default route
	# that is NOT the tunnel; LAN is the Pi's built-in wireless.
	[ -z "$WAN_IFACE" ] && WAN_IFACE=$(ip -4 route show default 2>/dev/null \
		| grep -v tailscale | awk '{print $5; exit}')
	[ "$ROLE" = "remote" ] && [ -z "$LAN_IFACE" ] && LAN_IFACE=wlan0
	[ "$ROLE" = "remote" ] && [ -z "$LAN_CIDR" ] && LAN_CIDR=192.168.9.1/24
	LAN_ADDR=${LAN_CIDR%%/*}
	LAN_NET=$(echo "$LAN_CIDR" | python3 -c 'import sys,ipaddress
try: print(ipaddress.ip_interface(sys.stdin.read().strip()).network)
except Exception: print("")' 2>/dev/null)

	# Comma-separated /32 list for --advertise-routes
	ROUTES=""
	for t in $TARGETS; do
		ROUTES="${ROUTES:+$ROUTES,}$t/32"
	done
	return 0
}

# tsvpn_check — validate the combination of values for this role.
tsvpn_check() {
	rc=0
	if [ "$ROLE" = "remote" ]; then
		[ -n "$EXIT_NODE" ] || { echo "tsvpn: role=remote needs \"exit_node\" (the host's 100.x address)." >&2; rc=1; }
		[ -n "$LAN_NET" ]   || { echo "tsvpn: lan_cidr \"$LAN_CIDR\" is not a valid address/prefix." >&2; rc=1; }
	fi
	[ -n "$WAN_IFACE" ] || { echo "tsvpn: could not determine the uplink interface; set \"wan_iface\"." >&2; rc=1; }
	for t in $TARGETS; do
		case "$t" in
			*/*|*:*|"") echo "tsvpn: target \"$t\" must be a bare IPv4 address (no /32, no port)." >&2; rc=1 ;;
		esac
	done
	return $rc
}
