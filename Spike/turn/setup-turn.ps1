# Throwaway (spike/LNK-3): configure and start coturn on the Windows VPS.
# Run ON THE VPS from the folder that holds turnserver.exe and its DLLs:
#   powershell -ExecutionPolicy Bypass -File setup-turn.ps1 -PublicIp <vps-ip>
# The shared secret is generated here with a CSPRNG and never leaves this machine.
param([Parameter(Mandatory = $true)][string]$PublicIp)
$ErrorActionPreference = 'Stop'
$dir = $PSScriptRoot
$conf = Join-Path $dir 'turnserver.conf'

if (-not (Test-Path $conf)) {
    $bytes = New-Object byte[] 32
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $secret = [Convert]::ToBase64String($bytes)
    @"
listening-port=3478
external-ip=$PublicIp
min-port=49160
max-port=49200
realm=linko
use-auth-secret
static-auth-secret=$secret
fingerprint
no-tls
no-dtls
no-cli
no-multicast-peers
no-loopback-peers
denied-peer-ip=10.0.0.0-10.255.255.255
denied-peer-ip=172.16.0.0-172.31.255.255
denied-peer-ip=192.168.0.0-192.168.255.255
denied-peer-ip=169.254.0.0-169.254.255.255
log-file=$dir\turn.log
simple-log
"@ | Set-Content -Path $conf -Encoding ascii
    # Owner-only: Administrators and SYSTEM keep access, inheritance removed.
    icacls $conf /inheritance:r /grant:r '*S-1-5-32-544:F' '*S-1-5-18:F' | Out-Null # SIDs: locale-independent
    Write-Host 'turnserver.conf created (secret generated on this machine, not printed)'
} else {
    Write-Host 'turnserver.conf exists, keeping its secret'
}

foreach ($rule in @(
        @{ Name = 'Linko TURN UDP 3478'; Protocol = 'UDP'; Port = '3478' },
        @{ Name = 'Linko TURN TCP 3478'; Protocol = 'TCP'; Port = '3478' },
        @{ Name = 'Linko TURN relay UDP'; Protocol = 'UDP'; Port = '49160-49200' })) {
    if (-not (Get-NetFirewallRule -DisplayName $rule.Name -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName $rule.Name -Direction Inbound -Action Allow `
            -Protocol $rule.Protocol -LocalPort $rule.Port | Out-Null
    }
    Write-Host "firewall: $($rule.Name) open"
}

$running = Get-Process turnserver -ErrorAction SilentlyContinue
if ($running) { Write-Host "turnserver already running (pid $($running.Id))"; exit 0 }
Start-Process -FilePath (Join-Path $dir 'turnserver.exe') -ArgumentList '-c', $conf -WorkingDirectory $dir -WindowStyle Hidden
Start-Sleep -Seconds 2
$p = Get-Process turnserver -ErrorAction SilentlyContinue
if ($p) { Write-Host "turnserver started (pid $($p.Id))" } else { Write-Host 'turnserver did not start; see turn.log'; exit 1 }
