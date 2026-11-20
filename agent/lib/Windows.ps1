# Windows.ps1 -- window inventory, targeting, lifecycle actions, launching, waiting.

function Get-WindowInfo {
    param([intptr]$Handle, [int]$Order = 0)

    $rect = [DWin]::Rect($Handle)
    $pid2 = [DWin]::Pid($Handle)
    $fg = [DWin]::GetForegroundWindow()
    return @{
        handle = [int64]$Handle
        title = [DWin]::Title($Handle)
        className = [DWin]::ClassName($Handle)
        pid = [int]$pid2
        process = (Get-ProcessNameSafe -ProcessId $pid2)
        rect = @{ x = $rect[0]; y = $rect[1]; width = $rect[2]; height = $rect[3] }
        minimized = [DWin]::IsMinimized($Handle)
        maximized = [DWin]::IsMaximized($Handle)
        foreground = ($fg -eq $Handle)
        z = $Order
    }
}

function Get-WindowList {
    param([bool]$IncludeEmpty = $false)

    $result = New-Object System.Collections.ArrayList
    $i = 0
    foreach ($h in [DWin]::TopWindows()) {
        if (-not [DWin]::IsShown($h)) { continue }
        $title = [DWin]::Title($h)
        $class = [DWin]::ClassName($h)
        if (-not $IncludeEmpty -and [string]::IsNullOrWhiteSpace($title) -and $class -ne 'ApplicationFrameWindow') { continue }
        $rect = [DWin]::Rect($h)
        if ($rect[2] -le 0 -or $rect[3] -le 0) { continue }
        [void]$result.Add((Get-WindowInfo -Handle $h -Order $i))
        $i++
    }
    return $result.ToArray()
}

function Find-WindowTarget {
    param([int64]$Handle = 0, [string]$Title = '', [string]$ProcessName = '')

    if ($Handle -ne 0) {
        if (-not [DWin]::IsAlive([intptr]$Handle)) { throw "window handle $Handle no longer exists" }
        return (Get-WindowInfo -Handle ([intptr]$Handle))
    }

    $windows = @(Get-WindowList)
    if ([string]::IsNullOrWhiteSpace($Title) -and [string]::IsNullOrWhiteSpace($ProcessName)) {
        $fg = [DWin]::GetForegroundWindow()
        if ($fg -ne [intptr]::Zero) { return (Get-WindowInfo -Handle $fg) }
        throw 'no foreground window and no target specified'
    }

    $candidates = $windows
    if (-not [string]::IsNullOrWhiteSpace($ProcessName)) {
        $candidates = @($candidates | Where-Object { $_.process -ieq $ProcessName })
    }
    if (-not [string]::IsNullOrWhiteSpace($Title)) {
        $exact = @($candidates | Where-Object { $_.title -ieq $Title })
        if ($exact.Count -gt 0) { return $exact[0] }
        $regex = @($candidates | Where-Object { $_.title -match [regex]::Escape($Title) })
        if ($regex.Count -gt 0) { return $regex[0] }
        try {
            $wild = @($candidates | Where-Object { $_.title -match $Title })
            if ($wild.Count -gt 0) { return $wild[0] }
        }
        catch { }
    }
    elseif ($candidates.Count -gt 0) {
        return $candidates[0]
    }

    $visible = ($windows | ForEach-Object { $_.title }) -join ' | '
    throw "no window matches title='$Title' process='$ProcessName'. Visible windows: $visible"
}

function Invoke-Window {
    param($Req)

    $action = 'list'; if ($Req.action) { $action = [string]$Req.action }

    if ($action -eq 'list') {
        $includeEmpty = $false
        if ($Req.includeEmpty -eq $true) { $includeEmpty = $true }
        $list = @(Get-WindowList -IncludeEmpty $includeEmpty)
        return @{ count = $list.Count; windows = $list }
    }

    if ($action -eq 'launch') {
        return (Invoke-LaunchWindow -Req $Req)
    }

    $handle = 0
    if ($null -ne $Req.handle) { $handle = [int64]$Req.handle }
    $title = ''; if ($Req.title) { $title = [string]$Req.title }
    $processName = ''; if ($Req.process) { $processName = [string]$Req.process }

    if ($action -eq 'find') {
        $target = Find-WindowTarget -Handle $handle -Title $title -ProcessName $processName
        return @{ window = $target }
    }

    $target = Find-WindowTarget -Handle $handle -Title $title -ProcessName $processName
    $h = [intptr]$target.handle

    switch ($action) {
        'activate' {
            $ok = [DWin]::Activate($h)
            Start-Sleep -Milliseconds 120
            $now = Get-WindowInfo -Handle $h
            return @{ activated = $ok; window = $now; foreground = $now.foreground }
        }
        'minimize' { [void][DWin]::ShowWindow($h, 6); Start-Sleep -Milliseconds 80 }
        'maximize' { [void][DWin]::ShowWindow($h, 3); Start-Sleep -Milliseconds 120 }
        'restore' { [void][DWin]::ShowWindow($h, 9); Start-Sleep -Milliseconds 120 }
        'close' {
            [void][DWin]::PostMessageW($h, 0x0010, [intptr]::Zero, [intptr]::Zero)
            Start-Sleep -Milliseconds 200
            return @{ closed = (-not [DWin]::IsAlive($h)); handle = $target.handle }
        }
        'move' {
            $x = [int]$Req.x; $y = [int]$Req.y
            $w = $target.rect.width; $hh = $target.rect.height
            if ($null -ne $Req.width) { $w = [int]$Req.width }
            if ($null -ne $Req.height) { $hh = [int]$Req.height }
            [void][DWin]::SetWindowPos($h, [intptr]::Zero, $x, $y, $w, $hh, 0x0040)
            Start-Sleep -Milliseconds 80
        }
        default { throw "unknown window action: $action" }
    }

    return @{ window = (Get-WindowInfo -Handle $h); action = $action }
}

function Invoke-LaunchWindow {
    param($Req)

    $command = [string]$Req.command
    if ([string]::IsNullOrWhiteSpace($command)) { throw 'launch requires a command' }
    $timeoutMs = 8000
    if ($Req.timeoutMs) { $timeoutMs = [int]$Req.timeoutMs }

    $before = @{}
    foreach ($w in @(Get-WindowList)) { $before[[string]$w.handle] = $true }

    $proc = $null
    $start = @{ }
    if ($command -match '^[a-zA-Z][a-zA-Z0-9+.-]*://') {
        $proc = Start-Process -FilePath $command -PassThru -ErrorAction Stop
    }
    else {
        $fileArgs = @()
        if ($Req.args) { $fileArgs = @($Req.args) }
        $startArgs = @{ FilePath = $command; PassThru = $true; ErrorAction = 'Stop' }
        if ($fileArgs.Count -gt 0) { $startArgs.ArgumentList = $fileArgs }
        if ($Req.cwd) { $startArgs.WorkingDirectory = [string]$Req.cwd }
        $proc = Start-Process @startArgs
    }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $found = $null
    while ($sw.ElapsedMilliseconds -lt $timeoutMs) {
        Start-Sleep -Milliseconds 250
        foreach ($w in @(Get-WindowList)) {
            if ($before.ContainsKey([string]$w.handle)) { continue }
            if ([string]::IsNullOrWhiteSpace($w.title)) { continue }
            $found = $w
            break
        }
        if ($found) { break }
    }
    $sw.Stop()

    return @{
        pid = $(if ($proc) { [int]$proc.Id } else { 0 })
        process = $(if ($proc) { $proc.ProcessName } else { '' })
        window = $found
        waitedMs = [int]$sw.ElapsedMilliseconds
    }
}

function Invoke-Wait {
    param($Req)

    $kind = 'window'; if ($Req.kind) { $kind = [string]$Req.kind }
    $pattern = [string]$Req.pattern
    if ([string]::IsNullOrWhiteSpace($pattern)) { throw 'wait requires a pattern' }
    $timeoutMs = 10000
    if ($Req.timeoutMs) { $timeoutMs = [int]$Req.timeoutMs }
    $intervalMs = 400
    if ($Req.intervalMs) { $intervalMs = [int][math]::Max(150, [int]$Req.intervalMs) }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $lastDetail = $null
    while ($sw.ElapsedMilliseconds -lt $timeoutMs) {
        if ($kind -eq 'window') {
            $hit = $null
            foreach ($w in @(Get-WindowList)) {
                if ($w.title -match [regex]::Escape($pattern)) { $hit = $w; break }
            }
            if (-not $hit) {
                try { foreach ($w in @(Get-WindowList)) { if ($w.title -match $pattern) { $hit = $w; break } } } catch { }
            }
            if ($hit) {
                $sw.Stop()
                return @{ matched = $true; kind = 'window'; elapsedMs = [int]$sw.ElapsedMilliseconds; window = $hit }
            }
        }
        elseif ($kind -eq 'text') {
            $ocrArgs = @{ mode = 'full'; scale = 1.5 }
            if ($Req.handle) { $ocrArgs.mode = 'window'; $ocrArgs.handle = [int64]$Req.handle }
            if ($Req.region) { $ocrArgs.mode = 'region'; $ocrArgs.region = $Req.region }
            $ocr = Invoke-Ocr -Req $ocrArgs
            # OCR inserts spaces between CJK glyphs and around digits, so compare a
            # whitespace-free view and fall back to the caller's regular expression.
            $compactPattern = ($pattern -replace '\s+', '')
            $regex = $null
            try { $regex = New-Object regex($pattern) } catch { }
            foreach ($line in $ocr.lines) {
                $compactLine = ($line.text -replace '\s+', '')
                $hit = $false
                if ($compactPattern -ne '' -and $compactLine.IndexOf($compactPattern, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                    $hit = $true
                }
                elseif ($regex -and $regex.IsMatch($line.text)) {
                    $hit = $true
                }
                if ($hit) {
                    $sw.Stop()
                    return @{ matched = $true; kind = 'text'; elapsedMs = [int]$sw.ElapsedMilliseconds; line = $line; text = $ocr.text }
                }
            }
            $lastDetail = $ocr.text
        }
        else { throw "unknown wait kind: $kind" }
        Start-Sleep -Milliseconds $intervalMs
    }

    $sw.Stop()
    return @{ matched = $false; kind = $kind; elapsedMs = [int]$sw.ElapsedMilliseconds; detail = $lastDetail }
}
