# Smoke test: boot the agent, exercise every primitive, print a compact report.
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

$root = Split-Path -Parent $PSScriptRoot
$agent = Join-Path $root 'agent\desktop-agent.ps1'
$ready = Join-Path $env:TEMP ('dsh-agent-smoke-' + [guid]::NewGuid().ToString('N') + '.json')
$outDir = Join-Path $root 'test\out'
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

$proc = Start-Process -FilePath 'powershell.exe' -PassThru -WindowStyle Hidden -ArgumentList @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', $agent,
    '-Port', '0', '-ReadyFile', $ready, '-IdleMinutes', '5'
)

$readyInfo = $null
for ($i = 0; $i -lt 100; $i++) {
    if (Test-Path $ready) {
        Start-Sleep -Milliseconds 100
        try { $readyInfo = [System.IO.File]::ReadAllText($ready) | ConvertFrom-Json; break } catch { }
    }
    Start-Sleep -Milliseconds 100
}
if (-not $readyInfo) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue; throw 'agent did not become ready' }
Write-Host ("agent ready on port {0} pid {1}" -f $readyInfo.port, $readyInfo.pid)

$client = New-Object System.Net.Sockets.TcpClient('127.0.0.1', [int]$readyInfo.port)
$client.NoDelay = $true
$stream = $client.GetStream()
$stream.ReadTimeout = 30000
$utf8 = [System.Text.UTF8Encoding]::new($false)
$reader = New-Object System.IO.StreamReader($stream, $utf8, $false, 8192)
$writer = New-Object System.IO.StreamWriter($stream, $utf8)
$writer.NewLine = "`n"
$writer.AutoFlush = $true

function Send-Agent {
    param([string]$Cmd, $Req = @{}, [string]$Label = '')
    $payload = ConvertTo-Json -InputObject @{ id = [guid]::NewGuid().ToString('N').Substring(0, 8); cmd = $Cmd; req = $Req } -Depth 10 -Compress
    $writer.WriteLine($payload)
    $line = $reader.ReadLine()
    if ($null -eq $line) { throw "agent closed the connection during $Cmd" }
    $resp = $line | ConvertFrom-Json
    if (-not $resp.ok) {
        Write-Host ("FAIL {0}: {1}" -f $Cmd, $resp.error.message) -ForegroundColor Red
        return $resp
    }
    if ($Label) { Write-Host ("OK   {0}: {1}" -f $Label, $Label) }
    return $resp
}

$sw = [System.Diagnostics.Stopwatch]::StartNew()

$r = Send-Agent 'ping'
Write-Host ("ping -> {0} ms" -f $sw.ElapsedMilliseconds)

$r = Send-Agent 'status'
$s = $r.result
Write-Host ("status: screen {0}x{1} os={2} ps={3} ocr={4} [{5}] uia={6}" -f $s.screen.width, $s.screen.height, $s.os, $s.psVersion, $s.ocr.available, ($s.ocr.languages -join ','), $s.uia.available)
Write-Host ("foreground: {0}" -f $s.foreground.title)

$sw.Restart()
$shotPath = Join-Path $outDir 'smoke-full.png'
$r = Send-Agent 'screenshot' @{ mode = 'full'; path = $shotPath }
Write-Host ("screenshot: {0} {1}x{2} {3} bytes in {4} ms" -f $r.result.path, $r.result.width, $r.result.height, $r.result.bytes, $sw.ElapsedMilliseconds)

$sw.Restart()
$r = Send-Agent 'ocr' @{ path = $shotPath; originX = 0; originY = 0; imageScale = 1 }
Write-Host ("ocr full screen: {0} lines in {1} ms" -f $r.result.count, $sw.ElapsedMilliseconds)
$r.result.lines | Select-Object -First 12 | ForEach-Object { Write-Host ("  [{0},{1},{2}x{3}] {4}" -f $_.x, $_.y, $_.width, $_.height, $_.text) }

$sw.Restart()
$r = Send-Agent 'ocr' @{ mode = 'region'; region = @{ x = 0; y = 0; width = 800; height = 200 }; scale = 2 }
Write-Host ("ocr live region: {0} lines in {1} ms" -f $r.result.count, $sw.ElapsedMilliseconds)

$r = Send-Agent 'windows' @{ action = 'list' }
Write-Host ("windows: {0}" -f $r.result.count)
$r.result.windows | Select-Object -First 8 | ForEach-Object { Write-Host ("  {0} [{1}] {2}x{3} {4}" -f $_.handle, $_.process, $_.rect.width, $_.rect.height, $_.title) }

$r = Send-Agent 'uia' @{ action = 'tree'; depth = 3; maxNodes = 30 }
if ($r.ok) { Write-Host ("uia tree: {0} nodes" -f $r.result.count); $r.result.nodes | Select-Object -First 8 | ForEach-Object { Write-Host ("  {0}{1} '{2}' {3}" -f ('  ' * $_.depth), $_.type, $_.name, $_.path) } }

$fixtures = [System.Text.Encoding]::UTF8.GetString([System.IO.File]::ReadAllBytes((Join-Path $PSScriptRoot 'fixtures.json'))) | ConvertFrom-Json
$r = Send-Agent 'clipboard' @{ action = 'set'; text = $fixtures.clipboard }
if ($r.ok) { Write-Host ("clipboard set: {0}" -f $r.result.set) }
$r = Send-Agent 'clipboard' @{ action = 'get' }
if ($r.ok) { Write-Host ("clipboard get: {0}" -f $r.result.text) }

$r = Send-Agent 'mouse' @{ action = 'move'; x = 20; y = 20 }
Write-Host ("mouse move: cursor {0},{1}" -f $r.result.cursor.x, $r.result.cursor.y)

$r = Send-Agent 'wait' @{ kind = 'window'; pattern = 'DeepSeek'; timeoutMs = 2000 }
Write-Host ("wait window: matched={0} in {1} ms" -f $r.result.matched, $r.result.elapsedMs)

$r = Send-Agent 'shutdown'
$client.Close()
Start-Sleep -Milliseconds 400
if (Get-Process -Id $proc.Id -ErrorAction SilentlyContinue) { Stop-Process -Id $proc.Id -Force }
if (Test-Path $ready) { Remove-Item $ready -Force }
Write-Host 'smoke test complete'
