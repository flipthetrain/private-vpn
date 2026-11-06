#!/bin/sh
# ============================================================
#  tsvpn-watchdog.sh — keep tailscaled alive with nobody on site.
#  Runs from cron every 3 minutes (installed by the self-heal).
#
#  WHY: on 2026-11-06 a host's tailscaled stopped answering under
#  heavy load (likely memory). The box itself stayed up, procd did
#  not restart it, and every remote behind it lost all internet
#  until someone pulled the power. This turns that into a blip.
#
#  Escalation, only while tailscaled is UNRESPONSIVE (the status
#  command fails or hangs) or stuck before Running:
#    1st bad check  -> note it, do nothing (could be a slow moment)
#    2nd in a row   -> restart tailscale
#    4th in a row   -> reboot, at most once per 6 hours
#  A node that is merely logged out (NeedsLogin) is NOT "stuck":
#  restarting cannot fix that, so it is logged and left alone.
#
#  Also catches DRIFT while tailscaled is healthy: a firmware update (seen
#  2026-11-06, GL 4.11) or GL's Tailscale plugin can reset the prefs after
#  the boot self-heal has run -- or the host was down when it ran -- leaving
#  a remote with no exit node (its clients blackholed) or advertising its
#  LAN. Then re-run the self-heal, at most once per 15 minutes.
#
#  Leaves evidence: each action appends a memory/process snapshot to
#  /etc/tsvpn/watchdog.log (flash, so it survives the reboot; small,
#  trimmed, written only when something is wrong).
#  Generic.
# ============================================================
STATE=/tmp/tsvpn-wd.count
LOG=/etc/tsvpn/watchdog.log
LAST=/etc/tsvpn/watchdog.lastreboot

# Leave the first minutes after boot to the boot self-heal.
[ "$(cut -d. -f1 /proc/uptime)" -lt 300 ] && exit 0

S=$(timeout 20 tailscale status --json 2>/dev/null | jsonfilter -e '@.BackendState' 2>/dev/null)
drift() {
	. /etc/tsvpn/tsvpn-lib.sh; tsvpn_load >/dev/null 2>&1 || return 1
	P=$(tailscale debug prefs 2>/dev/null)
	if [ "$ROLE" = remote ]; then
		echo "$P" | grep -q '"ExitNodeID": "[^"]' || { echo "no exit node selected"; return 0; }
		echo "$P" | sed -n '/"AdvertiseRoutes"/,/]/p' | grep -q '"[0-9]' && { echo "advertising routes"; return 0; }
	else
		echo "$P" | grep -q '"0.0.0.0/0"' || { echo "exit node not advertised"; return 0; }
		for t in $TARGETS; do echo "$P" | grep -q "\"$t/32\"" || { echo "route $t/32 not advertised"; return 0; }; done
	fi
	return 1
}

case "$S" in
	Running)
		rm -f "$STATE"
		WHY=$(drift) || exit 0
		STAMP=/tmp/tsvpn-wd.heal; nowt=$(date +%s)
		[ $((nowt - $(cat $STAMP 2>/dev/null || echo 0))) -ge 900 ] || exit 0
		echo "$nowt" > $STAMP
		logger -t tsvpn-wd "config drift ($WHY): re-running the self-heal"
		echo "== $(date) config drift ($WHY): re-ran the self-heal" >> "$LOG"
		/etc/tsvpn/tsvpn-selfheal.sh > /var/log/tsvpn-selfheal.log 2>&1
		exit 0 ;;
	NeedsLogin|NeedsMachineAuth)
		logger -t tsvpn-wd "tailscale is $S: needs a person (re-auth), not a restart"
		rm -f "$STATE"; exit 0 ;;
esac

n=$(( $(cat "$STATE" 2>/dev/null || echo 0) + 1 )); echo $n > "$STATE"

snap() {
	{
		echo "== $(date) $1 (state=${S:-no answer}, bad checks=$n, up $(cut -d' ' -f1 /proc/uptime)s)"
		free -k | sed -n 2p
		ps w | awk 'NR==1 || /tailscaled|dnsmasq|iperf3|curl|wget/' | grep -v awk
	} >> "$LOG"
	tail -n 200 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
	logger -t tsvpn-wd "$1 (tailscale state=${S:-no answer}, bad checks=$n)"
}

if [ $n -eq 2 ] || [ $n -eq 3 ]; then
	snap "restarting tailscale"
	/etc/init.d/tailscale restart
elif [ $n -ge 4 ]; then
	nowt=$(date +%s); last=$(cat "$LAST" 2>/dev/null || echo 0)
	if [ $((nowt - last)) -gt 21600 ] || [ "$last" -gt "$nowt" ]; then
		snap "REBOOTING: tailscale still dead after restarts"
		echo "$nowt" > "$LAST"
		sync; reboot
	else
		snap "would reboot, but already did within 6 h; restarting tailscale again"
		/etc/init.d/tailscale restart
	fi
fi
