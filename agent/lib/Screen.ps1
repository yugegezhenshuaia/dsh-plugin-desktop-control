# Screen.ps1 -- screenshot capture and pixel helpers.

function Get-CaptureRect {
    param([string]$Mode = 'full', [int64]$Handle = 0, $Region = $null)

    $screen = [DWin]::VirtualScreen()   # x, y, w, h
    $sx = $screen[0]; $sy = $screen[1]; $sw = $screen[2]; $sh = $screen[3]

    if ($Mode -eq 'window') {
        if ($Handle -eq 0) { $Handle = [int64][DWin]::GetForegroundWindow() }
        if ($Handle -eq 0) { throw 'no foreground window to capture' }
        $r = [DWin]::Rect([intptr]$Handle)
        $x = $r[0]; $y = $r[1]; $w = $r[2]; $h = $r[3]
    }
    elseif ($Mode -eq 'region') {
        if ($null -eq $Region) { throw 'region mode requires x, y, width, height' }
        $x = [int]$Region.x; $y = [int]$Region.y
        $w = [int]$Region.width; $h = [int]$Region.height
    }
    else {
        $x = $sx; $y = $sy; $w = $sw; $h = $sh
    }

    # Clip to the virtual desktop: CopyFromScreen cannot read outside it.
    if ($x -lt $sx) { $w = $w - ($sx - $x); $x = $sx }
    if ($y -lt $sy) { $h = $h - ($sy - $y); $y = $sy }
    if (($x + $w) -gt ($sx + $sw)) { $w = ($sx + $sw) - $x }
    if (($y + $h) -gt ($sy + $sh)) { $h = ($sy + $sh) - $y }
    if ($w -le 0 -or $h -le 0) { throw "capture rectangle is outside the screen: $x,$y ${w}x${h}" }

    return @{ x = $x; y = $y; width = $w; height = $h }
}

function New-ScreenBitmap {
    param([string]$Mode = 'full', [int64]$Handle = 0, $Region = $null, [double]$Scale = 1.0)

    $rect = Get-CaptureRect -Mode $Mode -Handle $Handle -Region $Region
    $w = [int]$rect.width; $h = [int]$rect.height
    if ($Scale -le 0) { $Scale = 1.0 }
    $dw = [int][math]::Round($w * $Scale); $dh = [int][math]::Round($h * $Scale)

    $native = New-Object System.Drawing.Bitmap($w, $h, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($native)
    $g.CopyFromScreen($rect.x, $rect.y, 0, 0, (New-Object System.Drawing.Size($w, $h)), [System.Drawing.CopyPixelOperation]::SourceCopy)
    $g.Dispose()

    if ($dw -eq $w -and $dh -eq $h) {
        return @{ bitmap = $native; originX = $rect.x; originY = $rect.y; width = $w; height = $h; scale = 1.0 }
    }

    $scaled = New-Object System.Drawing.Bitmap($dw, $dh, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g2 = [System.Drawing.Graphics]::FromImage($scaled)
    $g2.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g2.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g2.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
    $g2.DrawImage($native, 0, 0, $dw, $dh)
    $g2.Dispose()
    $native.Dispose()

    return @{ bitmap = $scaled; originX = $rect.x; originY = $rect.y; width = $dw; height = $dh; scale = $Scale }
}

function Save-ScreenBitmap {
    param($Capture, [string]$Path)

    $dir = [System.IO.Path]::GetDirectoryName($Path)
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $Capture.bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    $Capture.bitmap.Dispose()
    return @{
        path = $Path
        width = $Capture.width
        height = $Capture.height
        scale = $Capture.scale
        origin = @{ x = $Capture.originX; y = $Capture.originY }
        bytes = (Get-Item $Path).Length
    }
}

function Invoke-Screenshot {
    param($Req)
    $mode = 'full'; if ($Req.mode) { $mode = [string]$Req.mode }
    $handle = 0; if ($Req.handle) { $handle = [int64]$Req.handle }
    $scale = 1.0; if ($Req.scale) { $scale = [double]$Req.scale }
    $path = [string]$Req.path
    if ([string]::IsNullOrEmpty($path)) { throw 'screenshot requires a path' }
    $cap = New-ScreenBitmap -Mode $mode -Handle $handle -Region $Req.region -Scale $scale
    return (Save-ScreenBitmap -Capture $cap -Path $path)
}

function Invoke-Pixel {
    param($Req)
    # Average colour of a small patch, used to detect loading/spinner states cheaply.
    $cap = New-ScreenBitmap -Mode 'region' -Region @{ x = $Req.x; y = $Req.y; width = 1; height = 1 } -Scale 1
    $c = $cap.bitmap.GetPixel(0, 0)
    $cap.bitmap.Dispose()
    return @{ r = [int]$c.R; g = [int]$c.G; b = [int]$c.B; hex = ('#{0:X2}{1:X2}{2:X2}' -f $c.R, $c.G, $c.B) }
}
