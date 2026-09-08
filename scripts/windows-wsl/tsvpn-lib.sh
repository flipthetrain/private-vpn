#!/bin/sh
# ============================================================
#  tsvpn-lib.sh — shared config reader (WSL / Ubuntu)
#
#  Sourced by every other tsvpn script. Reads the ONE file that
#  is unique to this machine: /etc/tsvpn/node.json.
#
#  This platform supports role=host ONLY. A WSL instance cannot
#  be a remote: it lives behind Windows' NAT, so no other device
#  on the LAN can route through it. tsvpn_check refuses.
#
#  Generic. Do not put site values in here.
# ============================================================

TSVPN_DIR=${TSVPN_DIR:-/etc/tsvpn}
TSVPN_NODE=${TSVPN_NODE:-$TSVPN_DIR/node.json}
TSVPN_LOG=${TSVPN_LOG:-/var/log/tsvpn-selfheal.log}

# WSL breaks `tailscale` when the working directory is a Windows path
# (/mnt/c, /mnt/d ...): the CLI cannot resolve its own cwd and exits. Every
# script sources this, so move somewhere safe once, here.
case "$PWD" in
	/mnt/*) cd / 2>/dev/null || true ;;
esac

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

tsvpn_load() {
	if [ ! -f "$TSVPN_NODE" ]; then
		echo "tsvpn: no $TSVPN_NODE — this machine has no identity." >&2
		echo "tsvpn: create it (see scripts/windows-wsl/README.md) or re-run tsvpn-install.sh." >&2
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
	out={'DEPLOYMENT':d.get('deployment',''),'NODE':d.get('node',''),'ROLE':d.get('role',''),
	     'TARGETS':lst('targets'),'EXIT_NODE':d.get('exit_node',''),'COLLIDE':d.get('collide','')}
	for k,v in out.items(): print("%s=%s"%(k,q(v)))
	PY
	) || return 1
	eval "$_vars"
	unset _vars

	[ -n "$ROLE" ] || { echo "tsvpn: $TSVPN_NODE has no \"role\"." >&2; return 1; }

	ROUTES=""
	for t in $TARGETS; do
		ROUTES="${ROUTES:+$ROUTES,}$t/32"
	done
	return 0
}

tsvpn_check() {
	rc=0
	if [ "$ROLE" != "host" ]; then
		echo "tsvpn: role=\"$ROLE\" is not supported on WSL." >&2
		echo "" >&2
		echo "  A WSL instance can only be a HOST." >&2
		echo "" >&2
		echo "  It cannot be a remote, and this is a hard limit, not a missing" >&2
		echo "  feature: WSL2 sits behind a NAT that Windows manages, so no TV," >&2
		echo "  console or phone on the local network can use it as a gateway." >&2
		echo "  There is no route to it and no way to hand one out." >&2
		echo "" >&2
		echo "  For a remote, use scripts/glinet/ or scripts/rasp-pi/ on real hardware." >&2
		rc=1
	fi
	for t in $TARGETS; do
		case "$t" in
			*/*|*:*|"") echo "tsvpn: target \"$t\" must be a bare IPv4 address (no /32, no port)." >&2; rc=1 ;;
		esac
	done
	return $rc
}

# --- WSL facts the other scripts report on ---
wsl_is_wsl()      { grep -qi microsoft /proc/version 2>/dev/null; }
wsl_net_mode()    { command -v wslinfo >/dev/null 2>&1 && wslinfo --networking-mode 2>/dev/null || echo unknown; }
wsl_has_systemd() { [ "$(ps -p 1 -o comm= 2>/dev/null)" = "systemd" ]; }
wsl_has_tun()     { [ -c /dev/net/tun ]; }
