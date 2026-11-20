# Uia.ps1 -- UI Automation access for apps that expose an accessibility tree.

$script:UiaReady = $false

function Initialize-Uia {
    if ($script:UiaReady) { return }
    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes
    Add-Type -AssemblyName WindowsBase
    $script:UiaReady = $true
}

function Get-UiaFromHandle {
    param([int64]$Handle)
    Initialize-Uia
    $h = [intptr]$Handle
    if ($Handle -eq 0) { return [System.Windows.Automation.AutomationElement]::RootElement }
    if (-not [DWin]::IsAlive($h)) { throw "window handle $Handle no longer exists" }
    return [System.Windows.Automation.AutomationElement]::FromHandle($h)
}

function Get-RectSafe {
    param($Rect)
    if ([double]::IsInfinity($Rect.X) -or [double]::IsNaN($Rect.X)) { return @{ x = 0; y = 0; width = 0; height = 0 } }
    return @{ x = [int]$Rect.X; y = [int]$Rect.Y; width = [int]$Rect.Width; height = [int]$Rect.Height }
}

function Get-UiaPatternNames {
    param($Element)
    $names = New-Object System.Collections.ArrayList
    try {
        foreach ($p in $Element.GetSupportedPatterns()) {
            $name = $p.ProgrammaticName -replace 'PatternIdentifiers\.Pattern$', ''
            [void]$names.Add($name)
        }
    }
    catch { }
    return $names.ToArray()
}

function Get-UiaValue {
    param($Element)
    try {
        $pattern = $Element.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
        return $pattern.Current.Value
    }
    catch { return $null }
}

function Get-UiaNodeInfo {
    param($Element, [string]$Path, [int]$Depth)

    $c = $Element.Current
    $info = @{
        path = $Path
        depth = $Depth
        name = [string]$c.Name
        type = ($c.ControlType.ProgrammaticName -replace 'ControlType\.', '')
        automationId = [string]$c.AutomationId
        className = [string]$c.ClassName
        rect = (Get-RectSafe $c.BoundingRectangle)
        enabled = [bool]$c.IsEnabled
        offscreen = [bool]$c.IsOffscreen
        patterns = (Get-UiaPatternNames -Element $Element)
    }
    $value = Get-UiaValue -Element $Element
    if ($null -ne $value -and $value -ne '') { $info.value = [string]$value }
    return $info
}

function Invoke-UiaTree {
    param([int64]$Handle, [int]$MaxDepth = 6, [int]$MaxNodes = 400)

    $root = Get-UiaFromHandle -Handle $Handle
    $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
    $list = New-Object System.Collections.ArrayList
    $truncated = $false

    # Iterative depth-first walk with an explicit stack: recursion would blow up
    # on deep Chromium trees.
    $stack = New-Object System.Collections.Stack
    $stack.Push(@{ el = $root; path = ''; depth = 0 })
    while ($stack.Count -gt 0) {
        $item = $stack.Pop()
        if ($list.Count -ge $MaxNodes) { $truncated = $true; break }
        [void]$list.Add((Get-UiaNodeInfo -Element $item.el -Path $item.path -Depth $item.depth))
        if ($item.depth -ge $MaxDepth) { continue }
        $children = New-Object System.Collections.ArrayList
        try {
            $child = $walker.GetFirstChild($item.el)
            while ($null -ne $child) {
                [void]$children.Add($child)
                $child = $walker.GetNextSibling($child)
                if ($children.Count -gt 200) { break }
            }
        }
        catch { }
        for ($i = $children.Count - 1; $i -ge 0; $i--) {
            $childPath = if ($item.path -eq '') { [string]$i } else { "$($item.path)/$i" }
            $stack.Push(@{ el = $children[$i]; path = $childPath; depth = ($item.depth + 1) })
        }
    }
    return @{ handle = $Handle; count = $list.Count; truncated = $truncated; nodes = $list.ToArray() }
}

function Resolve-UiaPath {
    param($Root, [string]$Path)

    if ([string]::IsNullOrEmpty($Path)) { return $Root }
    $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
    $current = $Root
    foreach ($segment in $Path.Split('/')) {
        if ($segment -eq '') { continue }
        $index = [int]$segment
        $child = $walker.GetFirstChild($current)
        $i = 0
        while ($null -ne $child -and $i -lt $index) {
            $child = $walker.GetNextSibling($child)
            $i++
        }
        if ($null -eq $child) { throw "UI Automation path $Path is stale; take a new tree dump" }
        $current = $child
    }
    return $current
}

function Invoke-UiaFind {
    param([int64]$Handle, [string]$Name, [string]$ControlType, [int]$MaxNodes = 3000, [bool]$Exact = $false)

    $root = Get-UiaFromHandle -Handle $Handle
    $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
    $matches = New-Object System.Collections.ArrayList
    $visited = 0

    $stack = New-Object System.Collections.Stack
    $stack.Push(@{ el = $root; path = ''; depth = 0 })
    while ($stack.Count -gt 0 -and $visited -lt $MaxNodes) {
        $item = $stack.Pop()
        $visited++
        $info = Get-UiaNodeInfo -Element $item.el -Path $item.path -Depth $item.depth
        $okName = $true
        if (-not [string]::IsNullOrEmpty($Name)) {
            if ($Exact) { $okName = ($info.name -ieq $Name) }
            else { $okName = ($info.name -ine '' -and $info.name.IndexOf($Name, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) }
        }
        $okType = $true
        if (-not [string]::IsNullOrEmpty($ControlType)) { $okType = ($info.type -ieq $ControlType) }
        if ($okName -and $okType -and ($Name -ne '' -or $ControlType -ne '')) {
            $info.cx = $info.rect.x + [int]($info.rect.width / 2)
            $info.cy = $info.rect.y + [int]($info.rect.height / 2)
            [void]$matches.Add($info)
            if ($matches.Count -ge 20) { break }
        }
        $children = New-Object System.Collections.ArrayList
        try {
            $child = $walker.GetFirstChild($item.el)
            while ($null -ne $child) {
                [void]$children.Add($child)
                $child = $walker.GetNextSibling($child)
                if ($children.Count -gt 200) { break }
            }
        }
        catch { }
        for ($i = $children.Count - 1; $i -ge 0; $i--) {
            $childPath = if ($item.path -eq '') { [string]$i } else { "$($item.path)/$i" }
            $stack.Push(@{ el = $children[$i]; path = $childPath; depth = ($item.depth + 1) })
        }
    }
    return @{ handle = $Handle; visited = $visited; count = $matches.Count; matches = $matches.ToArray() }
}

function Invoke-UiaAction {
    param($Req)

    $action = 'tree'; if ($Req.action) { $action = [string]$Req.action }
    $handle = 0; if ($null -ne $Req.handle) { $handle = [int64]$Req.handle }

    if ($handle -eq 0) {
        $target = Find-WindowTarget -Handle 0 -Title ([string]$Req.title) -ProcessName ([string]$Req.process)
        $handle = [int64]$target.handle
    }

    switch ($action) {
        'tree' {
            $depth = 6; if ($Req.depth) { $depth = [int]$Req.depth }
            $nodes = 400; if ($Req.maxNodes) { $nodes = [int]$Req.maxNodes }
            return (Invoke-UiaTree -Handle $handle -MaxDepth $depth -MaxNodes $nodes)
        }
        'find' {
            $exact = $false; if ($Req.exact -eq $true) { $exact = $true }
            $nodes = 3000; if ($Req.maxNodes) { $nodes = [int]$Req.maxNodes }
            $controlType = [string]$Req.controlType
            $result = Invoke-UiaFind -Handle $handle -Name ([string]$Req.name) -ControlType $controlType -MaxNodes $nodes -Exact $exact
            # Applications that expose accessibility through the MSAA bridge report
            # every control as Pane: retry by name so a wrong type hint still helps.
            if ($result.count -eq 0 -and -not [string]::IsNullOrEmpty($controlType)) {
                $retry = Invoke-UiaFind -Handle $handle -Name ([string]$Req.name) -ControlType '' -MaxNodes $nodes -Exact $exact
                if ($retry.count -gt 0) {
                    $retry | Add-Member -NotePropertyName typeFilterIgnored -NotePropertyValue $true
                    return $retry
                }
            }
            return $result
        }
        'invoke' {
            $root = Get-UiaFromHandle -Handle $handle
            $el = Resolve-UiaPath -Root $root -Path ([string]$Req.path)
            $info = Get-UiaNodeInfo -Element $el -Path ([string]$Req.path) -Depth 0
            try {
                $p = $el.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
                $p.Invoke()
                return @{ invoked = 'InvokePattern'; element = $info }
            }
            catch {
                $cx = $info.rect.x + [int]($info.rect.width / 2)
                $cy = $info.rect.y + [int]($info.rect.height / 2)
                if ($info.rect.width -gt 0 -and $info.rect.height -gt 0) {
                    [void][DWin]::Activate([intptr]$handle)
                    Start-Sleep -Milliseconds 100
                    [void][DWin]::MoveTo($cx, $cy)
                    Start-Sleep -Milliseconds 40
                    [DWin]::Button($true, 'left'); Start-Sleep -Milliseconds 30; [DWin]::Button($false, 'left')
                    return @{ invoked = 'mouse'; element = $info; x = $cx; y = $cy }
                }
                throw "element at path $($Req.path) supports no invoke pattern and has no clickable rect"
            }
        }
        'set_value' {
            $root = Get-UiaFromHandle -Handle $handle
            $el = Resolve-UiaPath -Root $root -Path ([string]$Req.path)
            $p = $el.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
            $p.SetValue([string]$Req.value)
            return @{ set = $true; element = (Get-UiaNodeInfo -Element $el -Path ([string]$Req.path) -Depth 0) }
        }
        'focus' {
            $root = Get-UiaFromHandle -Handle $handle
            $el = Resolve-UiaPath -Root $root -Path ([string]$Req.path)
            $el.SetFocus()
            return @{ focused = $true; element = (Get-UiaNodeInfo -Element $el -Path ([string]$Req.path) -Depth 0) }
        }
        'text' {
            $root = Get-UiaFromHandle -Handle $handle
            $el = Resolve-UiaPath -Root $root -Path ([string]$Req.path)
            $p = $el.GetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern)
            $text = $p.DocumentRange.GetText(-1)
            return @{ text = $text; length = $text.Length }
        }
        default { throw "unknown uia action: $action" }
    }
}
