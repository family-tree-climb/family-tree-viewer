<#
  Compare-Trees.ps1
  -----------------
  Proves that two versions of the program build exactly the same family tree from the same data.

  It loads one data.js twice in headless Chrome: once with the program in -BaseDir and once with the
  program in -NewDir (each with its own config.js, genealogy.js and render.js, plus a family-settings.js
  when that version uses one). Each side prints a complete fingerprint of the model it built (every
  person, every document, every Notes item, the aliases, the order of things; see compare-trees.js), and
  the two fingerprints are compared line by line.

  Usage (Windows PowerShell 5.1):
    powershell -NoProfile -ExecutionPolicy Bypass -File tests\Compare-Trees.ps1 `
        -Data <data.js> -BaseDir <old program folder> -NewDir <new program folder> `
        [-BaseSettings auto|none|<file>] [-NewSettings auto|none|<file>] [-Out <folder>] [-Chrome <chrome.exe>]

    -Data          a data.js written by tools\Update-FamilyTree.ps1 (window.FAMILY_DATA). Only read.
    -BaseDir       the folder that holds the old program (index.html, app\config.js, app\genealogy.js, app\render.js)
    -NewDir        the folder that holds the new program
    -BaseSettings  the family-settings.js loaded before the old config.js:
                     auto (default) = <BaseDir>\family-settings.js when it exists, otherwise none
                     none           = no settings file (programs before 1.0 kept everything in app\config.js)
                     <file>         = this file
    -NewSettings   the same for the new program
    -Out           folder for the results (created if needed). Default: a new folder under %TEMP%.
                   Written there: base.txt and new.txt (the two fingerprints), report.txt, and Chrome's
                   throwaway profiles (deleted again at the end).
    -Chrome        chrome.exe; default: looked up in Program Files, Program Files (x86) and Local AppData
    -ShowDiffs     how many differing items to show in detail (default 10)

  Exit code: 0 = the two trees are identical, 1 = they differ, 2 = the comparison could not be run.

  Nothing is written anywhere except inside -Out. The program folders and the data file are only read.
#>
param(
  [Parameter(Mandatory = $true)][string]$Data,
  [Parameter(Mandatory = $true)][string]$BaseDir,
  [Parameter(Mandatory = $true)][string]$NewDir,
  [string]$BaseSettings = 'auto',
  [string]$NewSettings = 'auto',
  [string]$Out = '',
  [string]$Chrome = '',
  [int]$ShowDiffs = 10,
  [int]$TimeoutSec = 300,
  [switch]$Quiet
)
$ErrorActionPreference = 'Stop'

function Say([string]$msg) { if (-not $Quiet) { Write-Host $msg } }
function Fail([string]$msg) { Write-Host "COMPARE ERROR: $msg"; exit 2 }

# ---------- inputs
$TestsDir = [IO.Path]::GetFullPath($PSScriptRoot)
$PageFile = Join-Path $TestsDir 'compare-trees.html'
if (-not [IO.File]::Exists($PageFile) -or -not [IO.File]::Exists((Join-Path $TestsDir 'compare-trees.js'))) { Fail "compare-trees.html / compare-trees.js are missing next to this script ($TestsDir)" }

$DataFull = [IO.Path]::GetFullPath($Data)
if (-not [IO.File]::Exists($DataFull)) { Fail "data file not found: $DataFull" }

function Get-Side([string]$label, [string]$dir, [string]$settings) {
  $full = [IO.Path]::GetFullPath($dir).TrimEnd('\')
  foreach ($f in @('app\config.js', 'app\genealogy.js', 'app\render.js')) {
    if (-not [IO.File]::Exists((Join-Path $full $f))) { Fail "$label program folder has no $f ($full)" }
  }
  $set = ''
  if (-not $settings -or $settings -eq 'auto') {
    $cand = Join-Path $full 'family-settings.js'
    if ([IO.File]::Exists($cand)) { $set = $cand }
  } elseif ($settings -ne 'none') {
    $set = [IO.Path]::GetFullPath($settings)
    if (-not [IO.File]::Exists($set)) { Fail "$label settings file not found: $set" }
  }
  $ver = Join-Path $full 'app\version.js'
  if (-not [IO.File]::Exists($ver)) { $ver = '' }
  return @{ Label = $label; Dir = $full; Settings = $set; Version = $ver }
}
$sides = @((Get-Side 'base' $BaseDir $BaseSettings), (Get-Side 'new' $NewDir $NewSettings))

if (-not $Chrome) {
  foreach ($c in @(
      (Join-Path $env:ProgramFiles 'Google\Chrome\Application\chrome.exe'),
      (Join-Path ${env:ProgramFiles(x86)} 'Google\Chrome\Application\chrome.exe'),
      (Join-Path $env:LOCALAPPDATA 'Google\Chrome\Application\chrome.exe'))) {
    if ($c -and [IO.File]::Exists($c)) { $Chrome = $c; break }
  }
}
if (-not $Chrome -or -not [IO.File]::Exists($Chrome)) { Fail 'Google Chrome was not found (give its path with -Chrome)' }

if (-not $Out) { $Out = Join-Path $env:TEMP ('FamilyTree-CompareTrees-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + ('{0:x4}' -f (Get-Random -Maximum 65536))) }
$OutFull = [IO.Path]::GetFullPath($Out).TrimEnd('\')
if (-not [IO.Directory]::Exists($OutFull)) { [void][IO.Directory]::CreateDirectory($OutFull) }

# every file this script writes or deletes must be inside -Out
function Assert-InsideOut([string]$p) {
  $f = [IO.Path]::GetFullPath($p)
  if (-not $f.StartsWith($OutFull + '\', [StringComparison]::OrdinalIgnoreCase)) { throw "SAFETY STOP: $f is outside $OutFull" }
  return $f
}
function Write-Utf8([string]$path, [string]$text) {
  [IO.File]::WriteAllText((Assert-InsideOut $path), $text, (New-Object System.Text.UTF8Encoding($false)))
}
function Remove-OurFolder([string]$path) {
  $full = Assert-InsideOut $path
  $long = '\\?\' + $full          # Chrome's profile can hold paths longer than 260 characters
  for ($k = 0; $k -lt 6; $k++) {
    try { if ([IO.Directory]::Exists($long)) { [IO.Directory]::Delete($long, $true) }; return } catch { Start-Sleep -Milliseconds 500 }
  }
  Write-Warning "could not remove $full"
}
function Remove-OurFile([string]$path) {
  $full = Assert-InsideOut $path
  try { if ([IO.File]::Exists($full)) { [IO.File]::Delete($full) } } catch { }
}
function To-FileUrl([string]$p) {
  $f = [IO.Path]::GetFullPath($p)
  $parts = $f.Split('\')
  $enc = @($parts[0])
  for ($i = 1; $i -lt $parts.Length; $i++) { $enc += [Uri]::EscapeDataString($parts[$i]) }
  return 'file:///' + ($enc -join '/')
}
function Read-Shared([string]$p) {
  $fs = New-Object IO.FileStream($p, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
  try { $sr = New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8); return $sr.ReadToEnd() } finally { $fs.Dispose() }
}
function Quote-Arg([string]$a) { if ($a -match '[\s"]') { return '"' + $a.Replace('"', '\"') + '"' } return $a }

# ---------- one side: headless Chrome prints the fingerprint
function Get-Fingerprint($side) {
  $q = New-Object System.Collections.Generic.List[string]
  if ($side.Settings) { $q.Add('settings=' + [Uri]::EscapeDataString((To-FileUrl $side.Settings))) }
  $q.Add('config=' + [Uri]::EscapeDataString((To-FileUrl (Join-Path $side.Dir 'app\config.js'))))
  if ($side.Version) { $q.Add('version=' + [Uri]::EscapeDataString((To-FileUrl $side.Version))) }
  $q.Add('data=' + [Uri]::EscapeDataString((To-FileUrl $DataFull)))
  $q.Add('genealogy=' + [Uri]::EscapeDataString((To-FileUrl (Join-Path $side.Dir 'app\genealogy.js'))))
  $q.Add('render=' + [Uri]::EscapeDataString((To-FileUrl (Join-Path $side.Dir 'app\render.js'))))
  $url = (To-FileUrl $PageFile) + '?' + ($q -join '&')

  $tag = $side.Label + '-' + ('{0:x6}' -f (Get-Random -Maximum 16777216))
  $profileDir = Assert-InsideOut (Join-Path $OutFull "chrome-$tag")
  $domFile = Assert-InsideOut (Join-Path $OutFull "$($side.Label).dom.html")
  $errFile = Assert-InsideOut (Join-Path $OutFull "$($side.Label).chrome-err.txt")
  $chromeArgs = @('--headless=new', '--disable-gpu', '--no-first-run', '--no-default-browser-check', '--disable-extensions',
    '--disable-background-networking', '--disable-component-update', '--disable-sync', '--disable-default-apps', '--no-pings',
    '--disable-domain-reliability', "--user-data-dir=$profileDir", '--virtual-time-budget=5000',
    '--allow-file-access-from-files', '--dump-dom', $url) | ForEach-Object { Quote-Arg $_ }
  $proc = Start-Process -FilePath $Chrome -ArgumentList $chromeArgs -PassThru -WindowStyle Hidden -RedirectStandardOutput $domFile -RedirectStandardError $errFile
  $finished = $proc.WaitForExit($TimeoutSec * 1000)
  if (-not $finished) { & taskkill.exe /T /F /PID $proc.Id | Out-Null }
  # Chrome's helper processes can stay a moment longer: wait for the ones using our own profile folder
  for ($k = 0; $k -lt 40; $k++) {
    $left = @(Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" -ErrorAction SilentlyContinue |
      Where-Object { $_.CommandLine -and $_.CommandLine.IndexOf($profileDir, [StringComparison]::OrdinalIgnoreCase) -ge 0 })
    if ($left.Count -eq 0) { break }
    if ($k -eq 39) { foreach ($p in $left) { try { Stop-Process -Id ([int]$p.ProcessId) -Force -ErrorAction Stop } catch { } } }
    else { Start-Sleep -Milliseconds 500 }
  }
  Remove-OurFolder $profileDir
  if (-not $finished) { return "ERROR`tChrome did not finish within $TimeoutSec s" }

  $dom = ''
  if ([IO.File]::Exists($domFile)) { $dom = Read-Shared $domFile }
  $m = [regex]::Match($dom, '<pre id="out">([^<]*)</pre>')
  if (-not $m.Success) {
    $err = ''
    if ([IO.File]::Exists($errFile)) { $err = Read-Shared $errFile }
    if ($err.Length -gt 1500) { $err = $err.Substring($err.Length - 1500) }
    return "ERROR`tno <pre id=""out""> in Chrome's output ($($dom.Length) characters). Chrome said: $err"
  }
  Remove-OurFile $domFile
  Remove-OurFile $errFile
  return [System.Net.WebUtility]::HtmlDecode($m.Groups[1].Value)
}

$t0 = Get-Date
$texts = @{}
foreach ($s in $sides) {
  Say ("Building the tree with the {0} program: {1}{2}" -f $s.Label, $s.Dir, $(if ($s.Settings) { " (settings: $($s.Settings))" } else { ' (no settings file)' }))
  $txt = Get-Fingerprint $s
  Write-Utf8 (Join-Path $OutFull "$($s.Label).txt") $txt
  if ($txt.StartsWith('ERROR') -or $txt -eq 'running') { Fail ("the {0} program could not build the tree: {1}" -f $s.Label, $(if ($txt.Length -gt 2000) { $txt.Substring(0, 2000) } else { $txt })) }
  $texts[$s.Label] = $txt
}

# ---------- compare
function Split-Items([string]$text) {
  $items = New-Object 'System.Collections.Generic.Dictionary[string,string]'
  $order = New-Object System.Collections.Generic.List[string]
  $infoLines = New-Object System.Collections.Generic.List[string]
  $endCount = -1
  foreach ($line in ($text -split "\r?\n")) {          # Chrome's output on Windows ends its lines with CR LF
    if (-not $line) { continue }
    if ($line.StartsWith('#')) {
      if ($line -match '^#END\t(\d+)$') { $endCount = [int]$Matches[1] } else { $infoLines.Add($line) }
      continue
    }
    $a = $line.IndexOf("`t"); $b = if ($a -ge 0) { $line.IndexOf("`t", $a + 1) } else { -1 }
    if ($b -lt 0) { $id = $line; $val = '' } else { $id = $line.Substring(0, $b); $val = $line.Substring($b + 1) }
    if ($items.ContainsKey($id)) { $id = $id + "`t(duplicate " + $order.Count + ')' }
    $items[$id] = $val
    $order.Add($id)
  }
  return @{ Items = $items; Order = $order; Info = $infoLines; End = $endCount }
}
function Get-Sha([string]$text) {
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try { return (($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($text)) | ForEach-Object { $_.ToString('x2') }) -join '') } finally { $sha.Dispose() }
}
function Show-Around([string]$a, [string]$b) {
  $n = [Math]::Min($a.Length, $b.Length); $i = 0
  while ($i -lt $n -and $a[$i] -ceq $b[$i]) { $i++ }
  $from = [Math]::Max(0, $i - 120)
  $cut = { param($s) $len = [Math]::Min(300, $s.Length - $from); if ($len -le 0) { return '(ends here)' }; $s.Substring($from, $len) }
  return @("      at character $i", ('      base: ...' + (& $cut $a)), ('      new:  ...' + (& $cut $b)))
}

$FpBase = Split-Items $texts['base']
$FpNew = Split-Items $texts['new']
$report = New-Object System.Collections.Generic.List[string]
$report.Add('Tree comparison  ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
$report.Add("data:  $DataFull")
foreach ($s in $sides) { $report.Add(("{0,-5} program: {1}   settings: {2}" -f $s.Label, $s.Dir, $(if ($s.Settings) { $s.Settings } else { '(none)' }))) }
foreach ($pair in @(@('base', $FpBase), @('new', $FpNew))) { foreach ($l in $pair[1].Info) { $report.Add(("{0,-5} {1}" -f $pair[0], $l)) } }

$problems = 0
foreach ($pair in @(@('base', $FpBase), @('new', $FpNew))) {
  if ($pair[1].End -ne $pair[1].Order.Count) { $report.Add("$($pair[0]): the fingerprint is incomplete (#END says $($pair[1].End), found $($pair[1].Order.Count) items)"); $problems++ }
}

# per kind: how many items, how many differ
$kinds = [ordered]@{}
foreach ($id in (@($FpBase.Order) + @($FpNew.Order))) { $k = $id.Split("`t")[0]; if (-not $kinds.Contains($k)) { $kinds[$k] = @{ base = 0; new = 0; changed = 0; missing = 0; extra = 0 } } }
foreach ($id in $FpBase.Order) { $kinds[$id.Split("`t")[0]].base++ }
foreach ($id in $FpNew.Order) { $kinds[$id.Split("`t")[0]].new++ }
$changed = New-Object System.Collections.Generic.List[string]
$missing = New-Object System.Collections.Generic.List[string]
$extra = New-Object System.Collections.Generic.List[string]
foreach ($id in $FpBase.Order) {
  if (-not $FpNew.Items.ContainsKey($id)) { $missing.Add($id); $kinds[$id.Split("`t")[0]].missing++ }
  elseif (-not [string]::Equals($FpBase.Items[$id], $FpNew.Items[$id], [StringComparison]::Ordinal)) { $changed.Add($id); $kinds[$id.Split("`t")[0]].changed++ }
}
foreach ($id in $FpNew.Order) { if (-not $FpBase.Items.ContainsKey($id)) { $extra.Add($id); $kinds[$id.Split("`t")[0]].extra++ } }
$sameOrder = ($FpBase.Order.Count -eq $FpNew.Order.Count)
if ($sameOrder) { for ($i = 0; $i -lt $FpBase.Order.Count; $i++) { if ($FpBase.Order[$i] -ne $FpNew.Order[$i]) { $sameOrder = $false; break } } }

$report.Add('')
$report.Add('kind        base     new  changed  missing  extra')
foreach ($k in $kinds.Keys) {
  $c = $kinds[$k]
  $report.Add(("{0,-8} {1,7} {2,7} {3,8} {4,8} {5,6}" -f $k, $c.base, $c.new, $c.changed, $c.missing, $c.extra))
}
$compA = ($FpBase.Order | ForEach-Object { $_ + "`t" + $FpBase.Items[$_] }) -join "`n"
$compB = ($FpNew.Order | ForEach-Object { $_ + "`t" + $FpNew.Items[$_] }) -join "`n"
$shaA = Get-Sha $compA; $shaB = Get-Sha $compB
$report.Add('')
$report.Add("fingerprint base: $shaA")
$report.Add("fingerprint new:  $shaB")
if (-not $sameOrder) { $report.Add('the items come in a different order'); $problems++ }

$shown = 0
foreach ($id in $changed) {
  if ($shown -ge $ShowDiffs) { break }
  $shown++
  $report.Add("  CHANGED  $($id.Replace("`t", ' '))")
  foreach ($l in (Show-Around $FpBase.Items[$id] $FpNew.Items[$id])) { $report.Add($l) }
}
foreach ($id in @($missing | Select-Object -First $ShowDiffs)) { $report.Add("  ONLY IN BASE  $($id.Replace("`t", ' '))") }
foreach ($id in @($extra | Select-Object -First $ShowDiffs)) { $report.Add("  ONLY IN NEW   $($id.Replace("`t", ' '))") }

$identical = ($problems -eq 0 -and $changed.Count -eq 0 -and $missing.Count -eq 0 -and $extra.Count -eq 0 -and $shaA -eq $shaB)
$report.Add('')
if ($identical) {
  $report.Add("RESULT: IDENTICAL - both programs build exactly the same tree ($($FpBase.Order.Count) items compared).")
} else {
  $report.Add("RESULT: DIFFERENT - $($changed.Count) changed, $($missing.Count) only in base, $($extra.Count) only in new" + $(if ($sameOrder) { '' } else { ', order differs' }) + '.')
}
$report.Add(("time: {0:N1} s; full fingerprints: {1}\base.txt and new.txt" -f ((Get-Date) - $t0).TotalSeconds, $OutFull))
Write-Utf8 (Join-Path $OutFull 'report.txt') (($report -join "`r`n") + "`r`n")
if (-not $Quiet) { $report | ForEach-Object { Write-Host $_ } }
if ($identical) { exit 0 }
exit 1
