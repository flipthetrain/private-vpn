#!/bin/sh
# ============================================================
#  tsvpn-lib.sh — shared config reader (macOS)
#
#  Sourced by every other tsvpn script. Reads the ONE file that
#  is unique to this machine: /etc/tsvpn/node.json.
#
#  This platform supports role=host ONLY. See tsvpn_check.
#
#  JSON is read with `plutil`, which ships with macOS. python3
#  does NOT: since macOS 12.3 it only exists if the Xcode command
#  line tools are installed, so relying on it would make the
#  scripts fail on a clean machine.
#
#  Generic. Do not put site values in here.
# ============================================================

TSVPN_DIR=${TSVPN_DIR:-/etc/tsvpn}
TSVPN_NODE=${TSVPN_NODE:-$TSVPN_DIR/node.json}
TSVPN_LOG=${TSVPN_LOG:-/var/log/tsvpn-selfheal.log}

_json_scalar() {   # _json_scalar <keypath>
	if command -v plutil >/dev/null 2>&1; then
		plutil -extract "$1" raw -o - "$TSVPN_NODE" 2>/dev/null
	elif command -v python3 >/dev/null 2>&1; then
		python3 -c 'import json,sys
d=json.load(open(sys.argv[1]))
v=d.get(sys.argv[2])
print("" if v is None else v)' "$TSVPN_NODE" "$1" 2>/dev/null
	fi
}

_json_list() {     # _json_list <key> -> space separated
	_out=""; _i=0
	while [ $_i -lt 64 ]; do
		_v=$(_json_scalar "$1.$_i") || break
		[ -z "$_v" ] && break
		_out="${_out:+$_out }$_v"
		_i=$((_i + 1))
	done
	# python3 fallback cannot do indexed keypaths; take the whole list at once
	if [ -z "$_out" ] && ! command -v plutil >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
		_out=$(python3 -c 'import json,sys
d=json.load(open(sys.argv[1]))
v=d.get(sys.argv[2]) or []
print(" ".join(str(x) for x in ([v] if isinstance(v,str) else v)))' "$TSVPN_NODE" "$1" 2>/dev/null)
	fi
	echo "$_out"
}

tsvpn_load() {
	if [ ! -f "$TSVPN_NODE" ]; then
		echo "tsvpn: no $TSVPN_NODE — this machine has no identity." >&2
		echo "tsvpn: create it (see scripts/macos/README.md) or re-run tsvpn-install.sh." >&2
		return 1
	fi
	if command -v plutil >/dev/null 2>&1 && ! plutil -lint "$TSVPN_NODE" >/dev/null 2>&1; then
		echo "tsvpn: $TSVPN_NODE is not valid JSON." >&2
		return 1
	fi

	DEPLOYMENT=$(_json_scalar deployment)
	NODE=$(_json_scalar node)
	ROLE=$(_json_scalar role)
	TARGETS=$(_json_list targets)
	EXIT_NODE=$(_json_scalar exit_node)

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
		echo "tsvpn: role=\"$ROLE\" is not supported on macOS." >&2
		echo "" >&2
		echo "  A Mac can only be a HOST here." >&2
		echo "" >&2
		echo "  Being a remote means running an access point, DHCP and DNS for" >&2
		echo "  other devices, and a kill-switch that drops forwarded traffic" >&2
		echo "  when the tunnel is down. macOS Internet Sharing does some of" >&2
		echo "  that, but it is not scriptable in any stable way and cannot be" >&2
		echo "  verified, so this would be a security control you could not" >&2
		echo "  trust." >&2
		echo "" >&2
		echo "  For a remote, use scripts/glinet/ or scripts/rasp-pi/." >&2
		rc=1
	fi
	for t in $TARGETS; do
		case "$t" in
			*/*|*:*|"") echo "tsvpn: target \"$t\" must be a bare IPv4 address (no /32, no port)." >&2; rc=1 ;;
		esac
	done
	return $rc
}

# --- locating Tailscale, and rejecting the variant that cannot do this job ---
#
# The Mac App Store build is sandboxed. It cannot advertise subnet routes or act
# as an exit node, so it is useless as a host no matter how it is configured.
# The standalone build ships a CLI inside the app bundle; Homebrew puts one on
# PATH. Detect the App Store build by its receipt, which only that build has.
tsvpn_tailscale() {
	for c in /Applications/Tailscale.app/Contents/MacOS/Tailscale \
	         /opt/homebrew/bin/tailscale /usr/local/bin/tailscale; do
		[ -x "$c" ] && { echo "$c"; return 0; }
	done
	command -v tailscale 2>/dev/null && return 0
	return 1
}

tsvpn_is_appstore_build() {
	[ -e /Applications/Tailscale.app/Contents/_MASReceipt ]
}
