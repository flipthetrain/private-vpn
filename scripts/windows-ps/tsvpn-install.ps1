# ============================================================
#  tsvpn-install.ps1  -  install or update tsvpn on THIS machine.
#  Run in an elevated PowerShell on the Windows box itself.
#
#    .\tsvpn-install.ps1 -NodeJson .\my-host.json
#
#  There is no push script for this platform: Windows has no SSH
#  server by default, so copy the folder over and run it here.
#
#  What it does:
#    1. checks prerequisites, changing nothing if any are missing
#    2. copies the scripts to C:\ProgramData\tsvpn
#    3. installs node.json beside them
#    4. registers a scheduled task that re-applies everything at
#       boot
#    5. runs the self-heal, then the audit
#
#  Idempotent. Re-run any time.
#  Needs Tailscale installed and signed in first.
# ============================================================
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$NodeJson
)
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'tsvpn-lib.ps1')

if (-not (Test-TsvpnAdmin)) {
    Write-Host "Run this from an elevated PowerShell (Run as Administrator)." -ForegroundColor Red
    exit 1
}
if (-not (Test-Path $NodeJson)) { Write-Host "no such file: $NodeJson" -ForegroundColor Red; exit 1 }

# ---------- 1. validate + prerequisites ----------
$node = Get-TsvpnNode -Path $NodeJson
if (-not $node) { exit 1 }
if (-not (Test-TsvpnNode $node)) { exit 1 }
Write-Host "node.json valid: role=$($node.Role) targets=$(if ($node.Targets) { $node.Targets -join ',' } else { '<none>' })"

$ts = Get-TailscaleExe
if (-not $ts) {
    Write-Host ""
    Write-Host "Tailscale is not installed." -ForegroundColor Red
    Write-Host "  Get it from https://tailscale.com/download/windows, then run 'tailscale up'."
    Write-Host "Nothing has been changed."
    exit 1
}
& $ts status *> $null
if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "Tailscale is installed but this machine is not signed in." -ForegroundColor Red
    Write-Host "  Run 'tailscale up' first  -  authenticating is the one step no script can do."
    Write-Host "Nothing has been changed."
    exit 1
}

# ---------- 2. install ----------
New-Item -ItemType Directory -Force -Path $script:TsvpnDir | Out-Null
foreach ($f in 'tsvpn-lib.ps1','tsvpn-selfheal.ps1','tsvpn-audit.ps1') {
    $src = Join-Path $PSScriptRoot $f
    if (Test-Path $src) { Copy-Item $src -Destination $script:TsvpnDir -Force }
    elseif (-not (Test-Path (Join-Path $script:TsvpnDir $f))) {
        Write-Host "missing $f  -  copy the whole scripts/windows-ps/ folder across" -ForegroundColor Red
        exit 1
    }
}
Copy-Item $NodeJson -Destination $script:TsvpnNode -Force

# node.json is not secret, but it describes your network. Administrators only.
try {
    $acl = Get-Acl $script:TsvpnNode
    $acl.SetAccessRuleProtection($true, $false)
    $acl.Access | ForEach-Object { $acl.RemoveAccessRule($_) | Out-Null }
    foreach ($who in 'BUILTIN\Administrators','NT AUTHORITY\SYSTEM') {
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($who,'FullControl','Allow')))
    }
    Set-Acl -Path $script:TsvpnNode -AclObject $acl
} catch {
    Write-Host "  (could not tighten permissions on node.json: $($_.Exception.Message))" -ForegroundColor Yellow
}
Write-Host "installed $script:TsvpnDir"

# ---------- 3. run at boot ----------
# A scheduled task, not a service: the work is a short one-shot that must run
# after tailscaled is up, which is exactly what a delayed startup trigger is for.
$action  = New-ScheduledTaskAction -Execute 'powershell.exe' `
             -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $script:TsvpnDir 'tsvpn-selfheal.ps1')`""
$trigger = New-ScheduledTaskTrigger -AtStartup
$trigger.Delay = 'PT1M'
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings  = New-ScheduledTaskSettingsSet -StartWhenAvailable `
             -ExecutionTimeLimit (New-TimeSpan -Minutes 15) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
Register-ScheduledTask -TaskName 'tsvpn-selfheal' -Action $action -Trigger $trigger `
    -Principal $principal -Settings $settings -Force | Out-Null
Write-Host "scheduled task 'tsvpn-selfheal' registered (at startup, +1 min)"

# ---------- 4. apply + verify ----------
Write-Host ""
Write-Host "running the self-heal ..."
& (Join-Path $script:TsvpnDir 'tsvpn-selfheal.ps1')
exit $LASTEXITCODE
