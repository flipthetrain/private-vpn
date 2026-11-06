#!/bin/sh
# ============================================================
#  tsvpn-selfheal.sh — rebuild this router's VPN configuration.
#
#  Runs at every boot from /etc/rc.local, and may be run by hand
#  at any time. Idempotent and safe to re-run on either role.
#
#  WHY THIS EXISTS: every GL.iNet firmware update silently breaks
#  the setup. It destroys /root/*.sh and /etc/hotplug.d/iface/*,
#  resets firewall.tailscale0.masq, restores the *->wan
#  forwardings the kill-switch removed, and resets the Tailscale
#  route advertisements and exit-node selection. The box comes
#  back looking healthy in the Tailscale console while the tunnel
#  carries nothing.
#
#  This is also the PROVISIONER: it applies scripts/glinet/README.md section 5
#  and 8 in full. Configuring a new router is nothing more than
#  writing node.json and running this.
#
#  Generic. All values come from /etc/tsvpn/node.json.
#  See scripts/glinet/README.md sections 3 and 7.
# ============================================================
. /etc/tsvpn/tsvpn-lib.sh
tsvpn_load || exit 1
tsvpn_check || exit 1

echo "== tsvpn self-heal: ${NODE:-$(uci -q get system.@system[0].hostname)} role=$ROLE $(date) =="
[ -n "$DEPLOYMENT" ] && echo "deployment: $DEPLOYMENT"
echo "targets   : ${TARGETS:-<none>}"
[ "$ROLE" = "remote" ] && echo "exit node : $EXIT_NODE"
[ "$ROLE" = "remote" ] && echo "dns       : $DNS_UPSTREAM"

# --- clock: must be right BEFORE tailscaled needs TLS ---
# There is no RTC. A cold boot restores the newest mtime under /etc, which
# can be weeks old. Tailscale then rejects the control plane's certificate
# as "not yet valid" and the node stays logged out. GL.iNet's chrony config
# uses only NTS sources by HOSTNAME, so it needs working DNS to fix the
# clock -- and it may only step during its first 3 updates. Add two plain
# NTP sources by IP (no DNS, no certificates) and allow a step at any time.
# NTP is this box's own traffic, not a client's, so section 3.5 is untouched.
if [ -f /etc/config/chrony ]; then
	uci -q set chrony.@makestep[0].limit='-1'
	for pair in tsvpn_google:216.239.35.0 tsvpn_cf:162.159.200.1; do
		sec=${pair%%:*}
		uci -q set chrony.$sec=server
		uci -q set chrony.$sec.hostname="${pair#*:}"
		uci -q set chrony.$sec.iburst='yes'
		uci -q set chrony.$sec.nts='no'
	done
	# Restart only on a real change: a restart throws away chrony's sync and
	# it then takes minutes (NTS re-keying) to call the clock synced again.
	if [ -n "$(uci -q changes chrony)" ]; then
		uci -q commit chrony
		/etc/init.d/chronyd restart >/dev/null 2>&1
	fi
	# At boot GL's /etc/hotplug.d/kmwan/time_sync also restarts chronyd every
	# ~25 s until it syncs, which can push a sync past this wait. That is
	# fine: it keeps retrying on its own, and tailscaled retries TLS by
	# itself once the clock is right. This wait only keeps the log honest.
	chronyc waitsync 12 1 >/dev/null 2>&1 \
		&& echo "clock     : synced $(date)" \
		|| echo "clock     : not synced yet (GL time_sync keeps retrying) -- $(date)"
	# tailscaled backs off after a TLS failure; kick it so it retries now.
	tailscale status 2>&1 | grep -q 'not yet valid' && /etc/init.d/tailscale restart
else
	# Older GL firmware (4.8.x) has no chrony: busybox ntpd via sysntpd, fed
	# from system.ntp.server -- pool HOSTNAMES, so the same DNS dependency.
	# Add the same two IP sources. busybox ntpd steps a large offset on its
	# own, so there is no makestep equivalent to set. (A GFiber DHCP lease
	# may also hand it Google's IPs, but that is site-specific; don't rely on it.)
	for ip in 216.239.35.0 162.159.200.1; do
		uci -q get system.ntp.server | tr ' ' '\n' | grep -qx "$ip" || uci -q add_list system.ntp.server="$ip"
	done
	uci -q set system.ntp.enabled='1'
	if [ -n "$(uci -q changes system)" ]; then
		uci -q commit system
		/etc/init.d/sysntpd restart >/dev/null 2>&1
	fi
	echo "clock     : no chrony; sysntpd given plain-IP NTP sources -- $(date)"
	tailscale status 2>&1 | grep -q 'not yet valid' && /etc/init.d/tailscale restart
fi

# --- cap tailscaled's memory (512 MB routers, no swap) ---
# tailscaled is Go and keeps freed memory after a burst of traffic: on
# 2026-11-06 a host grew 78 -> 212 MB in minutes of streaming-level load,
# ran the box out of memory, and every remote lost the internet. GOMEMLIMIT
# is a soft cap that makes Go collect and return memory before that. GL's
# init script is replaced by firmware updates, so re-apply it every boot.
TSMEM=${TSVPN_GOMEMLIMIT:-128MiB}
if [ -f /etc/init.d/tailscale ] && ! grep -q "GOMEMLIMIT=$TSMEM" /etc/init.d/tailscale; then
	if grep -q 'procd_set_param env ' /etc/init.d/tailscale; then
		sed -i "s/ GOMEMLIMIT=[^ ]*//; s/procd_set_param env /procd_set_param env GOMEMLIMIT=$TSMEM /" /etc/init.d/tailscale
	else
		sed -i "s|procd_set_param command /usr/sbin/tailscaled|&\n  procd_set_param env GOMEMLIMIT=$TSMEM|" /etc/init.d/tailscale
	fi
	echo "memory    : tailscaled capped with GOMEMLIMIT=$TSMEM; restarting it"
	/etc/init.d/tailscale restart
	sleep 5
fi

# --- wait for tailscaled (the first boot after a flash is slow) ---
i=0
while [ $i -lt 60 ]; do
	tailscale status >/dev/null 2>&1 && break
	sleep 5
	i=$((i + 1))
done
echo "tailscaled ready after $((i * 5))s"

# --- GL.iNet Tailscale plugin toggles ---
# Only present on GL.iNet firmware. On plain OpenWrt there is no
# /etc/config/tailscale and tailscaled is managed directly, so skip it.
if [ -f /etc/config/tailscale ]; then
	uci -q set tailscale.settings.enabled='1'
	uci -q set tailscale.settings.lan_enabled='1'
	[ "$ROLE" = "host" ] && uci -q set tailscale.settings.wan_enabled='1'
	uci -q commit tailscale
else
	echo "note: no /etc/config/tailscale — not GL.iNet firmware, skipping plugin toggles"
fi

# --- firewall: common to both roles ---
uci -q set firewall.tailscale0=zone
uci -q set firewall.tailscale0.name='tailscale0'
uci -q set firewall.tailscale0.device='tailscale0'
uci -q set firewall.tailscale0.input='ACCEPT'      # admin over the tunnel, and nowhere else
uci -q set firewall.tailscale0.mtu_fix='1'         # section 3.4: or video stalls while UIs load
uci -q set firewall.lan_tailscale=forwarding
uci -q set firewall.lan_tailscale.src='lan'
uci -q set firewall.lan_tailscale.dest='tailscale0'

if [ "$ROLE" = "host" ]; then
	# ---------- exit-node SERVER ----------
	# No masq here: the wan zone already SNATs both exit-node egress and the
	# subnet route. Setting it twice breaks return traffic.
	uci -q delete firewall.tailscale0.masq
	uci -q set firewall.tailscale_lan=forwarding
	uci -q set firewall.tailscale_lan.src='tailscale0'
	uci -q set firewall.tailscale_lan.dest='lan'
	uci -q set firewall.wan_tailscale=forwarding
	uci -q set firewall.wan_tailscale.src='wan'
	uci -q set firewall.wan_tailscale.dest='tailscale0'
	# tailscale0 -> wan is what actually carries exit-node traffic to the
	# internet. Without it the exit node is selected and nothing flows.
	uci -q set firewall.tailscale_wan=forwarding
	uci -q set firewall.tailscale_wan.src='tailscale0'
	uci -q set firewall.tailscale_wan.dest='wan'

	# DNS (section 3.5): this box resolves via the network it is plugged into
	# -- its WAN DHCP resolver, the same one every other device at the host site uses --
	# and serves those answers to the tailnet. A remote site then gets exactly
	# what a device sitting at the host site gets: same resolver, same egress, nothing
	# for a service to correlate.
	uci -q delete dhcp.@dnsmasq[0].server        # no hardcoded PUBLIC upstream
	uci -q delete dhcp.@dnsmasq[0].noresolv      # use the network we are on
	# Optional dns_upstream on a host = the resolver(s) ON THIS SITE to use
	# INSTEAD of the WAN DHCP one (e.g. the ISP router). Same site, same public
	# IP, so section 3.5 still holds. Set it when the DHCP resolver is a single
	# box (a Pi-hole) that can fail: with no working resolver the clock never
	# syncs, TLS to the control plane fails ("certificate not yet valid") and
	# the node drops off the tailnet (2026-11-02). It REPLACES the DHCP one
	# (noresolv): a resolver that answers REFUSED is not skipped by dnsmasq,
	# so keeping a broken Pi-hole in the list still breaks lookups (2026-11-06).
	for s in $DNS_UPSTREAM; do
		uci -q add_list dhcp.@dnsmasq[0].server="$s"
		uci -q set dhcp.@dnsmasq[0].noresolv='1'
	done
	# localservice=0 is REQUIRED: tailscale0 is a /32, which dnsmasq's
	# `local-service` reads as "no local subnet", so it silently refuses
	# queries from remote tailnet peers. The wan zone is input DROP, so this
	# does not expose a resolver off-box.
	uci -q set dhcp.@dnsmasq[0].localservice='0'
else
	# ---------- the REMOTE (exit-node client) ----------
	# masq is REQUIRED (section 3.3). Both GL.iNet routers ship the same
	# 192.168.8.0/24 LAN, so un-NATed client traffic arrives at the host
	# sourced from a range the host routes to its OWN br-lan, and is dropped.
	# Symptom if missing: this router works over the tunnel, nothing behind
	# it does.
	uci -q set firewall.tailscale0.masq='1'

	# KILL-SWITCH (section 8): clients may reach the internet ONLY via the
	# tunnel. GL.iNet restores lan->wan (and guest/iot->wan) on every firmware
	# update, which silently reopens a direct path out of the site's own
	# uplink. Strip every *->wan forwarding. The index does NOT advance on
	# delete, because uci renumbers.
	i=0
	while [ $i -lt 20 ]; do
		d=$(uci -q get firewall.@forwarding[$i].dest)
		[ -z "$d" ] && break
		if [ "$d" = "wan" ]; then
			echo "  kill-switch: dropping $(uci -q get firewall.@forwarding[$i].src) -> wan"
			uci -q delete firewall.@forwarding[$i]
		else
			i=$((i + 1))
		fi
	done

	# DNS (section 3.5): resolve through the HOST, so the resolver egress IP
	# and the client egress IP are the same address. noresolv stops dnsmasq
	# falling back to THIS site's resolver, which is the leak that tells a
	# service you are on a VPN.
	#
	# `server` is a uci LIST. `uci set` writes a scalar, which the dnsmasq init
	# script SILENTLY IGNORES, leaving no-resolv with no upstream at all.
	# Symptom: direct-IP traffic works perfectly and every name lookup times
	# out, which presents as "no internet". Must be delete + add_list.
	uci -q set dhcp.@dnsmasq[0].noresolv='1'
	uci -q delete dhcp.@dnsmasq[0].server
	for s in $DNS_UPSTREAM; do
		uci -q add_list dhcp.@dnsmasq[0].server="$s"
	done

	# No IPv6 on the LAN (section 3.6): if the tunnel does not carry v6,
	# clients leak over v6 while v4 looks perfect.
	uci -q set dhcp.lan.ra='disabled'
	uci -q set dhcp.lan.dhcpv6='disabled'
fi

# --- only tailnet MACHINES reach tailnet addresses (both roles) ---
# Devices on this router's LAN are not tailnet members, but their traffic
# would otherwise reach any 100.x through this router (masqueraded as it),
# including the host's SSH, GL admin and tsvpn admin page. They never need a
# 100.x: DNS is answered by this router, targets and the internet are not
# 100.x. So refuse lan -> 100.64.0.0/10.
uci -q set firewall.tsvpn_lan_no_tailnet=rule
uci -q set firewall.tsvpn_lan_no_tailnet.name='tsvpn: LAN devices may not reach tailnet addresses'
uci -q set firewall.tsvpn_lan_no_tailnet.src='lan'
uci -q set firewall.tsvpn_lan_no_tailnet.dest='tailscale0'
uci -q set firewall.tsvpn_lan_no_tailnet.dest_ip='100.64.0.0/10'
uci -q set firewall.tsvpn_lan_no_tailnet.proto='all'
uci -q set firewall.tsvpn_lan_no_tailnet.target='REJECT'

uci -q commit dhcp
uci -q commit firewall
/etc/init.d/dnsmasq restart >/dev/null 2>&1
/etc/init.d/firewall restart >/dev/null 2>&1

# --- subnet-collision fix: hotplug hook + cron backstop (remote only) ---
# /etc/hotplug.d/iface/ is REPLACED wholesale by a firmware update, so the
# hook has to be rewritten here rather than merely installed once.
if [ "$ROLE" = "remote" ] && [ -n "$COLLIDE" ]; then
	mkdir -p /etc/hotplug.d/iface
	cat > /etc/hotplug.d/iface/99-tsvpn-route <<'HOTPLUG'
#!/bin/sh
[ "$ACTION" = "ifup" ] || exit 0
( sleep 8; /etc/tsvpn/tsvpn-fix-route.sh ) &
HOTPLUG
	chmod +x /etc/hotplug.d/iface/99-tsvpn-route

	grep -q tsvpn-fix-route /etc/crontabs/root 2>/dev/null || \
		echo '*/5 * * * * /etc/tsvpn/tsvpn-fix-route.sh' >> /etc/crontabs/root
	# drop any stale entry from the older /root layout
	if grep -q '/root/fix-target-route.sh' /etc/crontabs/root 2>/dev/null; then
		grep -v '/root/fix-target-route.sh' /etc/crontabs/root > /tmp/ct.$$ && \
			cat /tmp/ct.$$ > /etc/crontabs/root && rm -f /tmp/ct.$$
	fi
	/etc/init.d/cron enable >/dev/null 2>&1
	/etc/init.d/cron restart >/dev/null 2>&1
fi

# --- watchdog (both roles): restart a hung tailscaled, reboot as a last resort ---
# A host whose tailscaled hangs takes every remote's internet with it, and
# procd does not notice a process that is alive but unresponsive.
grep -q tsvpn-watchdog /etc/crontabs/root 2>/dev/null || \
	echo '*/3 * * * * /etc/tsvpn/tsvpn-watchdog.sh' >> /etc/crontabs/root
/etc/init.d/cron enable >/dev/null 2>&1
/etc/init.d/cron restart >/dev/null 2>&1

# --- the bit firmware updates always clobber: control-plane prefs ---
# GL.iNet's Tailscale plugin re-derives --advertise-routes from its own UI
# toggles on first boot, replacing a /32 with the whole /24 and dropping
# --advertise-exit-node entirely.
if [ "$ROLE" = "host" ]; then
	if [ -n "$ROUTES" ]; then
		tailscale set --advertise-exit-node --advertise-routes="$ROUTES"
	else
		tailscale set --advertise-exit-node --advertise-routes=
	fi
else
	# A remote advertises NOTHING. The GL.iNet plugin advertises the box's own
	# LAN by default, and `tailscale set --exit-node=...` does not clear it, so
	# without this the remote keeps offering its LAN to the tailnet. It sits
	# unapproved and inert -- until somebody clicks approve in the console, and
	# then every device at the remote site is reachable from the tailnet. This
	# VPN is one-way by design: remote -> host, never the reverse.
	tailscale set --advertise-routes= --advertise-exit-node=false \
		--exit-node="$EXIT_NODE" --exit-node-allow-lan-access --accept-routes
	sleep 2
	[ -x /etc/tsvpn/tsvpn-fix-route.sh ] && /etc/tsvpn/tsvpn-fix-route.sh
fi

# --- admin web page (http://<tailnet-ip>:8099/, tailnet + admin password) ---
if [ "$ROLE" = host ] && [ ! -s /etc/dropbear/tsvpn_host_ed25519 ]; then
	# The host's dashboard key. /etc/dropbear survives firmware updates.
	dropbearkey -t ed25519 -f /etc/dropbear/tsvpn_host_ed25519 >/dev/null 2>&1
fi
[ "$ROLE" = host ] && [ -s /etc/dropbear/tsvpn_host_ed25519 ] && \
	dropbearkey -y -f /etc/dropbear/tsvpn_host_ed25519 2>/dev/null | grep '^ssh-' > /etc/dropbear/tsvpn_host_ed25519.pub
cat > /etc/init.d/tsvpn-web <<'INIT'
#!/bin/sh /etc/rc.common
# GENERATED by tsvpn-selfheal.sh every boot. Admin page on the tailnet address.
START=99
USE_PROCD=1
start_service() {
	procd_open_instance
	procd_set_param command /etc/tsvpn/tsvpn-web.sh
	procd_set_param respawn 3600 10 0
	procd_close_instance
}
INIT
chmod +x /etc/init.d/tsvpn-web
/etc/init.d/tsvpn-web enable
/etc/init.d/tsvpn-web restart
if [ "$ROLE" = remote ]; then
	# Let the HOST's dashboard act on this router: fetch its key over the
	# tunnel and pin it to tsvpn-api.sh (a fixed menu, never a shell). Re-done
	# every boot, so a rebuilt host is picked up by itself.
	sleep 3
	HK=$(wget -qO- --timeout=8 "http://$EXIT_NODE:8099/cgi-bin/tsvpn?a=host-pub" 2>/dev/null | head -1)
	if echo "$HK" | grep -qE '^ssh-ed25519 [A-Za-z0-9+/=]+( |$)'; then
		AK=/etc/dropbear/authorized_keys; touch $AK
		grep -v ' tsvpn-host$' $AK > $AK.tmp
		echo "command=\"/etc/tsvpn/tsvpn-api.sh\",no-port-forwarding,no-agent-forwarding,no-X11-forwarding,no-pty $(echo "$HK" | cut -d' ' -f1-2) tsvpn-host" >> $AK.tmp
		cat $AK.tmp > $AK; rm -f $AK.tmp; chmod 600 $AK
		echo "dashboard : host key installed (restricted to tsvpn-api.sh)"
	else
		echo "dashboard : could not fetch the host's key yet (host page down?) -- kept the old one"
	fi
fi

echo
echo "-- verify --"
sleep 3
/etc/tsvpn/tsvpn-audit.sh
rc=$?
echo "== done $(date) =="
exit $rc
