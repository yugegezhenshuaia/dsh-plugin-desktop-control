# Verify text-wait tolerance for OCR spacing: the screen shows "score 0 / 6"
# (Chinese glyphs come from test/fixtures.json) while the caller waits for
# "score0/6" without spaces, and for the equivalent regular expression.
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'agent\lib\Core.ps1')
. (Join-Path $root 'agent\lib\Screen.ps1')
. (Join-Path $root 'agent\lib\Ocr.ps1')
. (Join-Path $root 'agent\lib\Input.ps1')
. (Join-Path $root 'agent\lib\Windows.ps1')
. (Join-Path $root 'agent\lib\Uia.ps1')
. (Join-Path $root 'agent\lib\Clipboard.ps1')
[DWin]::MakeDpiAware() | Out-Null

$fixtures = [System.Text.Encoding]::UTF8.GetString([System.IO.File]::ReadAllBytes((Join-Path $PSScriptRoot 'fixtures.json'))) | ConvertFrom-Json

$form = New-Object System.Windows.Forms.Form
$form.Text = 'wait text probe'
$form.StartPosition = 'Manual'
$form.Location = New-Object System.Drawing.Point(300, 260)
$form.Size = New-Object System.Drawing.Size(700, 260)
$label = New-Object System.Windows.Forms.Label
$label.Text = $fixtures.waitText
$label.Font = New-Object System.Drawing.Font('Microsoft YaHei', 30, [System.Drawing.FontStyle]::Bold)
$label.AutoSize = $true
$label.Location = New-Object System.Drawing.Point(30, 60)
$form.Controls.Add($label)
$form.Show()
[System.Windows.Forms.Application]::DoEvents()
Start-Sleep -Milliseconds 400
[System.Windows.Forms.Application]::DoEvents()

$box = $label.Bounds
$origin = $label.PointToScreen([System.Drawing.Point]::Empty)
$region = @{ x = $origin.X - 10; y = $origin.Y - 10; width = $box.Width + 40; height = $box.Height + 40 }

$failures = 0
$ocr = Invoke-Ocr -Req @{ mode = 'region'; region = $region; scale = 2 }
Write-Host ("ocr text        : '" + ($ocr.text -replace "`n", ' | ') + "'")
if ($ocr.text -notmatch $fixtures.waitLabelCheck) { Write-Host 'FAIL: OCR did not read the label'; $failures++ }

$compact = Invoke-Wait -Req @{ kind = 'text'; pattern = $fixtures.waitCompact; region = $region; timeoutMs = 4000; intervalMs = 200 }
Write-Host ("compact pattern : matched={0} elapsed={1}ms" -f $compact.matched, $compact.elapsedMs)
if (-not $compact.matched) { Write-Host 'FAIL: whitespace-insensitive match failed'; $failures++ }

$regex = Invoke-Wait -Req @{ kind = 'text'; pattern = $fixtures.waitRegex; region = $region; timeoutMs = 4000; intervalMs = 200 }
Write-Host ("regex pattern   : matched={0} elapsed={1}ms" -f $regex.matched, $regex.elapsedMs)
if (-not $regex.matched) { Write-Host 'FAIL: regex match failed'; $failures++ }

$missing = Invoke-Wait -Req @{ kind = 'text'; pattern = $fixtures.waitAbsent; region = $region; timeoutMs = 1200; intervalMs = 300 }
Write-Host ("absent pattern  : matched={0} elapsed={1}ms (expected false)" -f $missing.matched, $missing.elapsedMs)
if ($missing.matched) { Write-Host 'FAIL: absent pattern matched'; $failures++ }

$form.Close()
$form.Dispose()

if ($failures -gt 0) { Write-Host ("wait text test FAILED ({0})" -f $failures); exit 1 }
Write-Host 'wait text test passed'
