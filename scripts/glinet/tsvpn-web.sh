#!/bin/sh
# ============================================================
#  tsvpn-web.sh serve — run the admin page's web server.
#  Started by /etc/init.d/tsvpn-web (procd, respawn), which the
#  self-heal writes; both are rebuilt every boot, like everything.
#
#  Listens on port 8099 of the TAILNET address only: never LAN, never
#  WAN, and the CGI refuses non-tailnet clients as well. The tailnet
#  address only exists once tailscaled is up, so wait for it.
#  Generic.
# ============================================================
D=/etc/tsvpn
PORT=${TSVPN_WEB_PORT:-8099}
WWW=/tmp/tsvpn-www
. $D/tsvpn-lib.sh; tsvpn_load >/dev/null 2>&1

IP=""
while [ -z "$IP" ]; do
	IP=$(tailscale ip -4 2>/dev/null | head -1)
	[ -n "$IP" ] || sleep 5
done

mkdir -p $WWW/cgi-bin
cp $D/tsvpn-web.html $WWW/index.html
ln -sf $D/tsvpn-web-cgi.sh $WWW/cgi-bin/tsvpn

LISTEN="-p $IP:$PORT"
# -t: CGI time limit (speed tests take a minute); -n: few concurrent scripts
exec /usr/sbin/uhttpd -f -h $WWW -x /cgi-bin -t 300 -T 30 -n 4 -N 20 $LISTEN
