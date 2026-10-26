# Throwaway (spike/LNK-3): WebSocket relay for Windows without Python.
# Forwards every text message to all other clients. Run ON THE VPS as admin:
#   powershell -ExecutionPolicy Bypass -File relay.ps1 [-Port 9000]
param([int]$Port = 9000)
$ErrorActionPreference = 'Stop'

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://+:$Port/")
$listener.Start()
Write-Host "relay listening on $Port"

$none = [System.Threading.CancellationToken]::None
$clients = New-Object System.Collections.ArrayList
$accept = $listener.GetContextAsync()

function Receive($c) {
    $segment = New-Object 'System.ArraySegment[byte]' -ArgumentList $c.buf, $c.len, ($c.buf.Length - $c.len)
    $c.task = $c.ws.ReceiveAsync($segment, $none)
}

while ($true) {
    $tasks = [System.Threading.Tasks.Task[]](@($accept) + @($clients | ForEach-Object { $_.task }))
    $i = [System.Threading.Tasks.Task]::WaitAny($tasks)
    if ($i -eq 0) {
        $ctx = $accept.Result
        $accept = $listener.GetContextAsync()
        if (-not $ctx.Request.IsWebSocketRequest) { $ctx.Response.StatusCode = 400; $ctx.Response.Close(); continue }
        $ws = $ctx.AcceptWebSocketAsync($null).GetAwaiter().GetResult().WebSocket
        $c = @{ ws = $ws; buf = New-Object byte[] 262144; len = 0; task = $null }
        Receive $c
        [void]$clients.Add($c)
        Write-Host "+ client ($($clients.Count))"
        continue
    }
    $c = $clients[$i - 1]
    $result = $null
    try { $result = $c.task.GetAwaiter().GetResult() } catch { }
    if (-not $result -or $result.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close -or $c.len + $result.Count -ge $c.buf.Length) {
        $clients.Remove($c)
        try { $c.ws.Abort() } catch { }
        Write-Host "- client ($($clients.Count))"
        continue
    }
    $c.len += $result.Count
    if ($result.EndOfMessage) {
        $message = New-Object 'System.ArraySegment[byte]' -ArgumentList $c.buf, 0, $c.len
        $kind = [Text.Encoding]::UTF8.GetString($c.buf, 0, [Math]::Min($c.len, 30))
        Write-Host "relay $kind..."
        foreach ($other in @($clients)) {
            if ($other -ne $c) {
                try { $other.ws.SendAsync($message, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $none).GetAwaiter().GetResult() } catch { }
            }
        }
        $c.len = 0
    }
    Receive $c
}
