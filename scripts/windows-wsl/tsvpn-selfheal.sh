#!/bin/sh
# ============================================================
#  tsvpn-selfheal.sh — rebuild this machine's VPN configuration.
#
#  Runs at every boot from tsvpn-selfheal.service, and may be run
#  by hand at any time. Idempotent.
#
#  This is also the PROVISIONER: configuring a WSL host is nothing
#  more than writing node.json and running this.
#
#  HOST ROLE ONLY — see tsvpn-lib.sh for why WSL cannot be a
#  remote.
#
#  WHY IT EXISTS ON WSL: nothing wipes /etc here. What it defends
#  against is a `tailscale up` typed without the flags, a distro
#  restart, or a Windows reboot leaving advertisements cleared —
#  all silent, all leaving the box looking healthy in the console
#  while the tunnel carries nothing.
#
#  Generic. All values come from /etc/tsvpn/node.json.
# ============================================================
. "${TSVPN_DIR:-/etc/tsvpn}/tsvpn-lib.sh"
tsvpn_load || exit 1
tsvpn_check || exit 1

echo "== tsvpn self-heal: ${NODE:-$(hostname)} role=$ROLE $(date) =="
[ -n "$DEPLOYMENT" ] && echo "deployment: $DEPLOYMENT"
echo "targets   : ${TARGETS:-<none>}"
echo "wsl       : networking=$(wsl_net_mode) systemd=$(wsl_has_systemd && echo yes || echo NO) tun=$(wsl_has_tun && echo yes || echo NO)"

# --- wait for tailscaled ---
i=0
while [ $i -lt 60 ]; do
	tailscale status >/dev/null 2>&1 && break
	sleep 5
	i=$((i + 1))
done
echo "tailscaled ready after $((i * 5))s"

# --- IP forwarding, now and across restarts ---
# Required so this box can forward exit-node traffic and subnet-route traffic
# out through the Windows NAT to the host site's network.
cat > /etc/sysctl.d/99-tsvpn.conf <<SYSCTL
# Installed by tsvpn-selfheal.sh — a host forwards exit-node and subnet-route
# traffic on behalf of the rest of the tailnet.
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
SYSCTL
sysctl -q -p /etc/sysctl.d/99-tsvpn.conf 2>/dev/null

# --- DNS for the tailnet (optional but recommended) ---
# A remote elsewhere forwards its clients' lookups here, and this box forwards
# them to whatever /etc/resolv.conf points at — under WSL that is the Windows
# host, which in turn uses the host site's own resolver. So a lookup made at a
# remote site is answered by the same resolver every device at the host site
# uses, and egresses at the same address.
#
# Deliberately NO no-resolv and NO server=. That is what makes it "resolve via
# the network we are on" rather than pinning a public resolver.
if command -v dnsmasq >/dev/null 2>&1; then
	cat > /etc/dnsmasq.d/tsvpn.conf <<DNSMASQ
# Installed by tsvpn-selfheal.sh (role=host) -- do not hand-edit.
# Serve DNS to the tailnet; resolve via whatever this machine resolves with.
interface=tailscale0
bind-dynamic
no-dhcp-interface=tailscale0
domain-needed
bogus-priv
DNSMASQ
	systemctl restart dnsmasq >/dev/null 2>&1 || service dnsmasq restart >/dev/null 2>&1
	echo "dns: serving the tailnet, forwarding to $(sed -n 's/^nameserver //p' /etc/resolv.conf | tr '\n' ' ')"
else
	echo "note: dnsmasq not installed — this host will not answer DNS for a remote."
	echo "      Either 'apt install dnsmasq' and re-run, or point the remote's"
	echo "      dns_upstream at your site's resolver and add that resolver to"
	echo "      'targets' here. See README section 5."
fi

# --- the control-plane settings, which anything can quietly reset ---
if [ -n "$ROUTES" ]; then
	tailscale set --advertise-exit-node --advertise-routes="$ROUTES"
else
	tailscale set --advertise-exit-node --advertise-routes=
fi

echo
echo "-- verify --"
sleep 3
/etc/tsvpn/tsvpn-audit.sh
rc=$?
echo "== done $(date) =="
exit $rc
