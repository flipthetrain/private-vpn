#!/bin/sh
# ============================================================
#  clone-mac.sh — get past a captive portal you already passed
#                 on another device (usually your phone).
#
#  usage:
#    clone-mac.sh AA:BB:CC:DD:EE:FF        clone onto the current uplink
#    clone-mac.sh AA:BB:CC:DD:EE:FF wan    force the wired WAN port
#    clone-mac.sh AA:BB:CC:DD:EE:FF wifi   force the WiFi repeater
#    clone-mac.sh --show                   print current + saved MACs
#    clone-mac.sh --reset                  restore the factory MAC
#    clone-mac.sh --dry-run AA:BB:...      say what it would do, change nothing
#
#  IMPORTANT: the device you copied the MAC from must leave that
#  network first. Two interfaces with the same MAC on one LAN is a
#  conflict and neither will work reliably.
# ============================================================
BAK=/etc/tsvpn-mac.bak
DRY=0
[ "$1" = "--dry-run" ] && { DRY=1; shift; }

die() { echo "error: $*" >&2; exit 1; }

# --- which uplink are we on? ---
detect_mode() {
	sta=$(uci show wireless 2>/dev/null | sed -n "s/^wireless\.\([^.]*\)\.mode='sta'$/\1/p" | head -1)
	if [ -n "$sta" ] && [ "$(uci -q get wireless.$sta.disabled)" != "1" ]; then
		echo wifi
	else
		echo wan
	fi
}

wan_section() {
	i=0
	while [ $i -lt 12 ]; do
		[ "$(uci -q get network.@device[$i].name)" = "$(uci -q get network.wan.device)" ] && { echo "$i"; return; }
		i=$((i + 1))
	done
	die "could not find the device section for $(uci -q get network.wan.device)"
}

sta_section() {
	uci show wireless 2>/dev/null | sed -n "s/^wireless\.\([^.]*\)\.mode='sta'$/\1/p" | head -1
}

case "$1" in
--show)
	echo "uplink mode : $(detect_mode)"
	echo "wan device  : $(uci -q get network.wan.device) = $(uci -q get network.@device[$(wan_section)].macaddr)"
	s=$(sta_section)
	[ -n "$s" ] && echo "wifi sta    : $s = $(uci -q get wireless.$s.macaddr) (factory $(uci -q get wireless.$s.factory_macaddr))"
	[ -f "$BAK" ] && echo "saved       : $(cat $BAK)" || echo "saved       : (none — no clone applied)"
	exit 0
	;;
--reset)
	[ -f "$BAK" ] || die "no saved MAC; nothing to restore"
	mode=$(cut -d' ' -f1 "$BAK"); orig=$(cut -d' ' -f2 "$BAK")
	if [ "$mode" = "wan" ]; then
		uci set network.@device[$(wan_section)].macaddr="$orig"
		uci commit network
	else
		s=$(sta_section); [ -n "$s" ] || die "no sta interface to reset"
		uci set wireless.$s.macaddr="$orig"
		uci commit wireless
	fi
	rm -f "$BAK"
	echo "restored $mode MAC to $orig — reloading network"
	/etc/init.d/network restart
	exit 0
	;;
esac

MAC=$(echo "$1" | tr 'A-Z' 'a-z')
echo "$MAC" | grep -qE '^([0-9a-f]{2}:){5}[0-9a-f]{2}$' || die "not a MAC address: '$1'"
MODE=${2:-$(detect_mode)}

if [ "$MODE" = "wan" ]; then
	idx=$(wan_section)
	cur=$(uci -q get network.@device[$idx].macaddr)
	echo "uplink: wired WAN ($(uci -q get network.wan.device)), current $cur -> $MAC"
	[ $DRY -eq 1 ] && { echo "(dry run — nothing changed)"; exit 0; }
	[ -f "$BAK" ] || echo "wan $cur" > "$BAK"
	uci set network.@device[$idx].macaddr="$MAC"
	uci commit network
else
	s=$(sta_section); [ -n "$s" ] || die "no WiFi repeater interface is configured; join the network first, or pass 'wan'"
	cur=$(uci -q get wireless.$s.macaddr)
	echo "uplink: WiFi repeater ($s), current $cur -> $MAC"
	[ $DRY -eq 1 ] && { echo "(dry run — nothing changed)"; exit 0; }
	[ -f "$BAK" ] || echo "wifi $cur" > "$BAK"
	uci set wireless.$s.macaddr="$MAC"
	uci commit wireless
fi

echo "reloading network — you will drop off the uplink for a few seconds"
/etc/init.d/network restart
sleep 8
echo "uplink address now: $(ip -4 addr show $(uci -q get network.wan.device) 2>/dev/null | sed -n 's/.*inet \([0-9.]*\).*/\1/p')"
echo "run 'clone-mac.sh --reset' when you leave this network"
