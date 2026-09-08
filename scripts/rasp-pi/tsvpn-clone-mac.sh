#!/bin/sh
# ============================================================
#  tsvpn-clone-mac.sh — get past a captive portal you already
#                       passed on another device (usually your
#                       phone).
#
#  usage:
#    tsvpn-clone-mac.sh AA:BB:CC:DD:EE:FF        clone onto the uplink
#    tsvpn-clone-mac.sh AA:BB:CC:DD:EE:FF eth0   name the interface
#    tsvpn-clone-mac.sh --show                   current + saved MACs
#    tsvpn-clone-mac.sh --reset                  restore the real MAC
#    tsvpn-clone-mac.sh --dry-run AA:BB:...      say what it would do
#
#  IMPORTANT: the device you copied the MAC from must LEAVE that
#  network first. Two interfaces with the same MAC on one LAN is a
#  conflict and neither will work reliably. This is the step
#  people skip, and the failure looks like "the portal is broken".
#
#  Modern phones use a DIFFERENT random MAC per network, so read
#  the one it is using on THAT SSID, not the address on the box:
#    iOS     Settings > Wi-Fi > (i) > Wi-Fi Address
#    Android Settings > Network > Wi-Fi > network > Advanced
#
#  Uses NetworkManager when it manages the interface, because NM
#  would otherwise put its own address back; falls back to
#  `ip link` on a plain networkd/dhcpcd system.
#
#  Generic.
# ============================================================
BAK=/etc/tsvpn/mac.bak
DRY=0
[ "$1" = "--dry-run" ] && { DRY=1; shift; }

die() { echo "error: $*" >&2; exit 1; }

default_iface() {
	ip -4 route show default 2>/dev/null | grep -v tailscale | awk '{print $5; exit}'
}

# the connection profile name NetworkManager has up on an interface, if any
nm_con() {
	command -v nmcli >/dev/null 2>&1 || return 1
	nmcli -t -f GENERAL.CONNECTION device show "$1" 2>/dev/null \
		| sed -n 's/^GENERAL.CONNECTION://p' | grep -v '^--$' | grep .
}

# permanent (burned-in) address, which is what --reset should restore
perm_mac() {
	ethtool -P "$1" 2>/dev/null | sed -n 's/.*: //p' | grep -v '00:00:00:00:00:00' \
		|| cat "/sys/class/net/$1/address" 2>/dev/null
}

cur_mac() { cat "/sys/class/net/$1/address" 2>/dev/null; }

is_wifi() { [ -d "/sys/class/net/$1/wireless" ]; }

case "$1" in
--show)
	IF=${2:-$(default_iface)}
	[ -n "$IF" ] || die "no uplink interface found; name one explicitly"
	echo "interface   : $IF"
	echo "current MAC : $(cur_mac "$IF")"
	echo "permanent   : $(perm_mac "$IF")"
	c=$(nm_con "$IF") && echo "NM profile  : $c" || echo "NM profile  : (not NetworkManager-managed)"
	[ -f "$BAK" ] && echo "saved       : $(cat "$BAK")" || echo "saved       : (none — no clone applied)"
	exit 0
	;;
--reset)
	if [ -f "$BAK" ]; then
		IF=$(cut -d' ' -f1 "$BAK"); ORIG=$(cut -d' ' -f2 "$BAK")
	else
		IF=${2:-$(default_iface)}; ORIG=$(perm_mac "$IF")
		[ -n "$ORIG" ] || die "no saved MAC and no permanent address to fall back to"
		echo "no saved MAC; restoring the permanent address"
	fi
	[ -n "$IF" ] || die "no interface to reset"
	if c=$(nm_con "$IF"); then
		if is_wifi "$IF"; then nmcli connection modify "$c" 802-11-wireless.cloned-mac-address "$ORIG"
		else nmcli connection modify "$c" 802-3-ethernet.cloned-mac-address "$ORIG"; fi
		nmcli connection up "$c" >/dev/null
	else
		ip link set dev "$IF" down
		ip link set dev "$IF" address "$ORIG"
		ip link set dev "$IF" up
	fi
	rm -f "$BAK"
	echo "restored $IF to $ORIG"
	exit 0
	;;
esac

MAC=$(echo "$1" | tr 'A-Z' 'a-z')
echo "$MAC" | grep -qE '^([0-9a-f]{2}:){5}[0-9a-f]{2}$' || die "not a MAC address: '$1'"
IF=${2:-$(default_iface)}
[ -n "$IF" ] || die "no uplink interface found; pass one, e.g. $0 $MAC eth0"
[ -d "/sys/class/net/$IF" ] || die "no such interface: $IF"

CUR=$(cur_mac "$IF")
echo "uplink: $IF, current $CUR -> $MAC"
[ $DRY -eq 1 ] && { echo "(dry run — nothing changed)"; exit 0; }

mkdir -p "$(dirname "$BAK")"
[ -f "$BAK" ] || echo "$IF $(perm_mac "$IF")" > "$BAK"

if c=$(nm_con "$IF"); then
	echo "using NetworkManager profile '$c'"
	if is_wifi "$IF"; then nmcli connection modify "$c" 802-11-wireless.cloned-mac-address "$MAC"
	else nmcli connection modify "$c" 802-3-ethernet.cloned-mac-address "$MAC"; fi
	nmcli connection up "$c" >/dev/null || die "NetworkManager could not bring '$c' back up"
else
	ip link set dev "$IF" down
	ip link set dev "$IF" address "$MAC" || die "the driver refused that address"
	ip link set dev "$IF" up
fi

sleep 8
echo "uplink address now: $(ip -4 addr show "$IF" 2>/dev/null | sed -n 's/.*inet \([0-9.]*\).*/\1/p')"
echo "run '$0 --reset' when you leave this network"
