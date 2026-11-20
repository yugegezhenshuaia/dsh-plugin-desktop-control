# Input.ps1 -- synthetic mouse and keyboard input via SendInput.

$script:VkMap = @{
    'enter' = 0x0D; 'return' = 0x0D; 'tab' = 0x09; 'esc' = 0x1B; 'escape' = 0x1B
    'backspace' = 0x08; 'delete' = 0x2E; 'del' = 0x2E; 'insert' = 0x2D; 'ins' = 0x2D
    'space' = 0x20; 'up' = 0x26; 'down' = 0x28; 'left' = 0x25; 'right' = 0x27
    'home' = 0x24; 'end' = 0x23; 'pageup' = 0x21; 'pagedown' = 0x22; 'pgup' = 0x21; 'pgdn' = 0x22
    'ctrl' = 0x11; 'control' = 0x11; 'alt' = 0x12; 'shift' = 0x10; 'win' = 0x5B; 'lwin' = 0x5B
    'capslock' = 0x14; 'printscreen' = 0x2C; 'prtsc' = 0x2C; 'menu' = 0x5D
    'minus' = 0xBD; 'equal' = 0xBB; 'plus' = 0xBB; 'comma' = 0xBC; 'period' = 0xBE; 'dot' = 0xBE
    'slash' = 0xBF; 'semicolon' = 0xBA; 'quote' = 0xDE; 'backquote' = 0xC0; 'grave' = 0xC0
    'bracketleft' = 0xDB; 'bracketright' = 0xDD; 'backslash' = 0xDC
}

for ($i = 1; $i -le 12; $i++) { $script:VkMap["f$i"] = 0x6F + $i }

function Get-VirtualKey {
    param([string]$Name)
    $key = $Name.Trim().ToLowerInvariant()
    if ($script:VkMap.ContainsKey($key)) { return [uint16]$script:VkMap[$key] }
    if ($key.Length -eq 1) {
        $code = [int][char]$key.ToUpperInvariant()
        if (($code -ge 0x30 -and $code -le 0x39) -or ($code -ge 0x41 -and $code -le 0x5A)) { return [uint16]$code }
    }
    if ($key -match '^0x[0-9a-f]+$') { return [uint16][Convert]::ToInt32($key.Substring(2), 16) }
    throw "unknown key name: $Name"
}

function Get-WindowUnder {
    param([int]$X, [int]$Y)
    $h = [DWin]::WindowAt($X, $Y)
    if ($h -eq [intptr]::Zero) { return $null }
    return @{
        handle = [int64]$h
        title = [DWin]::Title($h)
        className = [DWin]::ClassName($h)
        pid = [int][DWin]::Pid($h)
        process = (Get-ProcessNameSafe -ProcessId ([DWin]::Pid($h)))
    }
}

function Invoke-Mouse {
    param($Req)

    $action = 'click'; if ($Req.action) { $action = [string]$Req.action }
    $x = 0; $y = 0
    if ($null -ne $Req.x) { $x = [int]$Req.x }
    if ($null -ne $Req.y) { $y = [int]$Req.y }
    $before = Get-WindowUnder -X $x -Y $y

    switch ($action) {
        'move' {
            [void][DWin]::MoveTo($x, $y)
        }
        'click' {
            [void][DWin]::MoveTo($x, $y)
            Start-Sleep -Milliseconds 20
            [DWin]::Button($true, 'left'); Start-Sleep -Milliseconds 30; [DWin]::Button($false, 'left')
        }
        'double_click' {
            [void][DWin]::MoveTo($x, $y)
            Start-Sleep -Milliseconds 20
            for ($i = 0; $i -lt 2; $i++) {
                [DWin]::Button($true, 'left'); Start-Sleep -Milliseconds 25; [DWin]::Button($false, 'left')
                if ($i -eq 0) { Start-Sleep -Milliseconds 60 }
            }
        }
        'right_click' {
            [void][DWin]::MoveTo($x, $y)
            Start-Sleep -Milliseconds 20
            [DWin]::Button($true, 'right'); Start-Sleep -Milliseconds 30; [DWin]::Button($false, 'right')
        }
        'middle_click' {
            [void][DWin]::MoveTo($x, $y)
            Start-Sleep -Milliseconds 20
            [DWin]::Button($true, 'middle'); Start-Sleep -Milliseconds 30; [DWin]::Button($false, 'middle')
        }
        'down' { [void][DWin]::MoveTo($x, $y); [DWin]::Button($true, 'left') }
        'up' { [DWin]::Button($false, 'left') }
        'drag' {
            $toX = [int]$Req.toX; $toY = [int]$Req.toY
            [void][DWin]::MoveTo($x, $y)
            Start-Sleep -Milliseconds 40
            [DWin]::Button($true, 'left')
            $steps = 12
            for ($i = 1; $i -le $steps; $i++) {
                $nx = [int]($x + ($toX - $x) * $i / $steps)
                $ny = [int]($y + ($toY - $y) * $i / $steps)
                [void][DWin]::MoveTo($nx, $ny)
                Start-Sleep -Milliseconds 15
            }
            Start-Sleep -Milliseconds 40
            [DWin]::Button($false, 'left')
        }
        'scroll' {
            [void][DWin]::MoveTo($x, $y)
            $amount = 3
            if ($null -ne $Req.amount) { $amount = [int]$Req.amount }
            $horizontal = $false
            if ($Req.horizontal -eq $true) { $horizontal = $true }
            [DWin]::Wheel([int]($amount * 120), $horizontal)
        }
        default { throw "unknown mouse action: $action" }
    }

    Start-Sleep -Milliseconds 60
    $cursor = [DWin]::Cursor()
    return @{
        action = $action
        x = $x
        y = $y
        cursor = @{ x = $cursor[0]; y = $cursor[1] }
        target = $before
    }
}

function Test-AsciiText {
    param([string]$Text)
    foreach ($ch in $Text.ToCharArray()) {
        if ([int]$ch -gt 126 -or [int]$ch -lt 32) { return $false }
    }
    return $true
}

function Send-TextByPaste {
    param([string]$Text)

    # Paste is the only path that survives an active IME and reaches CJK text:
    # key codes sent to a Chinese input method get composed instead of typed.
    $savedText = $null
    $savedImage = $null
    try {
        if ([System.Windows.Forms.Clipboard]::ContainsText()) { $savedText = [System.Windows.Forms.Clipboard]::GetText() }
        elseif ([System.Windows.Forms.Clipboard]::ContainsImage()) { $savedImage = [System.Windows.Forms.Clipboard]::GetImage() }
    }
    catch { }

    [void](Set-ClipboardText -Text $Text)
    Start-Sleep -Milliseconds 60
    [DWin]::Key(0x11, $true)   # Ctrl down
    [DWin]::Key(0x56, $true)   # V down
    Start-Sleep -Milliseconds 30
    [DWin]::Key(0x56, $false)
    [DWin]::Key(0x11, $false)
    Start-Sleep -Milliseconds 120

    try {
        if ($null -ne $savedImage) { [System.Windows.Forms.Clipboard]::SetImage($savedImage) }
        elseif ($null -ne $savedText) { [void](Set-ClipboardText -Text $savedText) }
    }
    catch { }
    return $true
}

function Invoke-Keyboard {
    param($Req)

    $action = 'type'; if ($Req.action) { $action = [string]$Req.action }

    if ($action -eq 'type') {
        $text = [string]$Req.text
        if ([string]::IsNullOrEmpty($text)) { throw 'type requires text' }
        $method = 'auto'
        if ($Req.method) { $method = [string]$Req.method }
        $asciiOnly = Test-AsciiText -Text $text

        # auto pastes: key codes are mangled by an active IME (Chinese input turns
        # ASCII into composed text), while paste reaches every application.
        if ($method -eq 'auto') { $method = 'paste' }

        switch ($method) {
            'keys' {
                if (-not $asciiOnly) { throw 'the keys method types printable ASCII only; use auto or paste for other text' }
                $chunk = 120
                for ($i = 0; $i -lt $text.Length; $i += $chunk) {
                    $len = [math]::Min($chunk, $text.Length - $i)
                    [DWin]::SendAscii($text.Substring($i, $len))
                    Start-Sleep -Milliseconds 10
                }
            }
            'unicode' {
                $chunk = 180
                for ($i = 0; $i -lt $text.Length; $i += $chunk) {
                    $len = [math]::Min($chunk, $text.Length - $i)
                    [void][DWin]::SendUnicode($text.Substring($i, $len))
                    Start-Sleep -Milliseconds 12
                }
            }
            'paste' { [void](Send-TextByPaste -Text $text) }
            default { throw "unknown type method: $method" }
        }

        Start-Sleep -Milliseconds 90
        return @{ action = 'type'; method = $method; characters = $text.Length; asciiOnly = $asciiOnly }
    }

    if ($action -eq 'press' -or $action -eq 'hotkey') {
        $spec = [string]$Req.keys
        if ([string]::IsNullOrEmpty($spec)) { throw 'press requires keys, for example "enter" or "ctrl+s"' }
        $parts = $spec.Split('+') | Where-Object { $_.Trim() -ne '' }
        $keys = @($parts | ForEach-Object { Get-VirtualKey $_ })
        if ($keys.Count -eq 0) { throw "cannot parse keys: $spec" }
        $holdMs = 40
        if ($Req.holdMs) { $holdMs = [int]$Req.holdMs }
        for ($i = 0; $i -lt $keys.Count - 1; $i++) { [DWin]::Key($keys[$i], $true); Start-Sleep -Milliseconds 15 }
        [DWin]::Key($keys[$keys.Count - 1], $true)
        Start-Sleep -Milliseconds $holdMs
        [DWin]::Key($keys[$keys.Count - 1], $false)
        for ($i = $keys.Count - 2; $i -ge 0; $i--) { Start-Sleep -Milliseconds 15; [DWin]::Key($keys[$i], $false) }
        Start-Sleep -Milliseconds 60
        return @{ action = $action; keys = $spec; count = $keys.Count }
    }

    throw "unknown keyboard action: $action"
}
