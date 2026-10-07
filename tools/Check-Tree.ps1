<#
  Check-Tree.ps1
  --------------
  A quick health summary of one Family Tree Viewer installation: builds the family tree once in headless
  Google Chrome (with tools\check-tree.html, next to this script) and prints ONE line of JSON.
  Used by tools\Update-Program.ps1 before and after it installs a new program version.

  Usage (Windows PowerShell 5.1):
    powershell -NoProfile -ExecutionPolicy Bypass -File tools\Check-Tree.ps1 [-Viewer <folder>] [-Chrome <chrome.exe>|none] [-TimeoutSec 180]

    -Viewer      the installation to check (the folder with index.html, app\, data\). Default: the folder
                 above this script. The check page next to THIS script is used, so an installation can be
                 checked with another version's check page.
    -Chrome      chrome.exe; default: looked up in Program Files, Program Files (x86) and Local AppData.
                 "none" = do not use Chrome (prints {"skipped":true,...}).
    -TimeoutSec  how long Chrome may take (default 180 s).

  Output, one line on standard output:
    {"version":"1.0.0","built":"...","docs":7,"personDocs":6,"peopleKnown":14,"people":20,
     "roots":{"tom":true,"ruth":true},"errors":0,"settingsProblem":"","buildError":null,"loadErrors":[]}
                                              the page answered (see check-tree.html for the fields)
    {"skipped":true,"reason":"..."}           Chrome was not found (or -Chrome none)
    {"noAnswer":true,"reason":"..."}          Chrome ran but the page gave no answer (time-out, crash)

  Exit code: 0 = answered and buildError is null, 1 = buildError or no answer, 3 = skipped, 2 = usage error.

  Nothing is changed in the installation. The only things written are Chrome's throwaway profile and its
  output, inside <Viewer>\updates\chrome-check\, and they are deleted again at the end. (Chrome cannot use
  a profile in a very deep folder: when that path would be longer than 120 characters, e.g. for a test copy,
  %TEMP%\FamilyTree-chrome-check\ is used instead.)
#>
param(
  [string]$Viewer = '',
  [string]$Chrome = '',
  [int]$TimeoutSec = 180
)
$ErrorActionPreference = 'Stop'

function Write-Result([string]$json, [int]$code) { Write-Output $json; exit $code }
$script:JsonEsc = New-Object System.Text.RegularExpressions.Regex('[\\"\u0000-\u001f]')
function JStr([string]$s) {
  return '"' + $script:JsonEsc.Replace([string]$s, [System.Text.RegularExpressions.MatchEvaluator] {
      param($m) $c = [int][char]$m.Value
      switch ($c) { 34 { '\"' } 92 { '\\' } 10 { '\n' } 13 { '\r' } 9 { '\t' } default { '\u{0:x4}' -f $c } } }) + '"'
}

$ToolsDir = [IO.Path]::GetFullPath($PSScriptRoot)
$PageFile = Join-Path $ToolsDir 'check-tree.html'
if (-not $Viewer) { $Viewer = Split-Path -Parent $ToolsDir }
$ViewerRoot = [IO.Path]::GetFullPath($Viewer).TrimEnd('\')
if ($ViewerRoot.Length -le 3 -or -not [IO.Directory]::Exists($ViewerRoot)) { Write-Result ('{"noAnswer":true,"reason":' + (JStr "the folder $ViewerRoot does not exist") + '}') 2 }
if (-not [IO.File]::Exists($PageFile)) { Write-Result ('{"noAnswer":true,"reason":' + (JStr "check-tree.html is missing next to $PSCommandPath") + '}') 2 }

# ---------- Chrome
if ($Chrome -eq 'none') { Write-Result '{"skipped":true,"reason":"Chrome was not used (-Chrome none)"}' 3 }
if (-not $Chrome) {
  foreach ($c in @(
      (Join-Path ([string]$env:ProgramFiles) 'Google\Chrome\Application\chrome.exe'),
      (Join-Path ([string]${env:ProgramFiles(x86)}) 'Google\Chrome\Application\chrome.exe'),
      (Join-Path ([string]$env:LOCALAPPDATA) 'Google\Chrome\Application\chrome.exe'))) {
    if ($c -and [IO.File]::Exists($c)) { $Chrome = $c; break }
  }
}
if (-not $Chrome -or -not [IO.File]::Exists($Chrome)) { Write-Result '{"skipped":true,"reason":"Google Chrome was not found"}' 3 }

# ---------- our own throwaway folder: <Viewer>\updates\chrome-check\<random>
# (Chrome cannot use a profile folder whose path is very long; for an installation in a very deep folder,
# e.g. a test copy, the throwaway folder goes to %TEMP%\FamilyTree-chrome-check instead.)
$WorkTop = $ViewerRoot
$WorkBase = Join-Path $ViewerRoot 'updates\chrome-check'
if ($WorkBase.Length -gt 120) { $WorkTop = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\'); $WorkBase = Join-Path $WorkTop 'FamilyTree-chrome-check' }
function Assert-OurFolder([string]$p) {
  $f = [IO.Path]::GetFullPath($p).TrimEnd('\')
  if (-not $f.StartsWith($WorkBase + '\', [StringComparison]::OrdinalIgnoreCase) -and $f -ne $WorkBase -and $f -ne (Join-Path $ViewerRoot 'updates')) { throw "SAFETY STOP: $f is outside $WorkBase" }
  # no junction or symbolic link anywhere between the installation (or TEMP) folder and here
  $q = $f
  while ($q.Length -gt $WorkTop.Length) {
    if ([IO.Directory]::Exists($q) -or [IO.File]::Exists($q)) {
      if (([IO.File]::GetAttributes($q) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "SAFETY STOP: $q is a link to somewhere else" }
    }
    $q = [IO.Path]::GetDirectoryName($q)
  }
  return $f
}
function Remove-OurFolder([string]$p) {
  $f = Assert-OurFolder $p
  for ($k = 0; $k -lt 8; $k++) {
    try { if ([IO.Directory]::Exists($f)) { [IO.Directory]::Delete('\\?\' + $f, $true) }; return } catch { Start-Sleep -Milliseconds 500 }
  }
}
function To-FileUrl([string]$p) {
  $parts = [IO.Path]::GetFullPath($p).Split('\')
  $enc = @($parts[0])
  for ($i = 1; $i -lt $parts.Length; $i++) { if ($parts[$i] -ne '') { $enc += [Uri]::EscapeDataString($parts[$i]) } }
  return 'file:///' + ($enc -join '/')
}
function Read-Shared([string]$p) {
  $fs = New-Object IO.FileStream($p, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
  try { return (New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8)).ReadToEnd() } finally { $fs.Dispose() }
}
function Quote-Arg([string]$a) { if ($a -match '[\s"]') { return '"' + $a.Replace('"', '\"') + '"' } return $a }

$work = ''
try {
  $made = @($WorkBase)
  if ($WorkTop -eq $ViewerRoot) { $made = @((Join-Path $ViewerRoot 'updates'), $WorkBase) }
  foreach ($d in $made) {
    if (-not [IO.Directory]::Exists($d)) { [void][IO.Directory]::CreateDirectory((Assert-OurFolder $d)) }
  }
  $work = Assert-OurFolder (Join-Path $WorkBase ('{0:x6}' -f (Get-Random -Maximum 16777216)))
  [void][IO.Directory]::CreateDirectory($work)
  $profileDir = Join-Path $work 'p'
  $domFile = Join-Path $work 'out.html'
  $errFile = Join-Path $work 'chrome-err.txt'
  $url = (To-FileUrl $PageFile) + '?root=' + [Uri]::EscapeDataString((To-FileUrl $ViewerRoot) + '/')
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
  if (-not $finished) { $answer = '{"noAnswer":true,"reason":' + (JStr "Chrome did not finish within $TimeoutSec s") + '}' }
  else {
    $dom = ''
    if ([IO.File]::Exists($domFile)) { $dom = Read-Shared $domFile }
    $m = [regex]::Match($dom, '<pre id="out">([^<]*)</pre>')
    $text = ''
    if ($m.Success) { $text = [System.Net.WebUtility]::HtmlDecode($m.Groups[1].Value).Trim() }
    if ($text.StartsWith('{')) { $answer = $text }
    else {
      $err = ''
      if ([IO.File]::Exists($errFile)) { $err = (Read-Shared $errFile).Trim() }
      if ($err.Length -gt 400) { $err = $err.Substring($err.Length - 400) }
      $answer = '{"noAnswer":true,"reason":' + (JStr ("the check page gave no answer (" + $(if ($text) { $text } else { "$($dom.Length) characters" }) + "); Chrome said: $err")) + '}'
    }
  }
} catch {
  $answer = '{"noAnswer":true,"reason":' + (JStr ("the check could not be run: " + $_.Exception.Message)) + '}'
} finally {
  if ($work) { try { Remove-OurFolder $work } catch { } }
  # the %TEMP% fallback folder itself is removed again when nothing else uses it
  if ($WorkTop -ne $ViewerRoot) { try { [IO.Directory]::Delete($WorkBase) } catch { } }
}
$code = 1
if ($answer -match '^\{"skipped"') { $code = 3 }
elseif ($answer -notmatch '"noAnswer"' -and $answer -match '"buildError":null') { $code = 0 }
Write-Result $answer $code
