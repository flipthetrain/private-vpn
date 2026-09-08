# ============================================================
#  tsvpn-lib.ps1  -  shared config reader (native Windows)
#
#  Dot-sourced by every other tsvpn script. Reads the ONE file
#  that is unique to this machine: node.json.
#
#  This platform supports role=host ONLY. Windows cannot be a
#  remote  -  see Test-TsvpnNode for why.
#
#  Generic. Do not put site values in here.
# ============================================================

$script:TsvpnDir  = if ($env:TSVPN_DIR) { $env:TSVPN_DIR } else { Join-Path $env:ProgramData 'tsvpn' }
$script:TsvpnNode = Join-Path $script:TsvpnDir 'node.json'
$script:TsvpnLog  = Join-Path $script:TsvpnDir 'selfheal.log'

function Test-TsvpnAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-TailscaleExe {
    # The MSI installs here; PATH is not reliable from a service or scheduled task.
    $candidates = @(
        (Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Tailscale\tailscale.exe')
    )
    foreach ($c in $candidates) { if ($c -and (Test-Path $c)) { return $c } }
    $cmd = Get-Command tailscale.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Get-TsvpnNode {
    param([string]$Path = $script:TsvpnNode)

    if (-not (Test-Path $Path)) {
        Write-Error "tsvpn: no $Path - this machine has no identity. Create it (see scripts/windows-dos/README.md) or re-run tsvpn-install.ps1."
        return $null
    }
    try {
        $n = Get-Content -Raw -Path $Path | ConvertFrom-Json
    } catch {
        Write-Error "tsvpn: $Path is not valid JSON: $($_.Exception.Message)"
        return $null
    }

    # Normalise: targets may be absent, a string, or an array.
    $targets = @()
    if ($n.PSObject.Properties.Name -contains 'targets' -and $n.targets) {
        $targets = @($n.targets)
    }

    [pscustomobject]@{
        Deployment = [string]$n.deployment
        Node       = [string]$n.node
        Role       = [string]$n.role
        Targets    = $targets
        ExitNode   = [string]$n.exit_node
        Routes     = ($targets | ForEach-Object { "$_/32" }) -join ','
        Path       = $Path
    }
}

function Test-TsvpnNode {
    param([Parameter(Mandatory)]$Node)
    $ok = $true

    if ($Node.Role -ne 'host') {
        Write-Host ""
        Write-Host "tsvpn: role=`"$($Node.Role)`" is not supported on Windows." -ForegroundColor Red
        Write-Host ""
        Write-Host "  Windows can only be a HOST here, and that is a deliberate limit."
        Write-Host ""
        Write-Host "  Acting as a REMOTE means being a router for other devices: NAT, DHCP,"
        Write-Host "  a DNS forwarder, and a kill-switch that drops forwarded traffic if the"
        Write-Host "  tunnel goes down. Windows can be coaxed into the first three with"
        Write-Host "  Internet Connection Sharing, but Windows Firewall filters traffic to"
        Write-Host "  and from THIS machine - it does not reliably filter traffic being"
        Write-Host "  routed THROUGH it. So the kill-switch cannot be made trustworthy, and"
        Write-Host "  a kill-switch you cannot trust is worse than none: it fails open,"
        Write-Host "  quietly, and the devices behind it leak while appearing to work."
        Write-Host ""
        Write-Host "  For a remote, use scripts/glinet/ or scripts/pi5/ on real hardware."
        Write-Host ""
        $ok = $false
    }

    foreach ($t in $Node.Targets) {
        if ($t -match '[/:]' -or [string]::IsNullOrWhiteSpace($t)) {
            Write-Host "tsvpn: target '$t' must be a bare IPv4 address (no /32, no port)." -ForegroundColor Red
            $ok = $false
        }
    }
    return $ok
}

function Get-TailscalePrefs {
    $ts = Get-TailscaleExe
    if (-not $ts) { return $null }
    try { & $ts debug prefs 2>$null | ConvertFrom-Json } catch { $null }
}
