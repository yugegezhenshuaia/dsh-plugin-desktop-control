# Input round-trip test: a real WinForms target window driven through the agent.
# ASCII-only source; Chinese test strings come from test/fixtures.json (UTF-8).
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class TestDpi
{
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    public static void Make() { try { SetProcessDpiAwarenessContext(new IntPtr(-4)); } catch { } try { SetProcessDPIAware(); } catch { } }
}
'@
[TestDpi]::Make()
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$root = Split-Path -Parent $PSScriptRoot
$outDir = Join-Path $PSScriptRoot 'out'
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$fixtures = [System.Text.Encoding]::UTF8.GetString([System.IO.File]::ReadAllBytes((Join-Path $PSScriptRoot 'fixtures.json'))) | ConvertFrom-Json

$agent = Join-Path $root 'agent\desktop-agent.ps1'
$ready = Join-Path $env:TEMP ('dsh-agent-input-' + [guid]::NewGuid().ToString('N') + '.json')
$log = Join-Path $outDir 'agent-stderr.log'
$proc = $null
$client = $null
$form = $null
$failures = New-Object System.Collections.ArrayList
$utf8 = [System.Text.UTF8Encoding]::new($false)
$reader = $null
$writer = $null

# Pump the WinForms message loop while waiting: the agent activates and clicks
# this very window, so a blocked client thread would deadlock the activation.
function Send-Agent {
    param([string]$Cmd, $Req = @{}, [int]$TimeoutMs = 15000)
    $payload = ConvertTo-Json -InputObject @{ id = 'x'; cmd = $Cmd; req = $Req } -Depth 10 -Compress
    $writer.WriteLine($payload)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
        [System.Windows.Forms.Application]::DoEvents()
        if ($stream.DataAvailable) {
            $line = $reader.ReadLine()
            if ($null -eq $line) { throw "agent closed during $Cmd" }
            $resp = $line | ConvertFrom-Json
            if (-not $resp.ok) { throw "agent error during $Cmd : $($resp.error.message)" }
            return $resp
        }
        Start-Sleep -Milliseconds 10
    }
    throw "agent did not answer $Cmd within $TimeoutMs ms"
}

function Pump {
    param([int]$Ms = 400)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $Ms) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 20
    }
}

try {
    # --- start the agent ------------------------------------------------
    $proc = Start-Process -FilePath 'powershell.exe' -PassThru -WindowStyle Hidden -RedirectStandardError $log -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', $agent, '-Port', '0', '-ReadyFile', $ready, '-IdleMinutes', '5'
    )
    $readyInfo = $null
    for ($i = 0; $i -lt 100; $i++) {
        if (Test-Path $ready) { try { $readyInfo = [System.IO.File]::ReadAllText($ready) | ConvertFrom-Json; break } catch { } }
        Start-Sleep -Milliseconds 100
    }
    if (-not $readyInfo) { throw 'agent did not become ready' }
    Write-Host ("agent ready: port={0} pid={1}" -f $readyInfo.port, $readyInfo.pid)

    $client = New-Object System.Net.Sockets.TcpClient('127.0.0.1', [int]$readyInfo.port)
    $client.NoDelay = $true
    $stream = $client.GetStream()
    $stream.ReadTimeout = 15000
    $reader = New-Object System.IO.StreamReader($stream, $utf8, $false, 8192)
    $writer = New-Object System.IO.StreamWriter($stream, $utf8)
    $writer.NewLine = "`n"; $writer.AutoFlush = $true

    $r = Send-Agent 'ping'
    Write-Host 'ping: ok'

    # --- build the target window ---------------------------------------
    $title = 'DSH agent input test ' + [guid]::NewGuid().ToString('N').Substring(0, 6)
    $form = New-Object System.Windows.Forms.Form
    $form.Text = $title
    $form.StartPosition = 'Manual'
    $form.Location = New-Object System.Drawing.Point(160, 160)
    $form.Size = New-Object System.Drawing.Size(560, 300)
    $form.ShowInTaskbar = $true

    $box = New-Object System.Windows.Forms.TextBox
    $box.Location = New-Object System.Drawing.Point(30, 40)
    $box.Size = New-Object System.Drawing.Size(480, 40)
    $box.Font = New-Object System.Drawing.Font('Microsoft YaHei', 14)
    $form.Controls.Add($box)

    $btn = New-Object System.Windows.Forms.Button
    $btn.Text = 'Submit'
    $btn.Location = New-Object System.Drawing.Point(30, 110)
    $btn.Size = New-Object System.Drawing.Size(150, 50)
    $form.Controls.Add($btn)

    $label = New-Object System.Windows.Forms.Label
    $label.Text = 'clicks=0'
    $label.Location = New-Object System.Drawing.Point(200, 120)
    $label.Size = New-Object System.Drawing.Size(200, 30)
    $form.Controls.Add($label)

    $script:clicks = 0
    $btn.Add_Click({ $script:clicks++; $label.Text = "clicks=$($script:clicks)" })

    $form.Show()
    Pump 400

    # --- drive it through the agent ------------------------------------
    $r = Send-Agent 'windows' @{ action = 'activate'; title = $title }
    Write-Host ("activate: activated={0} foreground={1}" -f $r.result.activated, $r.result.foreground)
    if (-not $r.result.foreground) { [void]$failures.Add('window did not become foreground') }
    Pump 300

    $boxPoint = $box.PointToScreen((New-Object System.Drawing.Point(40, 20)))
    $fg = (Send-Agent 'status').result.foreground
    Write-Host ("foreground before click: {0} [{1}] active={2}" -f $fg.title, $fg.className, $(if ($form.ActiveControl) { $form.ActiveControl.GetType().Name } else { 'none' }))
    $r = Send-Agent 'mouse' @{ action = 'click'; x = $boxPoint.X; y = $boxPoint.Y }
    Write-Host ("click textbox at {0},{1}: target={2}" -f $boxPoint.X, $boxPoint.Y, $r.result.target.className)
    Pump 300
    $fg = (Send-Agent 'status').result.foreground
    Write-Host ("foreground after click: {0} [{1}] active={2}" -f $fg.title, $fg.className, $(if ($form.ActiveControl) { $form.ActiveControl.GetType().Name } else { 'none' }))

    # Unicode text (auto -> paste under the sandboxed shell, where SendInput is dropped)
    $r = Send-Agent 'keyboard' @{ action = 'type'; text = $fixtures.typing }
    Write-Host ("type method={0} chars={1}" -f $r.result.method, $r.result.characters)
    Pump 500
    if ($box.Text -ne $fixtures.typing) { [void]$failures.Add("typed text mismatch: got '$($box.Text)'") }
    else { Write-Host ("type unicode: '{0}'" -f $box.Text) }

    # ASCII text through virtual-key codes
    $box.Clear()
    Pump 150
    $r = Send-Agent 'keyboard' @{ action = 'type'; text = 'Hello World 42!' }
    Pump 400
    if ($box.Text -ne 'Hello World 42!') { [void]$failures.Add("ascii typing mismatch: got '$($box.Text)'") }
    else { Write-Host ("type ascii (keys): '{0}'" -f $box.Text) }

    $btnPoint = $btn.PointToScreen((New-Object System.Drawing.Point(75, 25)))
    $r = Send-Agent 'mouse' @{ action = 'click'; x = $btnPoint.X; y = $btnPoint.Y }
    Pump 400
    if ($script:clicks -ne 1) { [void]$failures.Add("button click not registered (clicks=$($script:clicks))") }
    else { Write-Host 'click: button click registered' }

    # modifier keys: Ctrl+End must move the caret to the end before typing
    $null = Send-Agent 'mouse' @{ action = 'click'; x = $boxPoint.X; y = $boxPoint.Y }
    Pump 200
    $null = Send-Agent 'keyboard' @{ action = 'hotkey'; keys = 'ctrl+end' }
    Pump 150
    $null = Send-Agent 'keyboard' @{ action = 'type'; text = '9' }
    Pump 300
    if (-not $box.Text.EndsWith('9')) { [void]$failures.Add("ctrl+end did not move the caret: '$($box.Text)'") }
    else { Write-Host 'hotkey: ctrl+end moves the caret' }

    $formHandle = (Send-Agent 'windows' @{ action = 'find'; title = $title }).result.window.handle
    $r = Send-Agent 'uia' @{ action = 'tree'; handle = $formHandle; depth = 4; maxNodes = 60 }
    Write-Host ("uia tree: {0} nodes" -f $r.result.count)
    $r.result.nodes | Select-Object -First 12 | ForEach-Object { Write-Host ("  {0}{1} '{2}' {3}" -f ('  ' * $_.depth), $_.type, $_.name, $_.path) }

    $r = Send-Agent 'mouse' @{ action = 'scroll'; x = $boxPoint.X; y = $boxPoint.Y; amount = -2 }
    Write-Host 'scroll: ok'

    $r = Send-Agent 'clipboard' @{ action = 'set'; text = $fixtures.clipboard }
    Write-Host ("clipboard set: {0}" -f $r.result.set)
    $r = Send-Agent 'clipboard' @{ action = 'get' }
    if ($r.result.text -ne $fixtures.clipboard) { [void]$failures.Add('clipboard round trip mismatch') }
    else { Write-Host 'clipboard: round trip ok' }

    # --- window-scoped OCR ---------------------------------------------
    $handle = (Send-Agent 'windows' @{ action = 'activate'; title = $title }).result.window.handle
    $shot = Join-Path $outDir 'input-window.png'
    $r = Send-Agent 'screenshot' @{ mode = 'window'; handle = $handle; path = $shot }
    Write-Host ("window screenshot: {0}x{1} origin={2},{3}" -f $r.result.width, $r.result.height, $r.result.origin.x, $r.result.origin.y)
    $r = Send-Agent 'ocr' @{ path = $shot; originX = $r.result.origin.x; originY = $r.result.origin.y; imageScale = 1 }
    Write-Host ("ocr window: {0} lines, 'Submit' found={1}" -f $r.result.count, ($r.result.text -match 'Submit'))

    $r = Send-Agent 'uia' @{ action = 'find'; handle = $handle; name = 'Submit'; controlType = 'Button' }
    Write-Host ("uia find Submit: {0} matches" -f $r.result.count)

    Send-Agent 'shutdown' | Out-Null
}
catch {
    [void]$failures.Add([string]$_.Exception.Message)
}
finally {
    if ($writer) { try { $writer.Dispose() } catch { } }
    if ($reader) { try { $reader.Dispose() } catch { } }
    if ($client) { try { $client.Close() } catch { } }
    if ($form) { try { $form.Close(); $form.Dispose() } catch { } }
    Start-Sleep -Milliseconds 300
    if ($proc -and -not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
    if (Test-Path $ready) { Remove-Item $ready -Force -ErrorAction SilentlyContinue }
}

if ($failures.Count -gt 0) {
    Write-Host ''
    foreach ($f in $failures) { Write-Host ("FAIL " + $f) }
    if (Test-Path $log) { Write-Host '--- agent stderr ---'; Get-Content $log -Raw }
    exit 1
}
Write-Host 'input test passed'
