#!/bin/sh
# ============================================================
#  tsvpn-lib.sh — shared config reader.
#
#  Sourced by every other tsvpn script. Reads the ONE file that
#  is unique to this router: /etc/tsvpn/node.json. Everything
#  else in /etc/tsvpn is identical on every node of every
#  deployment.
#
#  Generic. Do not put site values in here.
# ============================================================

TSVPN_DIR=${TSVPN_DIR:-/etc/tsvpn}
TSVPN_NODE=${TSVPN_NODE:-$TSVPN_DIR/node.json}
TSVPN_LOG=${TSVPN_LOG:-/var/log/tsvpn-selfheal.log}

# tsvpn_get <jsonfilter-expr> — read one value, empty if absent
tsvpn_get() {
	jsonfilter -i "$TSVPN_NODE" -e "$1" 2>/dev/null
}

# tsvpn_load — populate the shell variables every script uses.
# Returns 1 if there is no node.json, which is always fatal.
tsvpn_load() {
	if [ ! -f "$TSVPN_NODE" ]; then
		echo "tsvpn: no $TSVPN_NODE — this router has no identity." >&2
		echo "tsvpn: create it (see scripts/node.example.json) or re-run tsvpn-install.sh." >&2
		return 1
	fi

	DEPLOYMENT=$(tsvpn_get '@.deployment')
	NODE=$(tsvpn_get '@.node')
	ROLE=$(tsvpn_get '@.role')
	TARGETS=$(tsvpn_get '@.targets[*]' | tr '\n' ' ')
	EXIT_NODE=$(tsvpn_get '@.exit_node')
	COLLIDE=$(tsvpn_get '@.collide')
	DNS_UPSTREAM=$(tsvpn_get '@.dns_upstream[*]' | tr '\n' ' ')

	if [ -z "$ROLE" ]; then
		echo "tsvpn: $TSVPN_NODE has no \"role\" (expected \"host\" or \"remote\")." >&2
		return 1
	fi
	case "$ROLE" in
		host|remote) ;;
		*) echo "tsvpn: role \"$ROLE\" is not \"host\" or \"remote\"." >&2; return 1 ;;
	esac

	# A remote node resolves through the host by default, so that a lookup made
	# at the remote site is answered by the HOST site's resolver and egresses
	# at the host site's IP. Only override dns_upstream if you know why.
	if [ "$ROLE" = "remote" ] && [ -z "$DNS_UPSTREAM" ]; then
		DNS_UPSTREAM="$EXIT_NODE"
	fi

	# Comma-separated /32 list for --advertise-routes
	ROUTES=""
	for t in $TARGETS; do
		ROUTES="${ROUTES:+$ROUTES,}$t/32"
	done

	return 0
}

# tsvpn_check — validate the combination of values for this role.
# Prints problems; returns 1 if any are fatal.
tsvpn_check() {
	rc=0
	if [ "$ROLE" = "remote" ]; then
		[ -n "$EXIT_NODE" ] || { echo "tsvpn: role=remote needs \"exit_node\" (the host's 100.x address)." >&2; rc=1; }
	fi
	for t in $TARGETS; do
		case "$t" in
			*[!0-9.]*|"") echo "tsvpn: target \"$t\" is not a bare IPv4 address (no /32, no port)." >&2; rc=1 ;;
		esac
	done
	return $rc
}
