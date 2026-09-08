#!/bin/sh
# ============================================================
#  tsvpn-persist.sh — copy the live /etc/tsvpn/node.json back
#  into the /etc/rc.local bootstrap payload.
#
#  WHY: /etc/rc.local is the one file a GL.iNet firmware update
#  reliably preserves, so it carries a copy of node.json. If you
#  hand-edit /etc/tsvpn/node.json on the router, run this — or the
#  next flash silently restores the OLD values.
#
#  The alternative is to edit the JSON in your repo and re-run
#  tsvpn-install.sh, which does this for you.
#
#  Generic.
# ============================================================
NODE=/etc/tsvpn/node.json
RC=/etc/rc.local

[ -f "$NODE" ] || { echo "no $NODE" >&2; exit 1; }
grep -q "__TSVPN_NODE__" "$RC" || { echo "no bootstrap payload in $RC — run tsvpn-install.sh" >&2; exit 1; }

# Validate before writing: an unparseable node.json would brick the next boot.
jsonfilter -i "$NODE" -e '@.role' >/dev/null 2>&1 || { echo "$NODE is not valid JSON" >&2; exit 1; }

awk -v f="$NODE" '
	$0 == "cat > /etc/tsvpn/node.json <<'"'"'__TSVPN_NODE__'"'"'" {
		print
		while ((getline line < f) > 0) print line
		close(f)
		skip = 1
		next
	}
	skip && $0 == "__TSVPN_NODE__" { print; skip = 0; next }
	skip { next }
	{ print }
' "$RC" > /tmp/rc.persist.$$

if ! sh -n /tmp/rc.persist.$$ 2>/dev/null; then
	echo "generated rc.local failed the syntax check — not installing" >&2
	rm -f /tmp/rc.persist.$$
	exit 1
fi

cp "$RC" "$RC.bak-persist"
cat /tmp/rc.persist.$$ > "$RC"
chmod +x "$RC"
rm -f /tmp/rc.persist.$$
echo "node.json persisted into $RC (previous kept as $RC.bak-persist)"
