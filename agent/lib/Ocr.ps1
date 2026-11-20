# Ocr.ps1 -- Windows.Media.Ocr wrapper (offline, no extra downloads).

$script:OcrReady = $false
$script:OcrAsTask = $null
$script:OcrEngines = @{}

function Initialize-Ocr {
    if ($script:OcrReady) { return }
    Add-Type -AssemblyName System.Runtime.WindowsRuntime
    [Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType = WindowsRuntime] | Out-Null
    [Windows.Globalization.Language, Windows.Foundation, ContentType = WindowsRuntime] | Out-Null
    [Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime] | Out-Null
    [Windows.Graphics.Imaging.BitmapDecoder, Windows.Graphics.Imaging, ContentType = WindowsRuntime] | Out-Null
    [Windows.Storage.Streams.IRandomAccessStream, Windows.Storage.Streams, ContentType = WindowsRuntime] | Out-Null
    [Windows.Graphics.Imaging.SoftwareBitmap, Windows.Graphics.Imaging, ContentType = WindowsRuntime] | Out-Null
    [Windows.Media.Ocr.OcrResult, Windows.Foundation, ContentType = WindowsRuntime] | Out-Null
    $script:OcrAsTask = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
            $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
            $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
        })[0]
    if (-not $script:OcrAsTask) { throw 'WindowsRuntimeSystemExtensions.AsTask is unavailable' }
    $script:OcrReady = $true
}

function Wait-WinRt {
    param($Operation, [Type]$ResultType)
    $m = $script:OcrAsTask.MakeGenericMethod($ResultType)
    $task = $m.Invoke($null, @($Operation))
    $task.Wait(-1) | Out-Null
    return $task.Result
}

function Get-OcrLanguages {
    Initialize-Ocr
    return @([Windows.Media.Ocr.OcrEngine]::AvailableRecognizerLanguages | ForEach-Object { $_.LanguageTag })
}

function Get-OcrEngine {
    param([string]$Language)
    Initialize-Ocr
    if (-not [string]::IsNullOrEmpty($Language)) {
        if ($script:OcrEngines.ContainsKey($Language)) { return $script:OcrEngines[$Language] }
        $lang = New-Object Windows.Globalization.Language $Language
        $engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromLanguage($lang)
        if (-not $engine) { throw "OCR language is not installed: $Language" }
        $script:OcrEngines[$Language] = $engine
        return $engine
    }
    if ($script:OcrEngines.ContainsKey('__default')) { return $script:OcrEngines['__default'] }
    $engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()
    if (-not $engine) {
        $available = @([Windows.Media.Ocr.OcrEngine]::AvailableRecognizerLanguages)
        if ($available.Count -eq 0) { throw 'no OCR recognizer language is installed on this Windows' }
        $engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromLanguage($available[0])
    }
    $script:OcrEngines['__default'] = $engine
    return $engine
}

# Collapse the spaces Windows OCR inserts between CJK characters while keeping
# word breaks in Latin text.
function Format-OcrText {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $cjk = '[\u2E80-\u9FFF\u3000-\u303F\uFF00-\uFFEF]'
    return [regex]::Replace($Text, "(?<=$cjk)\s+(?=$cjk)", '')
}

function Read-OcrFile {
    param([string]$Path, [string]$Language)

    Initialize-Ocr
    $engine = Get-OcrEngine -Language $Language
    $full = [System.IO.Path]::GetFullPath($Path)
    $file = Wait-WinRt ([Windows.Storage.StorageFile]::GetFileFromPathAsync($full)) ([Windows.Storage.StorageFile])
    $stream = Wait-WinRt ($file.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])
    try {
        $decoder = Wait-WinRt ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
        $bitmap = Wait-WinRt ($decoder.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
        $result = Wait-WinRt ($engine.RecognizeAsync($bitmap)) ([Windows.Media.Ocr.OcrResult])
        return $result
    }
    finally {
        $stream.Dispose()
    }
}

function Invoke-Ocr {
    param($Req)

    $language = ''
    if ($Req.lang) { $language = [string]$Req.lang }
    $scale = 2.0
    if ($Req.scale) { $scale = [double]$Req.scale }
    $withWords = $false
    if ($Req.words -eq $true) { $withWords = $true }
    $minLength = 1
    if ($Req.minLength) { $minLength = [int]$Req.minLength }

    $tempFile = $null
    $originX = 0; $originY = 0; $scaleInv = 1.0

    try {
        if ($Req.path) {
            $path = [string]$Req.path
            # Coordinates come from the caller's own image: origin stays 0,0 and
            # the caller maps them because it knows how the image was captured.
            if ($Req.originX) { $originX = [int]$Req.originX }
            if ($Req.originY) { $originY = [int]$Req.originY }
            $imageScale = 1.0
            if ($Req.imageScale) { $imageScale = [double]$Req.imageScale }
            # Upscale an existing image before recognition: small UI text needs it.
            if ($scale -ne 1) {
                $source = [System.Drawing.Image]::FromFile($path)
                try {
                    $sw2 = [int][math]::Round($source.Width * $scale)
                    $sh2 = [int][math]::Round($source.Height * $scale)
                    $big = New-Object System.Drawing.Bitmap($sw2, $sh2, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
                    $bg = [System.Drawing.Graphics]::FromImage($big)
                    $bg.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                    $bg.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
                    $bg.DrawImage($source, 0, 0, $sw2, $sh2)
                    $bg.Dispose()
                }
                finally {
                    $source.Dispose()
                }
                $scaledPath = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), ('dsh-ocr-s-' + [guid]::NewGuid().ToString('N') + '.png'))
                $big.Save($scaledPath, [System.Drawing.Imaging.ImageFormat]::Png)
                $big.Dispose()
                $path = $scaledPath
                $tempFile = $scaledPath
            }
            $scaleInv = 1.0 / ($imageScale * $scale)
        }
        else {
            $mode = 'full'
            if ($Req.mode) { $mode = [string]$Req.mode }
            $handle = 0; if ($Req.handle) { $handle = [int64]$Req.handle }
            $cap = New-ScreenBitmap -Mode $mode -Handle $handle -Region $Req.region -Scale $scale
            $path = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), ('dsh-ocr-' + [guid]::NewGuid().ToString('N') + '.png'))
            $cap.bitmap.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
            $originX = $cap.originX
            $originY = $cap.originY
            $scaleInv = 1.0 / $cap.scale
            $cap.bitmap.Dispose()
            $tempFile = $path
        }

        $result = Read-OcrFile -Path $path -Language $language
        $engine = Get-OcrEngine -Language $language
        $lines = New-Object System.Collections.ArrayList
        foreach ($line in @($result.Lines)) {
            $words = @($line.Words)
            if ($words.Count -eq 0) { continue }
            $x1 = [double]::MaxValue; $y1 = [double]::MaxValue; $x2 = 0.0; $y2 = 0.0
            $wordList = New-Object System.Collections.ArrayList
            foreach ($w in $words) {
                $wr = $w.BoundingRect
                if ($wr.X -lt $x1) { $x1 = $wr.X }
                if ($wr.Y -lt $y1) { $y1 = $wr.Y }
                if (($wr.X + $wr.Width) -gt $x2) { $x2 = $wr.X + $wr.Width }
                if (($wr.Y + $wr.Height) -gt $y2) { $y2 = $wr.Y + $wr.Height }
                if ($withWords) {
                    [void]$wordList.Add(@{
                            text = $w.Text
                            x = [int][math]::Round($originX + $wr.X * $scaleInv)
                            y = [int][math]::Round($originY + $wr.Y * $scaleInv)
                            width = [int][math]::Round($wr.Width * $scaleInv)
                            height = [int][math]::Round($wr.Height * $scaleInv)
                        })
                }
            }
            $raw = [string]$line.Text
            if ($raw.Length -lt $minLength) { continue }
            $entry = @{
                text = (Format-OcrText $raw)
                raw = $raw
                x = [int][math]::Round($originX + $x1 * $scaleInv)
                y = [int][math]::Round($originY + $y1 * $scaleInv)
                width = [int][math]::Round(($x2 - $x1) * $scaleInv)
                height = [int][math]::Round(($y2 - $y1) * $scaleInv)
                cx = [int][math]::Round($originX + (($x1 + $x2) / 2) * $scaleInv)
                cy = [int][math]::Round($originY + (($y1 + $y2) / 2) * $scaleInv)
            }
            if ($withWords) { $entry.words = $wordList.ToArray() }
            [void]$lines.Add((New-Object psobject -Property $entry))
        }

        $sorted = @($lines | Sort-Object -Property y, x)
        $text = ($sorted | ForEach-Object { $_.text }) -join "`n"
        return @{
            language = $engine.RecognizerLanguage.LanguageTag
            lines = $sorted
            text = $text
            count = $sorted.Count
            origin = @{ x = $originX; y = $originY }
        }
    }
    finally {
        if ($tempFile -and (Test-Path $tempFile)) { Remove-Item $tempFile -Force -ErrorAction SilentlyContinue }
    }
}
