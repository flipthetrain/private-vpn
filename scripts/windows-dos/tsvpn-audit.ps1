# ============================================================
#  tsvpn-audit.ps1  -  verify every design requirement on this
#  machine. Read-only: it changes nothing, always safe to run.
#
#  Exit status: 0 = everything passed, 1 = at least one FAIL.
#
#  Generic. All values come from node.json.
# ============================================================
[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot 'tsvpn-lib.ps1')

# NOTE: PowerShell variable names are case-insensitive, so a loop
# variable like $f would silently clobber a counter called $F.
$script:Pass = 0; $script:Fail = 0; $script:Warn = 0
function ok  ($m) { Write-Host "  PASS  $m" -ForegroundColor Green;  $script:Pass++ }
function no  ($m) { Write-Host "  FAIL  $m" -ForegroundColor Red;    $script:Fail++ }
function wn  ($m) { Write-Host "  WARN  $m" -ForegroundColor Yellow; $script:Warn++ }
function inf ($m) { Write-Host "        $m" }

$node = Get-TsvpnNode
if (-not $node) { exit 1 }

Write-Host "=== tsvpn audit: $($node.Node)  -  $(Get-Date) ==="
Write-Host ""
Write-Host "-- identity --"
if ($node.Role -eq 'host') { ok "role = host" }
else { no "role = $($node.Role)  -  Windows supports host only (a remote needs a trustworthy kill-switch; see README)" }
inf "deployment: $(if ($node.Deployment) { $node.Deployment } else { '<unset>' })"
inf "windows   : $((Get-CimInstance Win32_OperatingSystem).Caption) $([Environment]::OSVersion.Version)"
inf "targets   : $(if ($node.Targets) { $node.Targets -join ' ' } else { '<none>' })"

Write-Host ""
Write-Host "-- installation --"
foreach ($f in 'tsvpn-lib.ps1','tsvpn-selfheal.ps1','tsvpn-audit.ps1') {
    if (Test-Path (Join-Path $script:TsvpnDir $f)) { ok "$f installed" } else { no "$f MISSING from $script:TsvpnDir" }
}
$task = Get-ScheduledTask -TaskName 'tsvpn-selfheal' -ErrorAction SilentlyContinue
if ($task) {
    if ($task.State -ne 'Disabled') { ok "scheduled task 'tsvpn-selfheal' registered (runs at boot)" }
    else { no "scheduled task 'tsvpn-selfheal' is DISABLED  -  this will not survive a reboot" }
} else {
    no "scheduled task 'tsvpn-selfheal' not registered  -  this will not survive a reboot"
}
if (Test-Path $script:TsvpnLog) { inf "last self-heal: $((Get-Content $script:TsvpnLog -TotalCount 1))" }
else { wn "no $script:TsvpnLog yet (written at boot)" }

Write-Host ""
Write-Host "-- tailscale --"
$ts = Get-TailscaleExe
if ($ts) { ok "tailscale.exe found ($ts)" } else { no "tailscale.exe not found  -  install from tailscale.com/download/windows" }
$svc = Get-Service -Name Tailscale -ErrorAction SilentlyContinue
if ($svc) {
    if ($svc.Status -eq 'Running') { ok "Tailscale service running" } else { no "Tailscale service is $($svc.Status)" }
} else { wn "Tailscale service not found by name" }

$tsip = $null
if ($ts) { $tsip = (& $ts ip -4 2>$null | Select-Object -First 1) }
if ($tsip) { ok "tailnet address $tsip" } else { no "no tailnet address  -  run 'tailscale up'" }
$prefs = Get-TailscalePrefs

Write-Host ""
Write-Host "-- forwarding --"
# Per-interface forwarding is what takes effect now; the registry value is what
# survives a reboot. Check both, because either alone silently half-works.
$fwd = Get-NetIPInterface -AddressFamily IPv4 -ErrorAction SilentlyContinue |
       Where-Object { $_.Forwarding -eq 'Enabled' }
$tsFwd  = $fwd | Where-Object { $_.InterfaceAlias -like '*Tailscale*' }
if ($tsFwd) { ok "forwarding enabled on the Tailscale interface" }
else { no "forwarding NOT enabled on the Tailscale interface  -  nothing routes through this host" }
if ($fwd | Where-Object { $_.InterfaceAlias -notlike '*Tailscale*' }) {
    ok "forwarding enabled on a physical interface"
} else {
    no "forwarding NOT enabled on any physical interface  -  subnet routes will not work"
}
$reg = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters' -Name IPEnableRouter -ErrorAction SilentlyContinue).IPEnableRouter
if ($reg -eq 1) { ok "IPEnableRouter=1 (survives a reboot)" } else { wn "IPEnableRouter is not 1  -  forwarding may not come back after a reboot" }
$ras = Get-Service -Name RemoteAccess -ErrorAction SilentlyContinue
if ($ras -and $ras.Status -eq 'Running') { ok "RemoteAccess (RRAS) running  -  this is what routes between interfaces" }
elseif ($ras) { wn "RemoteAccess is $($ras.Status)  -  exit-node use is fine, subnet routes may not be" }
else { wn "RemoteAccess service not present on this Windows edition" }

Write-Host ""
Write-Host "-- host role --"
if ($prefs) {
    $adv = @($prefs.AdvertiseRoutes)
    if ($adv -contains '0.0.0.0/0') { ok "advertising exit node 0.0.0.0/0" } else { no "NOT advertising the exit node" }
    foreach ($t in $node.Targets) {
        if ($adv -contains "$t/32") { ok "advertising route $t/32" } else { no "NOT advertising $t/32" }
    }
    if ($adv | Where-Object { $_ -match '^(192\.168\.\d+|10\.\d+\.\d+)\.0/24$' }) {
        wn "a whole /24 is advertised  -  design 3.1 wants a /32 per device"
    } else { ok "no whole-LAN route advertised (design 3.1)" }
    if ($prefs.NoSNAT -eq $true) { no "NoSNAT is set  -  subnet-route replies will not come back" }
    else { ok "SNAT for subnet routes left on (Tailscale handles it)" }
} else {
    no "could not read Tailscale preferences"
}

Write-Host ""
Write-Host "-- dns for the tailnet (design 3.5) --"
wn "Windows ships no DNS forwarder, so this host cannot answer lookups for a REMOTE."
inf "Travelling laptops and phones are unaffected  -  they get DNS through the exit node."
inf "For a remote router: advertise your site's resolver as a target here and set"
inf "the remote's dns_upstream to it. See README section 5."
$dnsSrv = (Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
           Where-Object { $_.ServerAddresses } | Select-Object -First 1).ServerAddresses -join ' '
inf "this machine resolves via: $dnsSrv"

Write-Host ""
Write-Host "-- targets --"
if (-not $node.Targets) {
    inf "no targets configured (exit node only  -  fine if you just want to egress here)"
} else {
    foreach ($t in $node.Targets) {
        if (Test-Connection -ComputerName $t -Count 1 -Quiet -ErrorAction SilentlyContinue) {
            ok "$t reachable from this machine"
        } else {
            no "$t NOT reachable from this machine  -  a remote will not reach it either"
        }
    }
}

Write-Host ""
Write-Host "=== $script:Pass passed, $script:Fail failed, $script:Warn warnings ==="
if ($script:Fail -gt 0) { exit 1 } else { exit 0 }
