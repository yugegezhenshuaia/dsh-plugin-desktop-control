# Clipboard.ps1 -- text clipboard access (STA required, provided by the agent process).

function Get-ClipboardText {
    param([int]$Retries = 6)
    for ($i = 0; $i -lt $Retries; $i++) {
        try {
            if ([System.Windows.Forms.Clipboard]::ContainsText()) {
                return [string][System.Windows.Forms.Clipboard]::GetText()
            }
            return ''
        }
        catch {
            Start-Sleep -Milliseconds 80
        }
    }
    throw 'the clipboard is locked by another application'
}

function Set-ClipboardText {
    param([string]$Text, [int]$Retries = 6)
    for ($i = 0; $i -lt $Retries; $i++) {
        try {
            [System.Windows.Forms.Clipboard]::SetText($Text)
            return $true
        }
        catch {
            Start-Sleep -Milliseconds 80
        }
    }
    throw 'the clipboard is locked by another application'
}

function Invoke-Clipboard {
    param($Req)

    $action = 'get'; if ($Req.action) { $action = [string]$Req.action }
    if ($action -eq 'get') {
        $text = Get-ClipboardText
        return @{ text = $text; length = $text.Length }
    }
    if ($action -eq 'set') {
        $text = [string]$Req.text
        [void](Set-ClipboardText -Text $text)
        # The clipboard chain is asynchronous; verify with a short poll.
        $back = ''
        for ($i = 0; $i -lt 6; $i++) {
            Start-Sleep -Milliseconds 60
            $back = Get-ClipboardText
            if ($back -eq $text) { break }
        }
        return @{ set = ($back -eq $text); length = $text.Length }
    }
    throw "unknown clipboard action: $action"
}
