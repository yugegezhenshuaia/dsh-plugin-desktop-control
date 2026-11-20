# desktop-agent.ps1 -- long-lived local agent for the DSH desktop-control plugin.
# Protocol: one JSON request per line in, one JSON response per line out, over TCP
# on 127.0.0.1. The plugin owns the connection and serializes requests.

param(
    [int]$Port = 0,
    [string]$Token = '',
    [string]$ReadyFile = '',
    [int]$IdleMinutes = 120,
    [string]$LogFile = ''
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

$libDir = Join-Path $PSScriptRoot 'lib'
. (Join-Path $libDir 'Core.ps1')
. (Join-Path $libDir 'Screen.ps1')
. (Join-Path $libDir 'Ocr.ps1')
. (Join-Path $libDir 'Input.ps1')
. (Join-Path $libDir 'Windows.ps1')
. (Join-Path $libDir 'Uia.ps1')
. (Join-Path $libDir 'Clipboard.ps1')

[DWin]::MakeDpiAware() | Out-Null

function Invoke-Status {
    param($Req)
    $screen = [DWin]::VirtualScreen()
    $fg = [DWin]::GetForegroundWindow()
    $fgInfo = $null
    if ($fg -ne [intptr]::Zero) { $fgInfo = Get-WindowInfo -Handle $fg }
    $ocrLanguages = @()
    $ocrAvailable = $true
    try { $ocrLanguages = @(Get-OcrLanguages) } catch { $ocrAvailable = $false }
    $uiaAvailable = $true
    try { Initialize-Uia } catch { $uiaAvailable = $false }
    $cursor = [DWin]::Cursor()
    return @{
        version = $script:AgentVersion
        agent = @{
            pid = $PID
            started = $script:StartedAt
            uptimeSec = [int]((Get-Date) - $script:StartedAt).TotalSeconds
            idleMinutes = $IdleMinutes
        }
        os = [System.Environment]::OSVersion.VersionString
        psVersion = $PSVersionTable.PSVersion.ToString()
        screen = @{ x = $screen[0]; y = $screen[1]; width = $screen[2]; height = $screen[3] }
        cursor = @{ x = $cursor[0]; y = $cursor[1] }
        foreground = $fgInfo
        ocr = @{ available = $ocrAvailable; languages = $ocrLanguages }
        uia = @{ available = $uiaAvailable }
    }
}

$script:Commands = @{
    'ping' = { param($Req) @{ pong = $true; time = (Get-Date).ToString('o') } }
    'status' = { param($Req) Invoke-Status -Req $Req }
    'screenshot' = { param($Req) Invoke-Screenshot -Req $Req }
    'ocr' = { param($Req) Invoke-Ocr -Req $Req }
    'mouse' = { param($Req) Invoke-Mouse -Req $Req }
    'keyboard' = { param($Req) Invoke-Keyboard -Req $Req }
    'windows' = { param($Req) Invoke-Window -Req $Req }
    'uia' = { param($Req) Invoke-UiaAction -Req $Req }
    'clipboard' = { param($Req) Invoke-Clipboard -Req $Req }
    'wait' = { param($Req) Invoke-Wait -Req $Req }
    'pixel' = { param($Req) Invoke-Pixel -Req $Req }
}

function Invoke-CommandRequest {
    param($Request)
    $cmd = [string]$Request.cmd
    if (-not $script:Commands.ContainsKey($cmd)) { throw "unknown agent command: $cmd" }
    return (& $script:Commands[$cmd] $Request.req)
}

function Write-ReadyFile {
    $payload = @{
        port = $script:ActualPort
        pid = $PID
        version = $script:AgentVersion
        token = $Token
        startedAt = (Get-Date).ToString('o')
    } | ConvertTo-Json -Depth 5 -Compress
    $dir = [System.IO.Path]::GetDirectoryName($ReadyFile)
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    [System.IO.File]::WriteAllText($ReadyFile, $payload, [System.Text.UTF8Encoding]::new($false))
}

$script:StartedAt = Get-Date
$script:Running = $true
$script:LogFile = $LogFile

if ($script:LogFile) {
    try {
        $dir = [System.IO.Path]::GetDirectoryName($script:LogFile)
        if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        if ((Test-Path $script:LogFile) -and (Get-Item $script:LogFile).Length -gt 2MB) {
            Remove-Item $script:LogFile -Force -ErrorAction SilentlyContinue
        }
        Add-Content -Path $script:LogFile -Value ("[{0}] agent start pid={1} version={2}" -f (Get-Date).ToString('s'), $PID, $script:AgentVersion) -Encoding UTF8
    }
    catch { $script:LogFile = '' }
}

function Write-AgentLog {
    param([string]$Line)
    if (-not $script:LogFile) { return }
    try { Add-Content -Path $script:LogFile -Value $Line -Encoding UTF8 } catch { }
}

$listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $Port)
$listener.Start()
$script:ActualPort = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
if ($ReadyFile) { Write-ReadyFile }

$lastActivity = Get-Date
$utf8 = [System.Text.UTF8Encoding]::new($false)

while ($script:Running) {
    if (-not $listener.Pending()) {
        if ($IdleMinutes -gt 0 -and ((Get-Date) - $lastActivity).TotalMinutes -gt $IdleMinutes) { break }
        Start-Sleep -Milliseconds 120
        continue
    }

    $client = $listener.AcceptTcpClient()
    $client.NoDelay = $true
    $stream = $client.GetStream()
    $stream.ReadTimeout = 3600000
    $reader = New-Object System.IO.StreamReader($stream, $utf8, $false, 8192)
    $writer = New-Object System.IO.StreamWriter($stream, $utf8)
    $writer.NewLine = "`n"
    $writer.AutoFlush = $true

    try {
        while ($script:Running) {
            $line = $reader.ReadLine()
            if ($null -eq $line) { break }
            $lastActivity = Get-Date
            if ([string]::IsNullOrWhiteSpace($line)) { continue }

            $id = $null
            $reply = $null
            $swRequest = [System.Diagnostics.Stopwatch]::StartNew()
            try {
                $request = $line | ConvertFrom-Json
                $id = $request.id
                if ($Token -and ([string]$request.token) -ne $Token) { throw 'invalid agent token' }
                if ([string]$request.cmd -eq 'shutdown') {
                    $reply = @{ id = $id; ok = $true; result = @{ bye = $true } }
                    $writer.WriteLine((ConvertTo-Json -InputObject $reply -Depth 8 -Compress))
                    $script:Running = $false
                    break
                }
                $result = Invoke-CommandRequest -Request $request
                $reply = @{ id = $id; ok = $true; result = $result }
                Write-AgentLog ("[{0}] {1} ok ({2} ms)" -f (Get-Date).ToString('s'), [string]$request.cmd, $swRequest.ElapsedMilliseconds)
            }
            catch {
                $reply = @{
                    id = $id
                    ok = $false
                    error = @{
                        message = [string]$_.Exception.Message
                        type = [string]$_.Exception.GetType().Name
                        detail = [string]$_.ScriptStackTrace
                    }
                }
                Write-AgentLog ("[{0}] {1} FAILED ({2} ms): {3}" -f (Get-Date).ToString('s'), [string]$request.cmd, $swRequest.ElapsedMilliseconds, [string]$_.Exception.Message)
            }
            $writer.WriteLine((ConvertTo-Json -InputObject $reply -Depth 14 -Compress))
        }
    }
    catch {
        # A dropped or timed-out connection ends this client session only.
    }
    finally {
        try { $writer.Dispose() } catch { }
        try { $reader.Dispose() } catch { }
        try { $client.Close() } catch { }
    }
}

try { $listener.Stop() } catch { }
if ($ReadyFile -and (Test-Path $ReadyFile)) { Remove-Item $ReadyFile -Force -ErrorAction SilentlyContinue }
