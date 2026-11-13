# Throwaway (spike/LNK-3): print short-lived TURN REST credentials (valid 1 h).
# Run ON THE VPS next to turnserver.conf. Prints username and credential only;
# the shared secret itself is read from the local config and never printed.
#   powershell -ExecutionPolicy Bypass -File turn-cred.ps1 | Set-Clipboard
# Paste the result over RDP; never retype it: Base64 look-alikes (I/l, 0/O) silently break the HMAC.
$ErrorActionPreference = 'Stop'
$conf = Join-Path $PSScriptRoot 'turnserver.conf'
$line = Select-String -Path $conf -Pattern '^static-auth-secret=(.+)$' | Select-Object -First 1
$secret = $line.Matches[0].Groups[1].Value
$expiry = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 3600
$username = "${expiry}:spike"
$hmac = New-Object System.Security.Cryptography.HMACSHA1
$hmac.Key = [Text.Encoding]::UTF8.GetBytes($secret)
$credential = [Convert]::ToBase64String($hmac.ComputeHash([Text.Encoding]::UTF8.GetBytes($username)))
Write-Output "username:   $username"
Write-Output "credential: $credential"
