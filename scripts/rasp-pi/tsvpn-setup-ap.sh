#!/bin/sh
# ============================================================
#  tsvpn-setup-ap.sh — turn the Pi's WiFi into the access point
#  that client devices (TVs, sticks, consoles) join.
#
#    sudo /etc/tsvpn/tsvpn-setup-ap.sh          create or update it
#    sudo /etc/tsvpn/tsvpn-setup-ap.sh --show   what is configured
#    sudo /etc/tsvpn/tsvpn-setup-ap.sh --remove tear it down
#
#  Run ONCE, by hand, when setting up a remote Pi. It is separate
#  from the self-heal on purpose: it asks for the WiFi passphrase
#  interactively, so that passphrase never goes in node.json and
#  never lands in your repo. Keep it in a password manager --
#  losing it means re-joining every client device by hand.
#
#  It gives the interface a STATIC address rather than using
#  NetworkManager's "shared" mode, because shared mode would run
#  its own DHCP/DNS and its own NAT to the uplink -- which is
#  precisely the leak the kill-switch exists to prevent. DHCP and
#  DNS come from our dnsmasq, NAT from our nftables.
#
#  Only needed for role=remote, and only if the LAN side is
#  wireless. A wired LAN (a USB ethernet adapter, say) just needs
#  a static address on that interface by any means you like.
#
#  Generic. Interface and address come from /etc/tsvpn/node.json.
# ============================================================
set -e
. /etc/tsvpn/tsvpn-lib.sh
tsvpn_load || exit 1

CON=tsvpn-ap
[ "$(id -u)" = "0" ] || { echo "run as root: sudo $0 $*" >&2; exit 1; }
command -v nmcli >/dev/null 2>&1 || {
	echo "nmcli not found. This helper drives NetworkManager, which is the" >&2
	echo "default on Raspberry Pi OS Bookworm. On a systemd-networkd or" >&2
	echo "hostapd setup, configure the AP yourself and give $LAN_IFACE the" >&2
	echo "address $LAN_CIDR; everything else still applies." >&2
	exit 1; }

case "$1" in
--show)
	nmcli -f connection.id,802-11-wireless.ssid,802-11-wireless.mode,802-11-wireless.band,ipv4.method,ipv4.addresses \
		connection show "$CON" 2>/dev/null || echo "no '$CON' connection configured"
	echo
	ip -4 addr show "$LAN_IFACE" 2>/dev/null | sed -n 's/^ *inet /  address: /p' || true
	exit 0
	;;
--remove)
	nmcli connection down "$CON" >/dev/null 2>&1 || true
	nmcli connection delete "$CON" >/dev/null 2>&1 || true
	echo "removed '$CON'"
	exit 0
	;;
esac

[ "$ROLE" = "remote" ] || { echo "this machine is role=$ROLE; an AP is only for a remote Pi" >&2; exit 1; }

echo "Access point for $LAN_IFACE, address $LAN_CIDR"
echo

# Regulatory domain: without it the radio may refuse to start an AP at all.
if [ -z "$TSVPN_COUNTRY" ]; then
	printf "Two-letter country code for the WiFi regulatory domain (e.g. US, GB): "
	read -r TSVPN_COUNTRY
fi
echo "$TSVPN_COUNTRY" | grep -qE '^[A-Za-z]{2}$' || { echo "not a two-letter country code" >&2; exit 1; }
COUNTRY=$(echo "$TSVPN_COUNTRY" | tr 'a-z' 'A-Z')

printf "SSID that client devices will join: "
read -r SSID
[ -n "$SSID" ] || { echo "an SSID is required" >&2; exit 1; }

printf "Passphrase (8-63 characters, not shown): "
stty -echo 2>/dev/null || true
read -r PSK
stty echo 2>/dev/null || true
echo
[ ${#PSK} -ge 8 ] 2>/dev/null || { echo "WPA2 needs at least 8 characters" >&2; exit 1; }

printf "Band — 'bg' is 2.4GHz (slower, best range and device compatibility),\n"
printf "       'a'  is 5GHz (faster, shorter range)  [bg]: "
read -r BAND
[ -n "$BAND" ] || BAND=bg
case "$BAND" in bg|a) ;; *) echo "band must be 'bg' or 'a'" >&2; exit 1 ;; esac

rfkill unblock wifi 2>/dev/null || true
iw reg set "$COUNTRY" 2>/dev/null || true
# Persist the country for the Pi's firmware where the tool exists
command -v raspi-config >/dev/null 2>&1 && raspi-config nonint do_wifi_country "$COUNTRY" >/dev/null 2>&1 || true

nmcli connection delete "$CON" >/dev/null 2>&1 || true
nmcli connection add type wifi ifname "$LAN_IFACE" con-name "$CON" autoconnect yes ssid "$SSID" >/dev/null

nmcli connection modify "$CON" \
	802-11-wireless.mode ap \
	802-11-wireless.band "$BAND" \
	802-11-wireless.powersave 2 \
	wifi-sec.key-mgmt wpa-psk \
	wifi-sec.proto rsn \
	wifi-sec.pairwise ccmp \
	wifi-sec.group ccmp \
	wifi-sec.psk "$PSK" \
	ipv4.method manual \
	ipv4.addresses "$LAN_CIDR" \
	ipv6.method disabled \
	connection.autoconnect-priority 100

unset PSK

nmcli connection up "$CON" >/dev/null || {
	echo "the AP did not come up. Common causes:" >&2
	echo "  - the country code is wrong or unset (the radio refuses to transmit)" >&2
	echo "  - $LAN_IFACE is the interface you are connected over" >&2
	echo "  - the adapter does not support AP mode: iw list | grep -A10 'Supported interface modes'" >&2
	exit 1; }

echo
echo "AP '$SSID' is up on $LAN_IFACE at $LAN_ADDR."
echo "Now run:  sudo /etc/tsvpn/tsvpn-selfheal.sh"
echo "which starts DHCP and DNS on it and puts the kill-switch in place."
echo
echo "Record the SSID and passphrase in a password manager — they are"
echo "deliberately not stored anywhere in this repo."
