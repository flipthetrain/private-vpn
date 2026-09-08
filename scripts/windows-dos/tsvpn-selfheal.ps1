# ============================================================
#  tsvpn-selfheal.ps1  -  rebuild this machine's VPN configuration.
#
#  Runs at every boot from the "tsvpn-selfheal" scheduled task,
#  and may be run by hand at any time. Idempotent.
#
#  This is also the PROVISIONER: configuring a Windows host is
#  nothing more than writing node.json and running this.
#
#  HOST ROLE ONLY - see tsvpn-lib.ps1 for why Windows cannot be
#  a remote.
#
#  WHY IT EXISTS: nothing wipes configuration on Windows. What it
#  defends against is a `tailscale up` typed without the flags, a
#  Tailscale upgrade resetting preferences, or forwarding being
#  turned off - all silent, all leaving the machine looking
#  healthy in the console while the tunnel carries nothing.
#
#  Generic. All values come from node.json.
# ============================================================
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'tsvpn-lib.ps1')

if (-not (Test-TsvpnAdmin)) {
    Write-Host "Run this from an elevated PowerShell (Run as Administrator)." -ForegroundColor Red
    exit 1
}

$node = Get-TsvpnNode
if (-not $node) { exit 1 }
if (-not (Test-TsvpnNode $node)) { exit 1 }

Write-Host "== tsvpn self-heal: $($node.Node) role=$($node.Role) $(Get-Date) =="
if ($node.Deployment) { Write-Host "deployment: $($node.Deployment)" }
Write-Host "targets   : $(if ($node.Targets) { $node.Targets -join ' ' } else { '<none>' })"

$ts = Get-TailscaleExe
if (-not $ts) {
    Write-Host "Tailscale is not installed. Get it from https://tailscale.com/download/windows" -ForegroundColor Red
    exit 1
}

# --- wait for tailscaled: at boot this task can win the race against the service ---
$ready = $false
for ($i = 0; $i -lt 60; $i++) {
    & $ts status *> $null
    if ($LASTEXITCODE -eq 0) { $ready = $true; break }
    Start-Sleep -Seconds 5
}
Write-Host "tailscaled ready after $($i * 5)s$(if (-not $ready) { ' (TIMED OUT)' })"

# --- IP forwarding -----------------------------------------------------------
# A host forwards exit-node traffic and subnet-route traffic on behalf of the
# rest of the tailnet. Windows needs this in two places: per-interface, which
# takes effect immediately, and in the registry, which is what survives a
# reboot. Neither alone is enough.
Write-Host ""
Write-Host "-- forwarding --"

$tsIf = Get-NetIPInterface -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.InterfaceAlias -like '*Tailscale*' }
$lanIf = Get-NetIPInterface -AddressFamily IPv4 -ErrorAction SilentlyContinue |
         Where-Object { $_.InterfaceAlias -notlike '*Tailscale*' -and $_.InterfaceAlias -notlike '*Loopback*' } |
         Where-Object { (Get-NetRoute -InterfaceIndex $_.InterfaceIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue) }

foreach ($iface in @($tsIf) + @($lanIf)) {
    if (-not $iface) { continue }
    try {
        Set-NetIPInterface -InterfaceIndex $iface.InterfaceIndex -AddressFamily IPv4 -Forwarding Enabled -ErrorAction Stop
        Write-Host "  forwarding enabled on $($iface.InterfaceAlias)"
    } catch {
        Write-Host "  could not enable forwarding on $($iface.InterfaceAlias): $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

# Persist across reboots. This one needs a restart to take effect on its own,
# which is why the per-interface calls above run every boot as well.
$tcpip = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters'
try {
    Set-ItemProperty -Path $tcpip -Name 'IPEnableRouter' -Value 1 -Type DWord -ErrorAction Stop
    Write-Host "  IPEnableRouter=1 (persists across reboots)"
} catch {
    Write-Host "  could not set IPEnableRouter: $($_.Exception.Message)" -ForegroundColor Yellow
}

# RRAS is what actually moves packets between interfaces on Windows. On client
# editions the service exists but is usually disabled.
$ras = Get-Service -Name RemoteAccess -ErrorAction SilentlyContinue
if ($ras) {
    try {
        if ($ras.StartType -eq 'Disabled') { Set-Service -Name RemoteAccess -StartupType Automatic }
        if ($ras.Status -ne 'Running')     { Start-Service -Name RemoteAccess -ErrorAction Stop }
        Write-Host "  RemoteAccess service running"
    } catch {
        Write-Host "  RemoteAccess service would not start: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host "  Subnet routes may not work until it does. Exit-node use is unaffected."
    }
} else {
    Write-Host "  RemoteAccess service not present on this edition" -ForegroundColor Yellow
}

# --- DNS ---------------------------------------------------------------------
# Windows client editions ship no DNS forwarder, so this host cannot answer
# lookups for a remote the way a GL.iNet or Pi host does. That only matters if
# a REMOTE router will forward to it; travelling laptops and phones get DNS
# through the exit node and are unaffected. The README explains the alternative:
# advertise your site's resolver as a target and point the remote at it.
Write-Host ""
Write-Host "-- dns --"
Write-Host "  Windows has no built-in DNS forwarder; nothing to configure here."
Write-Host "  Fine for laptops and phones. For a REMOTE router, see README section 5."

# --- the control-plane settings, which anything can quietly reset -------------
Write-Host ""
Write-Host "-- advertisements --"
if ($node.Routes) {
    & $ts set --advertise-exit-node --advertise-routes=$($node.Routes)
} else {
    & $ts set --advertise-exit-node --advertise-routes=
}
if ($LASTEXITCODE -ne 0) { Write-Host "  'tailscale set' failed" -ForegroundColor Red }

Write-Host ""
Write-Host "-- verify --"
Start-Sleep -Seconds 3
& (Join-Path $PSScriptRoot 'tsvpn-audit.ps1')
$rc = $LASTEXITCODE
Write-Host "== done $(Get-Date) =="
exit $rc
