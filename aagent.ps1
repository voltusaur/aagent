<#
.SYNOPSIS
    aagent - text-first agentic control of an Android device over ADB.

.DESCRIPTION
    Designed for LLM agents that cannot receive image bytes: every read verb
    returns text plus pixel coordinates, so UI state is always machine-readable.

    Resolution order when targeting an element:
      1. OCR label match (Flutter, Compose, native - works everywhere)
      2. explicit coordinate (tapxy)

.EXAMPLES
    aagent.ps1 devices
    aagent.ps1 ocr
    aagent.ps1 find "Installation method"
    aagent.ps1 tap "Install"
    aagent.ps1 scroll down --until "Installation method" --max 10
    aagent.ps1 wait "All done!" --timeout 60
    aagent.ps1 flow .\flows\example.json
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0, Mandatory = $true)]
    [string]$Command,

    [Parameter(Position = 1, ValueFromRemainingArguments = $true)]
    [string[]]$Rest
)

$ErrorActionPreference = 'Stop'

# --------------------------------------------------------------------------
# Configuration
# --------------------------------------------------------------------------
$script:WorkDir = Join-Path $env:TEMP 'aagent'
if (-not (Test-Path $script:WorkDir)) { New-Item -ItemType Directory -Path $script:WorkDir -Force | Out-Null }
$script:ShotPath = Join-Path $script:WorkDir 'last.png'

$script:Adb = (Get-Command adb -ErrorAction SilentlyContinue).Source
if (-not $script:Adb) {
    $candidate = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages\Google.PlatformTools_Microsoft.Winget.Source_8wekyb3d8bbwe\platform-tools\adb.exe'
    if (Test-Path $candidate) { $script:Adb = $candidate }
}
if (-not $script:Adb) { throw 'adb not found. Install Google.PlatformTools or add platform-tools to PATH.' }

# --------------------------------------------------------------------------
# OCR engine (Windows.Media.Ocr)
# --------------------------------------------------------------------------
Add-Type -AssemblyName System.Runtime.WindowsRuntime
$script:asTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
        $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
        $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
    })[0]

function Await-WinRt($op, $resultType) {
    $m = $script:asTaskGeneric.MakeGenericMethod($resultType)
    $task = $m.Invoke($null, @($op))
    $task.Wait(-1) | Out-Null
    $task.Result
}

[Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime] | Out-Null
[Windows.Graphics.Imaging.BitmapDecoder, Windows.Foundation, ContentType = WindowsRuntime] | Out-Null
[Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType = WindowsRuntime] | Out-Null

function Invoke-DeviceCommand {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)
    $out = & $script:Adb @Args 2>&1
    return $out
}

function Save-Screenshot {
    param([string]$Path = $script:ShotPath)
    & $env:ComSpec /c "`"$($script:Adb)`" exec-out screencap -p > `"$Path`""
    if (-not (Test-Path $Path)) { throw 'screencap failed' }
    return $Path
}

function Get-OcrLines {
    param([string]$Path)

    $file = Await-WinRt ([Windows.Storage.StorageFile]::GetFileFromPathAsync($Path)) ([Windows.Storage.StorageFile])
    $stream = Await-WinRt ($file.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])
    $decoder = Await-WinRt ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
    $bitmap = Await-WinRt ($decoder.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])

    $engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()
    if (-not $engine) { throw 'No OCR engine available for user profile languages.' }

    $result = Await-WinRt ($engine.RecognizeAsync($bitmap)) ([Windows.Media.Ocr.OcrResult])

    $lines = @()
    foreach ($line in $result.Lines) {
        if ($line.Words.Count -eq 0) { continue }
        $minX = [double]::MaxValue; $minY = [double]::MaxValue
        $maxX = 0.0; $maxY = 0.0; $words = @()
        foreach ($w in $line.Words) {
            $r = $w.BoundingRect
            if ($r.X -lt $minX) { $minX = $r.X }
            if ($r.Y -lt $minY) { $minY = $r.Y }
            if (($r.X + $r.Width) -gt $maxX) { $maxX = $r.X + $r.Width }
            if (($r.Y + $r.Height) -gt $maxY) { $maxY = $r.Y + $r.Height }
            $words += [pscustomobject]@{
                text = $w.Text
                x    = [int]($r.X + $r.Width / 2)
                y    = [int]($r.Y + $r.Height / 2)
            }
        }
        $lines += [pscustomobject]@{
            text = ($words | ForEach-Object { $_.text }) -join ' '
            x    = [int](($minX + $maxX) / 2)
            y    = [int](($minY + $maxY) / 2)
        }
    }
    return $lines
}

function Get-ScreenLines {
    $path = Save-Screenshot
    return Get-OcrLines -Path $path
}

function Find-Element {
    param(
        [string]$Pattern,
        $Lines,
        [switch]$Regex
    )

    if (-not $Lines) { $Lines = Get-ScreenLines }

    $matches = @()
    foreach ($l in $Lines) {
        $hit = $false
        if ($Regex) { $hit = [regex]::IsMatch($l.text, $Pattern, 'IgnoreCase') }
        else { $hit = $l.text.IndexOf($Pattern, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 }
        if ($hit) { $matches += $l }
    }
    if ($matches.Count -eq 0) { return $null }
    return ($matches | Sort-Object y, x | Select-Object -First 1)
}

# --------------------------------------------------------------------------
# Verbs
# --------------------------------------------------------------------------
function Show-Help {
    @'
aagent <command> [args]

  devices                          list attached devices
  shot [path]                      capture a screenshot
  ocr [--json] [--filter text]     read screen as text + coordinates
  find <text> [--json]             locate a label
  tap <text> [--retries n]         tap by label (verified)
  tapxy <x> <y>                    tap by coordinate
  type <text>                      type into the focused field
  key <KEYCODE>                    send a key event (e.g. BACK, ENTER)
  swipe <x1> <y1> <x2> <y2> [ms]   raw swipe
  scroll <up|down> [--until text] [--max n]
  wait <text> [--timeout secs]     block until text appears
  ui [--raw]                       uiautomator dump (falls back to OCR)
  start <package>                  launch an app
  stop <package>                   force-stop an app
  flow <file.json>                 run a sequence of commands
'@
}

function Invoke-Verb {
    param([string]$Name, [string[]]$Args)

    $json = $false
    $clean = @()
    foreach ($a in $Args) {
        if ($a -eq '--json') { $json = $true } else { $clean += $a }
    }

    switch ($Name) {

        'devices' {
            $out = Invoke-DeviceCommand 'devices' '-l'
            return ($out -join "`n")
        }

        'shot' {
            $p = if ($clean.Count -ge 1) { $clean[0] } else { $script:ShotPath }
            $path = Save-Screenshot -Path $p
            return "screenshot: $path"
        }

        'ocr' {
            $lines = Get-ScreenLines
            if ($clean.Count -ge 2 -and $clean[0] -eq '--filter') {
                $lines = $lines | Where-Object { $_.text -like "*$($clean[1])*" }
            }
            if ($json) {
                return ($lines | Select-Object text, x, y | ConvertTo-Json -Depth 4)
            }
            return (($lines | ForEach-Object { '{0,-45} ({1},{2})' -f $_.text, $_.x, $_.y }) -join "`n")
        }

        'find' {
            if ($clean.Count -lt 1) { throw 'find requires text' }
            $e = Find-Element -Pattern $clean[0]
            if (-not $e) { throw "not found: $($clean[0])" }
            if ($json) { return ($e | Select-Object text, x, y | ConvertTo-Json) }
            return ('{0}  -> ({1},{2})' -f $e.text, $e.x, $e.y)
        }

        'tap' {
            if ($clean.Count -lt 1) { throw 'tap requires text' }
            $retries = 3
            if ($clean -contains '--retries') {
                $i = [array]::IndexOf($clean, '--retries')
                $retries = [int]$clean[$i + 1]
            }
            for ($i = 0; $i -lt $retries; $i++) {
                $e = Find-Element -Pattern $clean[0]
                if ($e) {
                    Invoke-DeviceCommand 'shell' 'input' 'tap' $e.x $e.y | Out-Null
                    Start-Sleep -Milliseconds 700
                    return ('tapped "{0}" at ({1},{2})' -f $e.text, $e.x, $e.y)
                }
                Start-Sleep -Milliseconds 800
            }
            throw "not found after $retries attempts: $($clean[0])"
        }

        'tapxy' {
            if ($clean.Count -lt 2) { throw 'tapxy requires x y' }
            Invoke-DeviceCommand 'shell' 'input' 'tap' $clean[0] $clean[1] | Out-Null
            return "tapped ($($clean[0]),$($clean[1]))"
        }

        'type' {
            if ($clean.Count -lt 1) { throw 'type requires text' }
            $escaped = ($clean -join ' ') -replace ' ', '%s'
            Invoke-DeviceCommand 'shell' 'input' 'text' $escaped | Out-Null
            return "typed: $($clean -join ' ')"
        }

        'key' {
            if ($clean.Count -lt 1) { throw 'key requires a keycode' }
            Invoke-DeviceCommand 'shell' 'input' 'keyevent' $clean[0] | Out-Null
            return "key: $($clean[0])"
        }

        'swipe' {
            if ($clean.Count -lt 4) { throw 'swipe requires x1 y1 x2 y2 [ms]' }
            $ms = 400
            if ($clean.Count -ge 5) { $ms = [int]$clean[4] }
            Invoke-DeviceCommand 'shell' 'input' 'swipe' $clean[0] $clean[1] $clean[2] $clean[3] $ms | Out-Null
            return "swiped ($($clean[0]),$($clean[1])) -> ($($clean[2]),$($clean[3]))"
        }

        'scroll' {
            if ($clean.Count -lt 1) { throw 'scroll requires up|down' }
            $dir = $clean[0]
            $until = $null; $max = 8
            if ($clean -contains '--until') {
                $i = [array]::IndexOf($clean, '--until'); $until = $clean[$i + 1]
            }
            if ($clean -contains '--max') {
                $i = [array]::IndexOf($clean, '--max'); $max = [int]$clean[$i + 1]
            }
            for ($n = 1; $n -le $max; $n++) {
                if ($dir -eq 'down') {
                    Invoke-DeviceCommand 'shell' 'input' 'swipe' 960 900 960 380 250 | Out-Null
                }
                else {
                    Invoke-DeviceCommand 'shell' 'input' 'swipe' 960 380 960 900 250 | Out-Null
                }
                Start-Sleep -Milliseconds 800
                $lines = Get-ScreenLines
                if (-not $until) { return "scrolled $dir x$n" }
                $e = Find-Element -Pattern $until -Lines $lines
                if ($e) {
                    return ('found "{0}" at ({1},{2}) after {3} scroll(s)' -f $e.text, $e.x, $e.y, $n)
                }
            }
            throw "not found after $max scrolls: $until"
        }

        'wait' {
            if ($clean.Count -lt 1) { throw 'wait requires text' }
            $timeout = 30
            if ($clean -contains '--timeout') {
                $i = [array]::IndexOf($clean, '--timeout'); $timeout = [int]$clean[$i + 1]
            }
            $sw = [Diagnostics.Stopwatch]::StartNew()
            while ($sw.Elapsed.TotalSeconds -lt $timeout) {
                $lines = Get-ScreenLines
                $e = Find-Element -Pattern $clean[0] -Lines $lines
                if ($e) {
                    return ('appeared "{0}" at ({1},{2}) after {3:N1}s' -f $e.text, $e.x, $e.y, $sw.Elapsed.TotalSeconds)
                }
                Start-Sleep -Milliseconds 1200
            }
            throw "timeout after ${timeout}s waiting for: $($clean[0])"
        }

        'ui' {
            $tmp = '/sdcard/aagent_ui.xml'
            $dump = Invoke-DeviceCommand 'shell' 'uiautomator' 'dump' $tmp
            if (($dump -join "`n") -match 'dumped to') {
                $local = Join-Path $script:WorkDir 'ui.xml'
                Invoke-DeviceCommand 'pull' $tmp $local | Out-Null
                Invoke-DeviceCommand 'shell' 'rm' '-f' $tmp | Out-Null
                $xml = Get-Content $local -Raw
                $nodes = [regex]::Matches($xml, '<node[^>]*text="([^"]+)"[^>]*bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"')
                $result = foreach ($n in $nodes) {
                    if ($n.Groups[1].Value -eq '') { continue }
                    [pscustomobject]@{
                        text = $n.Groups[1].Value
                        x    = [int](([int]$n.Groups[2].Value + [int]$n.Groups[4].Value) / 2)
                        y    = [int](([int]$n.Groups[3].Value + [int]$n.Groups[5].Value) / 2)
                    }
                }
                if ($result) { return (($result | ForEach-Object { '{0,-45} ({1},{2})' -f $_.text, $_.x, $_.y }) -join "`n") }
            }
            return "uiautomator unavailable (Flutter/Compose); falling back to OCR:`n" + (Invoke-Verb -Name 'ocr' -Args @())
        }

        'start' {
            if ($clean.Count -lt 1) { throw 'start requires a package' }
            $out = Invoke-DeviceCommand 'shell' 'monkey' '-p' $clean[0] '-c' 'android.intent.category.LAUNCHER' '1'
            return ($out -join "`n")
        }

        'stop' {
            if ($clean.Count -lt 1) { throw 'stop requires a package' }
            Invoke-DeviceCommand 'shell' 'am' 'force-stop' $clean[0] | Out-Null
            return "stopped $($clean[0])"
        }

        'flow' {
            if ($clean.Count -lt 1) { throw 'flow requires a json file' }
            $steps = Get-Content $clean[0] -Raw | ConvertFrom-Json
            $log = @()
            foreach ($s in $steps) {
                $argList = @()
                if ($s.args) { $argList = @($s.args | ForEach-Object { [string]$_ }) }
                try {
                    $r = Invoke-Verb -Name $s.cmd -Args $argList
                    $log += "[ok]   $($s.cmd) $($argList -join ' ') -> $r"
                }
                catch {
                    $log += "[fail] $($s.cmd) $($argList -join ' ') -> $($_.Exception.Message)"
                    if ($s.stopOnFail -ne $false) { return ($log -join "`n") }
                }
            }
            return ($log -join "`n")
        }

        default { return (Show-Help) }
    }
}

try {
    $result = Invoke-Verb -Name $Command -Args $Rest
    if ($null -ne $result) { $result }
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
