<#
  Run-Tests.ps1
  -------------
  All automatic tests of the Family Tree Viewer. They run the same way on a PC and on GitHub (CI), with
  Windows PowerShell 5.1 and Google Chrome (headless, with a throwaway profile; no window opens).

  Usage:
    powershell -NoProfile -ExecutionPolicy Bypass -File tests\Run-Tests.ps1 [-Out <folder>] [-UpdateSnapshot]
                                                                            [-Only <stage>,...] [-Chrome <chrome.exe>]
    -Out             folder for everything the tests make (default: a new folder under %TEMP%). It must be
                     new, empty, or a folder an earlier run of this script made (it is then emptied).
    -UpdateSnapshot  write the snapshot of this run to tests\expected\snapshot.json instead of comparing
                     (afterwards, read the changes with a diff tool before committing them)
    -Only            run only these stages (the ones they need are added): parse, build, snapshot,
                     checks, media, pages, settings, reload, compare, e2e, updater
    -Chrome          chrome.exe; default: looked up in Program Files, Program Files (x86), Local AppData

  Exit code: 0 = every test passed, 1 = something failed or could not run.

  The stages:
    parse     every .ps1 / .psm1 file of the program parses, and a file with non-ASCII characters has a
              UTF-8 BOM (Windows PowerShell 5.1 reads a file without one as ANSI)
    build     makes the made-up test family (New-TestFamily.ps1), a test copy of the program (the files in
              tools\program-files.txt + family-settings.example.js as family-settings.js) and runs its
              tools\Update-FamilyTree.ps1 on the documents
    snapshot  headless Chrome builds the family model; it must equal tests\expected\snapshot.json
    checks    the things the test documents are there to prove (who is where, notes, links, lists ...)
    media     the pictures copied out of the documents (as they are, and cropped), and the photo copies
              of the Photos folder (smaller, upright)
    pages     every page of the viewer, with clicks on its controls: no script error, nothing broken
    settings  family-settings.js missing or broken: a friendly card, no script error
    reload    data\status.js with another program version: the open page reloads exactly once
    compare   tests\Compare-Trees.ps1 finds the test tree identical to itself
    e2e       the document updater on changing documents: added, changed, removed, new folder, damaged,
              empty, lock file, a document locked by another program, case-only rename, a copy of the
              viewer in the folder, settings.txt, and a junction (must stop without touching anything)
    updater   every tests\updater\Test-*.ps1 (each run in its own PowerShell; exit code 0 = passed). They
              get $env:FAMILYTREE_TEST_OUT (a folder of their own), $env:FAMILYTREE_TEST_REPO (the
              program folder) and $env:FAMILYTREE_TEST_CHROME (chrome.exe)

  Nothing is written outside -Out (except tests\expected\snapshot.json with -UpdateSnapshot). The
  program files are only read and copied.
#>
param(
  [string]$Out = '',
  [switch]$UpdateSnapshot,
  [string[]]$Only = @(),
  [string]$Chrome = ''
)
$ErrorActionPreference = 'Stop'
$StartedAt = Get-Date

$TestsDir = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')
$RepoDir = [IO.Path]::GetDirectoryName($TestsDir)
$PsExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$Utf8 = New-Object System.Text.UTF8Encoding($false)
$MarkerName = '.family-tree-tests'

# ---------------------------------------------------------------- results
$Results = New-Object System.Collections.Generic.List[object]
$StageTimes = [ordered]@{}
$script:Stage = ''
function Check([string]$name, [bool]$ok, [string]$detail = '') {
  $Results.Add([pscustomobject]@{ Stage = $script:Stage; Name = $name; Ok = $ok; Detail = $detail })
  if (-not $ok) { Write-Host ("  FAIL  {0}: {1}{2}" -f $script:Stage, $name, $(if ($detail) { " -- $detail" } else { '' })) -ForegroundColor Red }
}
function Note([string]$msg) { Write-Host "  $msg" }

# ---------------------------------------------------------------- the output folder
if (-not $Out) { $Out = Join-Path $env:TEMP ('FamilyTree-Tests-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + ('{0:x4}' -f (Get-Random -Maximum 65536))) }
$OutFull = [IO.Path]::GetFullPath($Out).TrimEnd('\')
if ($OutFull.Length -le 3) { Write-Host "Run-Tests: -Out cannot be a whole drive ($OutFull)"; exit 1 }
if (($OutFull + '\').StartsWith($RepoDir + '\', [StringComparison]::OrdinalIgnoreCase)) { Write-Host "Run-Tests: -Out must be outside the program folder ($RepoDir)"; exit 1 }
function Assert-InsideOut([string]$p) {
  $f = [IO.Path]::GetFullPath($p)
  if (-not $f.StartsWith($OutFull + '\', [StringComparison]::OrdinalIgnoreCase)) { throw "SAFETY STOP: $f is outside the test folder $OutFull" }
  return $f
}
# A junction or link inside is removed by itself first (never followed), e.g. one left by an e2e run
# that was stopped half-way.
function Remove-Links([string]$dir) {
  foreach ($d in [IO.Directory]::GetDirectories($dir)) {
    if (([IO.File]::GetAttributes($d) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { [IO.Directory]::Delete($d) } else { Remove-Links $d }
  }
}
function Remove-TestDir([string]$path) {
  $full = Assert-InsideOut $path
  if (-not [IO.Directory]::Exists('\\?\' + $full)) { return }
  if (([IO.File]::GetAttributes('\\?\' + $full) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { [IO.Directory]::Delete('\\?\' + $full); return }
  Remove-Links ('\\?\' + $full)
  for ($k = 0; $k -lt 8; $k++) {
    try { if ([IO.Directory]::Exists('\\?\' + $full)) { [IO.Directory]::Delete('\\?\' + $full, $true) }; return } catch { Start-Sleep -Milliseconds 400 }
  }
  throw "could not remove $full"
}
if ([IO.Directory]::Exists($OutFull) -and [IO.Directory]::GetFileSystemEntries($OutFull).Length -gt 0) {
  if (-not [IO.File]::Exists((Join-Path $OutFull $MarkerName))) {
    Write-Host "Run-Tests: $OutFull is not empty and was not made by this script. Give a new or empty folder with -Out."
    exit 1
  }
  foreach ($e in [IO.Directory]::GetDirectories($OutFull)) { Remove-TestDir $e }
  foreach ($e in [IO.Directory]::GetFiles($OutFull)) { if ([IO.Path]::GetFileName($e) -ne $MarkerName) { [IO.File]::Delete((Assert-InsideOut $e)) } }
}
[void][IO.Directory]::CreateDirectory($OutFull)
[IO.File]::WriteAllText((Join-Path $OutFull $MarkerName), 'Made by tests\Run-Tests.ps1; it may empty this folder again.', $Utf8)
$Logs = Join-Path $OutFull 'logs'
[void][IO.Directory]::CreateDirectory($Logs)

function Write-TestFile([string]$path, [string]$text) {
  $full = Assert-InsideOut $path
  [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($full))
  [IO.File]::WriteAllText($full, $text, $Utf8)
}
function Copy-TestFile([string]$from, [string]$to) {
  $full = Assert-InsideOut $to
  [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($full))
  [IO.File]::Copy($from, $full, $true)
}
function Copy-TestTree([string]$from, [string]$to) {
  foreach ($f in [IO.Directory]::GetFiles($from, '*', [IO.SearchOption]::AllDirectories)) {
    Copy-TestFile $f (Join-Path $to $f.Substring($from.TrimEnd('\').Length + 1))
  }
}

# ---------------------------------------------------------------- child processes
function Quote-Arg([string]$a) { if ($a -eq '' -or $a -match '[\s"]') { return '"' + $a.Replace('"', '\"') + '"' } return $a }
function Invoke-Logged([string]$exe, [string[]]$argList, [string]$logName, [int]$timeoutSec = 600) {
  $base = Assert-InsideOut (Join-Path $Logs $logName)
  $quoted = @($argList | ForEach-Object { Quote-Arg $_ })
  $p = Start-Process -FilePath $exe -ArgumentList $quoted -PassThru -WindowStyle Hidden -RedirectStandardOutput "$base.out.txt" -RedirectStandardError "$base.err.txt"
  $null = $p.Handle          # keeps the exit code available after the process ends
  if (-not $p.WaitForExit($timeoutSec * 1000)) {
    & taskkill.exe /T /F /PID $p.Id | Out-Null
    return 124
  }
  $p.WaitForExit()
  return $p.ExitCode
}
function Get-Log([string]$logName) {
  $t = ''
  foreach ($ext in '.out.txt', '.err.txt') { $f = Join-Path $Logs ($logName + $ext); if ([IO.File]::Exists($f)) { $t += [IO.File]::ReadAllText($f) } }
  return $t.Trim()
}
function Invoke-PsFile([string]$file, [string[]]$scriptArgs, [string]$logName, [int]$timeoutSec = 600) {
  return Invoke-Logged $PsExe (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $file) + $scriptArgs) $logName $timeoutSec
}

# ---------------------------------------------------------------- Chrome
function Find-Chrome {
  if ($Chrome) { if ([IO.File]::Exists($Chrome)) { return [IO.Path]::GetFullPath($Chrome) }; return '' }
  foreach ($c in @((Join-Path $env:ProgramFiles 'Google\Chrome\Application\chrome.exe'),
                   (Join-Path ${env:ProgramFiles(x86)} 'Google\Chrome\Application\chrome.exe'),
                   (Join-Path $env:LOCALAPPDATA 'Google\Chrome\Application\chrome.exe'))) {
    if ($c -and [IO.File]::Exists($c)) { return $c }
  }
  return ''
}
function To-FileUrl([string]$p) {
  $parts = [IO.Path]::GetFullPath($p).Split('\')
  $enc = @($parts[0])
  for ($i = 1; $i -lt $parts.Length; $i++) { $enc += [Uri]::EscapeDataString($parts[$i]) }
  return 'file:///' + ($enc -join '/')
}
$script:ChromeRuns = 0
# Opens a page in headless Chrome and returns the text of <pre id="$preId"> (or throws).
function Invoke-ChromePage([string]$name, [string]$url, [int]$budgetMs, [string]$preId) {
  $script:ChromeRuns++
  $profileDir = Assert-InsideOut (Join-Path $OutFull ("chrome\$name-" + ('{0:x6}' -f (Get-Random -Maximum 16777216))))
  $domFile = Assert-InsideOut (Join-Path $Logs "chrome-$name.dom.html")
  $errFile = Assert-InsideOut (Join-Path $Logs "chrome-$name.err.txt")
  $chromeArgs = @('--headless=new', '--disable-gpu', '--no-first-run', '--no-default-browser-check', '--disable-extensions',
    '--disable-background-networking', '--disable-component-update', '--disable-sync', '--disable-default-apps', '--no-pings',
    '--disable-domain-reliability', '--mute-audio', "--user-data-dir=$profileDir", "--virtual-time-budget=$budgetMs", '--window-size=1280,900',
    '--allow-file-access-from-files', '--dump-dom', $url) | ForEach-Object { Quote-Arg $_ }
  $proc = Start-Process -FilePath $ChromeExe -ArgumentList $chromeArgs -PassThru -WindowStyle Hidden -RedirectStandardOutput $domFile -RedirectStandardError $errFile
  $finished = $proc.WaitForExit(240000)
  if (-not $finished) { & taskkill.exe /T /F /PID $proc.Id | Out-Null }
  # Chrome's helper processes can stay a moment longer: wait for the ones that use our profile folder
  for ($k = 0; $k -lt 40; $k++) {
    $left = @(Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" -ErrorAction SilentlyContinue |
      Where-Object { $_.CommandLine -and $_.CommandLine.IndexOf($profileDir, [StringComparison]::OrdinalIgnoreCase) -ge 0 })
    if ($left.Count -eq 0) { break }
    if ($k -eq 39) { foreach ($p in $left) { try { Stop-Process -Id ([int]$p.ProcessId) -Force -ErrorAction Stop } catch { } } }
    else { Start-Sleep -Milliseconds 400 }
  }
  try { Remove-TestDir $profileDir } catch { Note "could not remove the Chrome profile $profileDir" }
  if (-not $finished) { throw "Chrome did not finish within 240 s ($name)" }
  $dom = ''
  if ([IO.File]::Exists($domFile)) {
    $fs = New-Object IO.FileStream($domFile, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    try { $dom = (New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8)).ReadToEnd() } finally { $fs.Dispose() }
  }
  $m = [regex]::Match($dom, '<pre id="' + $preId + '"[^>]*>([^<]*)</pre>')
  if (-not $m.Success) {
    $err = ''; if ([IO.File]::Exists($errFile)) { $err = [IO.File]::ReadAllText($errFile) }
    if ($err.Length -gt 1200) { $err = $err.Substring($err.Length - 1200) }
    throw "no <pre id=""$preId""> in Chrome's output for $name ($($dom.Length) characters). Chrome said: $err"
  }
  return [System.Net.WebUtility]::HtmlDecode($m.Groups[1].Value)
}

# ---------------------------------------------------------------- reading the viewer's files
function Read-JsObject([string]$file) {
  $t = [IO.File]::ReadAllText($file, [Text.Encoding]::UTF8)
  $i = $t.IndexOf('= {')
  $j = $t.LastIndexOf('}')
  if ($i -lt 0 -or $j -lt $i) { throw "not a window.X = {...}; file: $file" }
  return ($t.Substring($i + 2, $j - $i - 1) | ConvertFrom-Json)
}
function Get-ProgramVersion([string]$dir) {
  $m = [regex]::Match([IO.File]::ReadAllText((Join-Path $dir 'app\version.js')), 'FAMILY_VERSION\s*=\s*[''"]([0-9A-Za-z.+-]{1,40})[''"]')
  if ($m.Success) { return $m.Groups[1].Value }
  return ''
}

# ---------------------------------------------------------------- stages
$AllStages = @('parse', 'build', 'snapshot', 'checks', 'media', 'pages', 'settings', 'reload', 'compare', 'e2e', 'updater')
$Run = @{}
if ($Only.Count) {
  foreach ($s in ($Only -join ',').Split(',')) { $s = $s.Trim().ToLower(); if ($s) { if ($AllStages -notcontains $s) { Write-Host "Run-Tests: unknown stage '$s' (stages: $($AllStages -join ', '))"; exit 1 }; $Run[$s] = $true } }
  foreach ($s in 'snapshot', 'checks', 'media', 'pages', 'settings', 'reload', 'compare') { if ($Run[$s]) { $Run['build'] = $true } }
  if ($Run['checks']) { $Run['snapshot'] = $true }
} else { foreach ($s in $AllStages) { $Run[$s] = $true } }

$ChromeExe = Find-Chrome
$NeedChrome = $Run['snapshot'] -or $Run['pages'] -or $Run['settings'] -or $Run['reload'] -or $Run['compare']
$SnapDir = Join-Path $OutFull 'snap'
$SnapSource = Join-Path $SnapDir 'life history'
$Viewer = Join-Path $SnapSource 'Family Tree Viewer'
$ExpectedSnapshot = Join-Path $TestsDir 'expected\snapshot.json'
$script:BuildOk = $false
$script:Snapshot = $null
$ProgramVersion = Get-ProgramVersion $RepoDir

Write-Host "Family Tree Viewer tests"
Write-Host "  program:   $RepoDir (version $ProgramVersion)"
Write-Host "  test files: $OutFull"
Write-Host "  PowerShell $($PSVersionTable.PSVersion); Chrome: $(if ($ChromeExe) { $ChromeExe } else { 'NOT FOUND' })"
if ($PSVersionTable.PSVersion.Major -ne 5) { Write-Host '  NOTE: these tests are meant for Windows PowerShell 5.1 (powershell.exe), the PowerShell the program uses.' -ForegroundColor Yellow }

function Invoke-Stage([string]$name, [scriptblock]$body) {
  if (-not $Run[$name]) { return }
  $script:Stage = $name
  Write-Host "[$name]"
  $t0 = Get-Date
  try { & $body }
  catch { Check 'stage ran to the end' $false ($_.Exception.Message + ' @ ' + $_.InvocationInfo.ScriptLineNumber) }
  $StageTimes[$name] = ((Get-Date) - $t0).TotalSeconds
}

# ================================================================ parse
Invoke-Stage 'parse' {
  $skip = @('data', 'dev', 'updates', 'program-previous', '.git', 'node_modules')
  $files = New-Object System.Collections.Generic.List[string]
  $stack = New-Object System.Collections.Generic.Stack[string]
  $stack.Push($RepoDir)
  while ($stack.Count) {
    $d = $stack.Pop()
    foreach ($sub in [IO.Directory]::GetDirectories($d)) {
      if ($d -eq $RepoDir -and $skip -contains [IO.Path]::GetFileName($sub).ToLower()) { continue }
      $stack.Push($sub)
    }
    foreach ($f in [IO.Directory]::GetFiles($d)) { if ($f -match '\.(ps1|psm1)$') { $files.Add($f) } }
  }
  $bad = 0
  foreach ($f in $files) {
    $rel = $f.Substring($RepoDir.Length + 1)
    $tokens = $null; $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($f, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { $bad++; Check "parses: $rel" $false (($errors | Select-Object -First 3 | ForEach-Object { "line $($_.Extent.StartLineNumber): $($_.Message)" }) -join ' | ') }
    $bytes = [IO.File]::ReadAllBytes($f)
    $bom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    $nonAscii = $false; foreach ($b in $bytes) { if ($b -ge 0x80) { $nonAscii = $true; break } }
    if ($nonAscii -and -not $bom) { $bad++; Check "encoding: $rel" $false 'has non-ASCII characters but no UTF-8 BOM, so Windows PowerShell 5.1 would misread them' }
  }
  Check "$($files.Count) PowerShell files parse and are safely encoded" ($bad -eq 0) "$bad problem(s)"
  Check 'app\version.js has a version' ([bool]$ProgramVersion) $ProgramVersion
}

# ================================================================ build
Invoke-Stage 'build' {
  # 1. the made-up family
  $code = Invoke-PsFile (Join-Path $TestsDir 'New-TestFamily.ps1') @('-Path', $SnapSource, '-Quiet') 'new-test-family'
  Check 'New-TestFamily.ps1 made the test documents' ($code -eq 0) (Get-Log 'new-test-family')
  if ($code -ne 0) { return }

  # 2. a test copy of the program: the files of the allow-list (so a file missing from it shows up here)
  $listFile = Join-Path $RepoDir 'tools\program-files.txt'
  $copied = 0; $missing = @()
  if ([IO.File]::Exists($listFile)) {
    foreach ($line in [IO.File]::ReadAllLines($listFile)) {
      $rel = $line.Trim()
      if (-not $rel -or $rel.StartsWith('#')) { continue }
      $src = Join-Path $RepoDir ($rel.Replace('/', '\'))
      if ([IO.File]::Exists($src)) { Copy-TestFile $src (Join-Path $Viewer ($rel.Replace('/', '\'))); $copied++ } else { $missing += $rel }
    }
    Check 'every file in tools\program-files.txt exists' ($missing.Count -eq 0) ($missing -join ', ')
  } else {
    Note 'tools\program-files.txt not found: copying index.html, app\ and tools\Update-FamilyTree.ps1'
    foreach ($rel in @('index.html', 'tools\Update-FamilyTree.ps1') + @([IO.Directory]::GetFiles((Join-Path $RepoDir 'app')) | ForEach-Object { 'app\' + [IO.Path]::GetFileName($_) })) {
      Copy-TestFile (Join-Path $RepoDir $rel) (Join-Path $Viewer $rel); $copied++
    }
  }
  foreach ($need in 'index.html', 'app\app.js', 'app\genealogy.js', 'app\config.js', 'app\version.js', 'tools\Update-FamilyTree.ps1') {
    Check "the program has $need" ([IO.File]::Exists((Join-Path $Viewer $need)))
  }
  # the example family's settings, with a made-up report address so the Report-a-problem card is tested too
  $example = [IO.File]::ReadAllText((Join-Path $RepoDir 'family-settings.example.js'), [Text.Encoding]::UTF8)
  $settings = $example.Replace("email: '',", "email: 'family-tree-tests@example.com',")
  Check "family-settings.example.js has the line email: ''," ($settings -ne $example)
  Write-TestFile (Join-Path $Viewer 'family-settings.js') $settings
  Copy-TestTree (Join-Path $TestsDir 'pages') (Join-Path $Viewer 'test-pages')
  # index.html with the error recorder first and the test driver last
  $index = [IO.File]::ReadAllText((Join-Path $Viewer 'index.html'), [Text.Encoding]::UTF8)
  $at = $index.IndexOf('<script src=')
  Check 'index.html loads scripts' ($at -ge 0)
  $index = $index.Substring(0, $at) + '<script src="test-pages/capture.js"></script>' + "`n" + $index.Substring($at)
  $index = $index.Replace('</body>', '<script src="test-pages/driver.js"></script>' + "`n</body>")
  Write-TestFile (Join-Path $Viewer 'index-test.html') $index

  # 3. the document updater
  $t0 = Get-Date
  $code = Invoke-PsFile (Join-Path $Viewer 'tools\Update-FamilyTree.ps1') @('-Quiet', '-Source', $SnapSource) 'build-update'
  $secs = ((Get-Date) - $t0).TotalSeconds
  Check 'Update-FamilyTree.ps1 exit code 0' ($code -eq 0) ("exit $code " + (Get-Log 'build-update'))
  Note ("{0} program files copied; the first update read the test family in {1:N1} s" -f $copied, $secs)
  $dataFile = Join-Path $Viewer 'data\data.js'
  Check 'data\data.js was written' ([IO.File]::Exists($dataFile))
  if (-not [IO.File]::Exists($dataFile)) { return }
  $st = Read-JsObject (Join-Path $Viewer 'data\status.js')
  Check 'status.js says done' ($st.state -eq 'done') $st.state
  Check 'status.js carries the program version' ($st.version -eq $ProgramVersion) "status: '$($st.version)', app\version.js: '$ProgramVersion'"
  Check 'status.js counts: 27 documents, 26 read, 1 failed' ($st.total -eq 27 -and $st.changed -eq 26 -and $st.added -eq 26 -and $st.failed -eq 1) "total $($st.total), changed $($st.changed), added $($st.added), failed $($st.failed)"
  $data = Read-JsObject $dataFile
  Check 'data.js: 27 documents' (@($data.docs).Count -eq 27) "$(@($data.docs).Count)"
  Check 'data.js: the source folder' ($data.source -eq $SnapSource) $data.source
  Check 'data.js: the Word lock file (~$...) is not read' (-not (@($data.docs) | Where-Object { $_.name.StartsWith('~$') })) ''
  $errs = @($data.errors)
  Check 'data.js: one read error, for the damaged document' ($errs.Count -eq 1 -and $errs[0].path -eq 'Carrow\C4,1 Carrow Isaac.docx' -and $errs[0].msg -match 'damaged') (($errs | ForEach-Object { "$($_.path): $($_.msg)" }) -join ' | ')
  Check 'data.js: the text file is listed as another file' (@($data.other).Count -eq 1 -and @($data.other)[0].path -eq 'Dalby\research notes.txt') ((@($data.other) | ForEach-Object { $_.path }) -join ', ')
  $ph = @($data.photos); $phErr = @($ph | Where-Object { $_.err })
  Check 'data.js: 10 photos from the Photos folder, 1 could not be read' ($ph.Count -eq 10 -and $phErr.Count -eq 1 -and $phErr[0].path -eq 'Photos\B3,3.jpg') "$($ph.Count) photos; not read: $(($phErr | ForEach-Object { $_.path }) -join ', ')"
  Check 'data.js: the Photos folder is there' ($data.photosFolder.exists -eq $true -and $data.photosFolder.path -eq (Join-Path $SnapSource 'Photos')) ($data.photosFolder | ConvertTo-Json -Compress)
  $script:BuildOk = $true
}
if (($Run['snapshot'] -or $Run['pages'] -or $Run['settings'] -or $Run['reload'] -or $Run['compare'] -or $Run['media']) -and -not $script:BuildOk) {
  $script:Stage = 'build'
  Check 'the test family was built (the stages that need it are skipped)' $false
  foreach ($s in 'snapshot', 'checks', 'media', 'pages', 'settings', 'reload', 'compare') { $Run[$s] = $false }
}
if ($NeedChrome -and -not $ChromeExe) {
  $script:Stage = 'chrome'
  Check 'Google Chrome is installed (needed for the snapshot and page tests; give its path with -Chrome)' $false
  foreach ($s in 'snapshot', 'checks', 'pages', 'settings', 'reload', 'compare') { $Run[$s] = $false }
}

# ================================================================ snapshot
Invoke-Stage 'snapshot' {
  $text = Invoke-ChromePage 'snapshot' (To-FileUrl (Join-Path $Viewer 'test-pages\snapshot.html')) 10000 'out'
  $text = $text.Replace("`r`n", "`n").TrimEnd()
  Write-TestFile (Join-Path $OutFull 'snapshot.actual.json') ($text + "`n")
  if ($text.StartsWith('ERROR')) { Check 'the snapshot page built the model' $false $text; return }
  $script:SnapshotText = $text
  try { $script:Snapshot = $text | ConvertFrom-Json } catch { Check 'the snapshot is valid JSON' $false $_.Exception.Message; return }
  $expected = ''
  if ([IO.File]::Exists($ExpectedSnapshot)) { $expected = [IO.File]::ReadAllText($ExpectedSnapshot, [Text.Encoding]::UTF8).Replace("`r`n", "`n").TrimEnd() }
  if ($UpdateSnapshot) {
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($ExpectedSnapshot))
    [IO.File]::WriteAllText($ExpectedSnapshot, $text + "`n", $Utf8)
    Note "wrote $ExpectedSnapshot ($(($text -split "`n").Count) lines)$(if ($expected -and $expected -ne $text) { '; it changed: compare it with the previous version before committing' } elseif ($expected) { '; no change' })"
    return
  }
  if (-not $expected) { Check 'tests\expected\snapshot.json exists (make it with -UpdateSnapshot, then check it by eye)' $false; return }
  if ($expected -ceq $text) { Check 'the model equals tests\expected\snapshot.json' $true; return }
  $a = $expected -split "`n"; $b = $text -split "`n"
  $setA = New-Object 'System.Collections.Generic.HashSet[string]' (, [string[]]$a)
  $setB = New-Object 'System.Collections.Generic.HashSet[string]' (, [string[]]$b)
  $gone = @($a | Where-Object { -not $setB.Contains($_) })
  $new = @($b | Where-Object { -not $setA.Contains($_) })
  # an item that only changed (same key on both sides) is shown once, around the first difference
  $keyOf = { param($l) $m = [regex]::Match($l, '^\s*("[^"]*"):'); if ($m.Success) { $m.Groups[1].Value } else { '' } }
  $newByKey = New-Object 'System.Collections.Generic.Dictionary[string,string]'      # (case-sensitive, unlike @{})
  foreach ($l in $new) { $k = & $keyOf $l; if ($k -and -not $newByKey.ContainsKey($k)) { $newByKey[$k] = $l } }
  $paired = New-Object 'System.Collections.Generic.Dictionary[string,bool]'
  $show = New-Object System.Collections.Generic.List[string]
  foreach ($l in $gone) {
    if ($show.Count -ge 30) { break }
    $k = & $keyOf $l
    if ($k -and $newByKey.ContainsKey($k)) {
      $o = $newByKey[$k]; $paired[$o] = $true
      $i = 0; $n = [Math]::Min($l.Length, $o.Length)
      while ($i -lt $n -and $l[$i] -ceq $o[$i]) { $i++ }
      $from = [Math]::Max(0, $i - 60)
      $show.Add("    changed $k at character ${i}:")
      $show.Add('      was: ...' + $l.Substring($from, [Math]::Min(180, $l.Length - $from)))
      $show.Add('      now: ...' + $o.Substring($from, [Math]::Min(180, $o.Length - $from)))
    } else { $show.Add('    - ' + $(if ($l.Length -gt 300) { $l.Substring(0, 300) + '...' } else { $l })) }
  }
  foreach ($l in $new) {
    if ($show.Count -ge 45) { break }
    if (-not $paired.ContainsKey($l)) { $show.Add('    + ' + $(if ($l.Length -gt 300) { $l.Substring(0, 300) + '...' } else { $l })) }
  }
  Check 'the model equals tests\expected\snapshot.json' $false ("$($gone.Count) line(s) of the expected snapshot are not in this run, $($new.Count) line(s) are new. This run: $(Join-Path $OutFull 'snapshot.actual.json') (if the change is intended, run with -UpdateSnapshot and check the diff)`n" + ($show -join "`n"))
}

# ================================================================ checks: what the test documents prove
Invoke-Stage 'checks' {
  $snap = $script:Snapshot
  if (-not $snap) { Check 'a snapshot to check' $false; return }
  # (PowerShell variable names ignore case: $People and $person would be one variable, so the names differ)
  $Dash = [string][char]0x2013
  $PeopleMap = $snap.people; $DocMap = $snap.docs; $NoteMap = $snap.notes
  function Person([string]$k) { $prop = $PeopleMap.PSObject.Properties[$k]; if ($prop) { return $prop.Value }; return $null }
  function DocOf([string]$path) { $prop = $DocMap.PSObject.Properties[$path]; if ($prop) { return $prop.Value }; return $null }
  function Has($list, [string]$value) { return @($list) -contains $value }
  # the blocks of one document, as the snapshot wrote them (JSON text, one block per line)
  function BlocksOf([string]$path) {
    $all = $script:SnapshotText -split "`n"
    $start = [Array]::IndexOf($all, ' "blocks": {')
    $head = '  "' + $path.Replace('\', '\\') + '": ['
    $k = $start
    while ($k -ge 0 -and $k -lt $all.Length -and $all[$k] -ne $head) { $k++ }
    if ($k -lt 0 -or $k -ge $all.Length) { return '' }
    $sb = New-Object System.Text.StringBuilder
    for ($k++; $k -lt $all.Length -and $all[$k] -notmatch '^  \],?$'; $k++) { [void]$sb.Append($all[$k]).Append("`n") }
    return $sb.ToString()
  }

  $x = Person 'tom'
  Check 'root tom: from the settings, his own document by documentPeople' ($x.name -eq 'Thomas R. Ashworth' -and $x.doc -eq 'Ashworth\Ashworth Thomas.docx' -and $x.father -eq 'A1,1' -and $x.mother -eq 'B1,1' -and $x.spouse -eq 'ruth') "$($x.name) | $($x.doc)"
  $x = Person 'A1,1'
  Check 'A1,1: name and years after a Shift+Enter, bold labels read' ($x.name -eq 'Henry Lowell Ashworth' -and $x.years -eq "1922$($Dash)1998" -and $x.doc -eq 'Ashworth\A1,1 Ashworth Henry.docx' -and $x.relation -eq "Tom's father") "$($x.name) | $($x.years) | $($x.relation)"
  Check 'A1,1: three siblings (Tab-indented lines continue the list)' (@($x.siblings).Count -eq 3) ((@($x.siblings) | ForEach-Object { $_.name }) -join ', ')
  Check 'A1,1: two children' (@($x.otherChildren).Count -eq 2) ((@($x.otherChildren) | ForEach-Object { $_.name }) -join ', ')
  Check 'A1,1: timeline events from the year lines' (@($x.events).Count -eq 2) ((@($x.events)) -join ' | ')
  Check 'A1,1: married to B1,1 (Marriage: line with her number)' ($x.spouse -eq 'B1,1' -and -not $x.otherSpouses)
  $x = Person 'B1,1'
  Check 'B1,1: her document by documentPeople; a woman, though number 1 of her line' ($x.name -eq 'Margaret Ann Brennan' -and $x.doc -eq 'Brennan\Brennan Margaret.docx' -and $x.sex -eq 'f' -and $x.relation -eq "Tom's mother") "$($x.name) | $($x.sex) | $($x.relation)"
  Check 'A2,1: a code split over two Word runs is still read' ((Person 'A2,1').doc -eq 'Ashworth\A2,1 Ashworth Samuel.docx' -and (Person 'A2,1').name -eq 'Samuel Ashworth')
  Check 'A3,1: "A3, 1" (with a space) on a Father: line' ((Person 'A3,1').name -eq 'John Ashworth' -and -not @($NoteMap.refMismatch | Where-Object { $_ -match 'A3, 1' }).Count)
  Check 'A3,3: "A3.3" (with a full stop) on a Father: line' ((Person 'A3,3').doc -eq 'Ashworth\A3,3 Thornfield Edward.docx' -and (Person 'A3,3').name -eq 'Edward Thornfield')
  $x = Person 'A3,2'
  Check 'A3,2: "Mother: ?" leaves the place empty and blocked' ($x.blocked -eq $true -and $x.placeholder -eq $true -and $x.name -eq 'Unknown mother') "$($x.name) blocked=$($x.blocked)"
  $x = Person 'A3,1'
  Check 'A3,1: a marriage line cannot fill the blocked place, it is another marriage' (@($x.otherSpouses).Count -eq 1 -and @($x.otherSpouses)[0].name -eq 'Mary Penrose') ((@($x.otherSpouses) | ForEach-Object { $_.name }) -join ', ')
  Check 'A3,1: the full, newer document is shown, the older copy is another version' ($x.doc -eq 'Ashworth\A3,1 Ashworth John.docx' -and (Has $x.otherDocs 'Ashworth\A3,1 Ashworth John (old copy).docx'))
  $dup = @($NoteMap.duplicates)
  Check 'notes: one duplicate (A3,1), not two different people' ($dup.Count -eq 1 -and $dup[0].key -eq 'A3,1' -and -not $dup[0].differentPeople -and $dup[0].main -eq 'doc:Ashworth\A3,1 Ashworth John.docx') "$($dup.Count) duplicate(s)"
  Check 'A4,7: "Father: unknown" blocks the place too' ((Person 'A4,7').blocked -eq $true)
  Check 'D4,10: "Mother: Not known" blocks the place too' ((Person 'D4,10').blocked -eq $true)
  $x = Person 'A4,1'
  Check 'A4,1: the first line wins over the file name A4,2' ($x.doc -eq 'Ashworth\A4,2 Ashworth William.docx' -and $x.name -eq 'William Ashworth' -and $x.years -eq "abt. 1830$($Dash)1895") "$($x.doc) | $($x.years)"
  Check 'A4,2: keeps the name from the Mother: line' ((Person 'A4,2').name -eq 'Sarah Tolland' -and -not (Person 'A4,2').doc)
  $cm = @($NoteMap.codeMismatch)
  Check 'notes: the file name / first line disagreement' ($cm.Count -eq 1 -and $cm[0].file -eq 'A4,2' -and $cm[0].head -eq 'A4,1' -and $cm[0].chosen -eq 'A4,1') "$($cm.Count) item(s)"
  Check 'notes: the wrong number on a Descendant: line' (@($NoteMap.refMismatch | Where-Object { $_.field -eq 'descendant' -and $_.written -eq 'A4,2' -and $_.expected -eq 'A4,1' }).Count -eq 1) "$(@($NoteMap.refMismatch).Count) item(s)"
  Check 'A5,1: the file name "A5.1 ..." (with a full stop)' ((Person 'A5,1').doc -eq 'Ashworth\A5.1 Ashworth Robert.docx')
  $x = Person 'B2,1'
  Check 'B2,1: the document without a code is matched by name and years' ($x.doc -eq 'Brennan\Brennan Patrick.docx' -and (DocOf 'Brennan\Brennan Patrick.docx').matchedByName -eq $true) "$($x.doc)"
  Check 'notes: the match by name' (@($NoteMap.unmatched | Where-Object { $_.matched -eq 'B2,1' }).Count -eq 1)
  $x = Person 'B2,2'
  Check 'B2,2: the picture above the first line is the photo, the title is still read' ($x.name -eq 'Nora Quinn' -and $x.years -eq "1898$($Dash)1980" -and $x.docPhoto -eq 'media:Brennan\B2,2 Quinn Nora.docx#1.png?v=mtime') "$($x.name) | $($x.docPhoto)"
  Check 'B2,2: a photo in the Photos folder wins over the picture in the life history' ($x.photoFile -eq 'Photos\B2,2 Nora at 20.png' -and $x.photo -eq 'photo:Photos\B2,2 Nora at 20.png?v=mtime') "$($x.photoFile) | $($x.photo)"
  Check 'photos: A2,1 has two; the one named by the number alone wins over the newer one' ((Person 'A2,1').photoFile -eq 'Photos\A2,1.jpg') (Person 'A2,1').photoFile
  Check 'photos: the camera-rotated photo is for C3,1' ((Person 'C3,1').photoFile -eq 'Photos\C3,1 Joseph.jpg') (Person 'C3,1').photoFile
  Check 'photos: D3,8.jpg goes to C3,2 (the same person, pedigree collapse)' ((Person 'C3,2').photoFile -eq 'Photos\D3,8.jpg' -and -not (Person 'D3,8')) (Person 'C3,2').photoFile
  Check 'photos: "d4,12.JPG" (small letter, capital ending) for D4,12, who has no document' ((Person 'D4,12').photoFile -eq 'Photos\d4,12.JPG' -and (Person 'D4,12').placeholder -eq $true) (Person 'D4,12').photoFile
  Check 'photos: "ruth.jpg" for the root person ruth' ((Person 'ruth').photoFile -eq 'Photos\ruth.jpg') (Person 'ruth').photoFile
  Check 'photos: a photo adds no one to the tree (A9,1)' (-not (Person 'A9,1'))
  $pn = @($NoteMap.photos)
  $pnText = ($pn | ForEach-Object { "$($_.path):$($_.problem)" }) -join ', '
  Check 'notes: the 4 photos that are not shown, each with its reason' ($pn.Count -eq 4 -and
    @($pn | Where-Object { $_.path -eq 'Photos\A9,1.jpg' -and $_.problem -eq 'nobody' -and $_.code -eq 'A9,1' }).Count -eq 1 -and
    @($pn | Where-Object { $_.path -eq 'Photos\Family picnic.jpg' -and $_.problem -eq 'no number' }).Count -eq 1 -and
    @($pn | Where-Object { $_.path -eq 'Photos\B3,3.jpg' -and $_.problem -eq 'unreadable' -and $_.person -eq 'B3,3' }).Count -eq 1 -and
    @($pn | Where-Object { $_.path -eq 'Photos\A2,1 older.jpg' -and $_.problem -eq 'another' -and $_.shown -eq 'Photos\A2,1.jpg' }).Count -eq 1) $pnText
  Check 'photos: B3,3 (damaged photo) keeps the silhouette' (-not (Person 'B3,3').photo)
  Check 'flags: "from Kent, England to New York" is England' ((Person 'D4,11').flag -eq 'gb-eng England (immigration)') (Person 'D4,11').flag
  Check 'flags: "to New England from Wales" is Wales, not England' ((Person 'C3,3').flag -eq 'gb-wls Wales (immigration)') (Person 'C3,3').flag
  Check 'flags: "Flag: Irish" is Ireland' ((Person 'B2,2').flag -eq 'ie Ireland (flag)') (Person 'B2,2').flag
  $fn = @($NoteMap.flags)
  Check 'flags: "Arrived: 1859 at New Orleans" names no country: no flag, one note' (-not (Person 'D3,5').flag -and $fn.Count -eq 1 -and $fn[0].person -eq 'D3,5' -and $fn[0].value -eq '1859 at New Orleans') (($fn | ConvertTo-Json -Compress))
  Check 'flags: only these three people have a flag' (@($PeopleMap.PSObject.Properties | Where-Object { $_.Value.flag }).Count -eq 3) ((@($PeopleMap.PSObject.Properties | Where-Object { $_.Value.flag } | ForEach-Object { $_.Name })) -join ', ')
  Check 'B4,5 / B4,6: parents named without codes' ((Person 'B4,5').name -eq 'Daniel Quinn' -and (Person 'B4,5').years -eq "1840$($Dash)1901" -and (Person 'B4,6').name -eq 'Catherine Walsh')
  Check 'C1,1 / D1,2: people from the settings' ((Person 'C1,1').name -eq 'Walter James Carrow' -and (Person 'C1,1').years -eq "1925$($Dash)1990" -and (Person 'D1,2').name -eq 'Edna Mae Dalby')
  Check 'ruth: her parents C1,1 and D1,2 (a double line)' ((Person 'ruth').father -eq 'C1,1' -and (Person 'ruth').mother -eq 'D1,2' -and (Person 'C2,1').relation -eq "Ruth's grandfather")
  Check 'C4,5: "(C 4,5)" with a space after the letter' ((Person 'C4,5').name -eq 'John Fenwick')
  Check 'C3,4: "Marriage: 5/20/1895 to Alice Pennock (C3,4)(...)" names the spouse' ((Person 'C3,4').name -eq 'Alice Pennock' -and (Person 'C3,4').years -eq "1872$($Dash)1950")
  $al = $snap.aliases
  Check 'pedigree collapse: D3,7 is C3,1 and D3,8 is C3,2' ($al.'D3,7' -eq 'C3,1' -and $al.'D3,8' -eq 'C3,2') "D3,7 -> $($al.'D3,7'), D3,8 -> $($al.'D3,8')"
  Check 'pedigree collapse: C3,1 also stands at D3,7; D2,4 has them as parents' ((Has (Person 'C3,1').alsoAt 'D3,7') -and (Person 'D2,4').father -eq 'C3,1' -and (Person 'D2,4').mother -eq 'C3,2')
  Check 'notes: two collapse items' (@($NoteMap.collapse).Count -eq 2)
  Check 'D4,11: years at the end of the title line' ((Person 'D4,11').years -eq "1830$($Dash)1899")
  Check 'D3,6: "c. 1862-1940"' ((Person 'D3,6').years -eq "c. 1862$($Dash)1940" -and (Person 'D3,6').born -eq 1862)
  Check 'C4,1: the damaged document is listed; the place keeps its name from a Father: line' ((Person 'C4,1').name -eq 'Isaac Carrow' -and -not (Person 'C4,1').doc -and (Has $NoteMap.unreadable 'doc:Carrow\C4,1 Carrow Isaac.docx'))
  $tpl = DocOf 'template life history.docx'
  Check 'the template is skipped (ignoreDocuments) and its number not used' ($tpl.kind -eq 'ignored' -and -not (Person 'C8,30') -and (Has $NoteMap.ignored 'doc:template life history.docx'))
  Check 'two stories' ((@($snap.stories) -join '|') -eq 'Stories\Family Reunion 1985.docx|Stories\The Old Mill.docx') (@($snap.stories) -join ', ')
  Check 'a number in running text links a person but adds no one (A9,1)' (-not (Person 'A9,1') -and @((Person 'A2,1').mentions | Where-Object { $_ -eq 'text in Stories\The Old Mill.docx' }).Count -eq 1)

  # what the document reader (tools\Update-FamilyTree.ps1) made of the Word features
  $h = BlocksOf 'Ashworth\A1,1 Ashworth Henry.docx'
  Check 'reader: Shift+Enter is a line break' ($h.Contains('{"t":"\n"}'))
  Check 'reader: bold, bigger, superscript, italic, underline' ($h.Contains('{"t":"Henry Lowell Ashworth (A1,1)","f":1,"z":32}') -and $h.Contains('{"t":"rd","f":8,"z":24}') -and $h.Contains('{"t":"Army Air Forces","f":2,"z":24}') -and $h.Contains('{"t":"detailed diary","f":4,"z":24}'))
  Check 'reader: w:hyperlink, with & in the address' ($h.Contains('"h":"https://example.com/records?id=12&page=3"'))
  Check 'reader: a curly apostrophe' ($h.Contains("St. Anne$([char]0x2019)s Church"))
  Check 'reader: a Tab at the start of a line' ($h.Contains('{"r":[{"t":"\t"},{"t":"George Ashworth (1925-1944)","z":24}]}'))
  $rose = BlocksOf 'Ashworth\A3,4 Marsh Rose.docx'
  Check 'reader: HYPERLINK field' ($rose.Contains('{"t":"the family recipe page","h":"https://example.org/recipes","z":24}'))
  $ed = BlocksOf 'Ashworth\A3,3 Thornfield Edward.docx'
  Check 'reader: numbered list, sub-list and bullets (numbering.xml)' ($ed.Contains('"li":{"n":3,"l":1,"f":"lowerLetter","x":"%2.","s":1}') -and $ed.Contains('"li":{"n":2,"l":0,"f":"bullet","x":"' + [char]0xF0B7 + '","s":1}'))
  Check 'reader: table with a spanning and a merged cell' ($ed.Contains('"cs":2') -and $ed.Contains('"vm":"restart"') -and $ed.Contains('"vm":"continue"'))
  $geo = BlocksOf 'Dalby\D3,5 Dalby George.docx'
  Check 'reader: subscript and strike-through' ($geo.Contains('{"t":"2","f":16,"z":24}') -and $geo.Contains('{"t":"Smithy","f":32,"z":24}'))
  Check 'reader: tracked changes, hidden text, a bookmark, an accented letter' ($geo.Contains("{""t"":""He married Emma in 1885 at the Caf$([char]0xE9) Corner chapel."",""z"":24}"))
  $nora = BlocksOf 'Brennan\B2,2 Quinn Nora.docx'
  Check 'reader: the same picture uncropped and cropped gives two files' ($nora.Contains('"img":"media:Brennan\\B2,2 Quinn Nora.docx#1.png?v=mtime","w":40,"h":60,"alt":"Portrait of a woman wearing a hat"') -and $nora.Contains('"img":"media:Brennan\\B2,2 Quinn Nora.docx#2.png?v=mtime","w":40,"h":60,"alt":"Headstone in the churchyard"'))
}

# ================================================================ media
Invoke-Stage 'media' {
  Import-Module (Join-Path $TestsDir 'TestDocx.psm1') -Force
  $data = Read-JsObject (Join-Path $Viewer 'data\data.js')
  $nora = @($data.docs | Where-Object { $_.path -eq 'Brennan\B2,2 Quinn Nora.docx' })[0]
  $dir = Join-Path $Viewer ('data\media\' + $nora.id)
  $one = Join-Path $dir '1.png'; $two = Join-Path $dir '2.png'
  Check 'the pictures of B2,2 were copied out' ([IO.File]::Exists($one) -and [IO.File]::Exists($two)) $dir
  if (-not ([IO.File]::Exists($one) -and [IO.File]::Exists($two))) { return }
  $orig = Get-TestPicture
  $b1 = [IO.File]::ReadAllBytes($one)
  Check 'the uncropped picture is copied byte for byte' ([Convert]::ToBase64String($b1) -eq [Convert]::ToBase64String($orig)) "$($b1.Length) bytes, original $($orig.Length)"
  $b2 = [IO.File]::ReadAllBytes($two)
  $w = ($b2[16] -shl 24) -bor ($b2[17] -shl 16) -bor ($b2[18] -shl 8) -bor $b2[19]
  $hgt = ($b2[20] -shl 24) -bor ($b2[21] -shl 16) -bor ($b2[22] -shl 8) -bor $b2[23]
  Check 'the cropped picture is 10% smaller on every side (32 x 48)' ($w -eq 32 -and $hgt -eq 48) "$w x $hgt"
  $dirs = @([IO.Directory]::GetDirectories((Join-Path $Viewer 'data\media')) | Where-Object { [IO.Path]::GetFileName($_) -ne 'photos' })
  Check 'two documents have pictures' ($dirs.Count -eq 2) (($dirs | ForEach-Object { [IO.Path]::GetFileName($_) }) -join ', ')

  # the photo copies: smaller, upright, PNG stays PNG, one .key each; a second update leaves them alone
  $photoDir = Join-Path $Viewer 'data\media\photos'
  function PhotoCopy([string]$rel) {
    $ph = @($data.photos | Where-Object { $_.path -eq $rel })[0]
    if (-not $ph -or -not $ph.img) { return $null }
    return Join-Path $Viewer ($ph.img.Split('?')[0].Replace('/', '\'))
  }
  $big = PhotoCopy 'Photos\A2,1.jpg'
  $sz = if ($big -and [IO.File]::Exists($big)) { Get-PictureSize $big } else { @(0, 0, $false) }
  Check 'photos: a 1600 x 2000 photo is made 960 x 1200' ($sz[0] -eq 960 -and $sz[1] -eq 1200 -and $big.EndsWith('.jpg')) "$($sz[0]) x $($sz[1]) $big"
  $rot = PhotoCopy 'Photos\C3,1 Joseph.jpg'
  $sz = if ($rot -and [IO.File]::Exists($rot)) { Get-PictureSize $rot } else { @(0, 0, $true) }
  Check 'photos: the camera-rotated 400 x 240 photo is turned upright (240 x 400, no rotation flag left)' ($sz[0] -eq 240 -and $sz[1] -eq 400 -and -not $sz[2]) "$($sz[0]) x $($sz[1]), flag: $($sz[2])"
  $ph = @($data.photos | Where-Object { $_.path -eq 'Photos\C3,1 Joseph.jpg' })[0]
  Check 'photos: data.js has the upright size' ($ph.w -eq 240 -and $ph.h -eq 400) "$($ph.w) x $($ph.h)"
  $png = PhotoCopy 'Photos\B2,2 Nora at 20.png'
  Check 'photos: a PNG stays a PNG' ($png -and $png.EndsWith('.png') -and [IO.File]::Exists($png)) "$png"
  $copies = @([IO.Directory]::GetFiles($photoDir))
  Check 'photos: 9 copies and 9 .key files, nothing else' (@($copies | Where-Object { $_ -match '\\p[0-9a-f]{12}\.(jpg|png)$' }).Count -eq 9 -and @($copies | Where-Object { $_ -match '\\p[0-9a-f]{12}\.key$' }).Count -eq 9 -and $copies.Count -eq 18) (($copies | ForEach-Object { [IO.Path]::GetFileName($_) }) -join ', ')
  $before = @{}; foreach ($f in $copies) { $before[$f] = [IO.File]::GetLastWriteTimeUtc($f).Ticks }
  $code = Invoke-PsFile (Join-Path $Viewer 'tools\Update-FamilyTree.ps1') @('-Quiet', '-Source', $SnapSource) 'media-second-update'
  $same = $true; foreach ($f in $copies) { if (-not [IO.File]::Exists($f) -or [IO.File]::GetLastWriteTimeUtc($f).Ticks -ne $before[$f]) { $same = $false } }
  Check 'photos: a second update keeps the copies as they are' ($code -eq 0 -and $same) "exit $code"
}

# ================================================================ pages
Invoke-Stage 'pages' {
  $json = Invoke-ChromePage 'pages' ((To-FileUrl (Join-Path $Viewer 'index-test.html')) + '?mode=routes') 120000 '__out'
  Write-TestFile (Join-Path $Logs 'pages.json') $json
  $r = $json | ConvertFrom-Json
  if ($r.fatal) { Check 'the viewer built the model' $false $r.fatal; return }
  $res = @($r.results)
  Check 'pages opened' ($res.Count -gt 100) "$($res.Count)"
  $broken = @($res | Where-Object { @($_.errors).Count -or @($_.resources).Count -or $_.broke -or $_.chars -lt 5 })
  foreach ($x in ($broken | Select-Object -First 10)) {
    Check "page $($x.route)" $false ((@($x.errors) + @($x.resources | ForEach-Object { "could not load $_" }) + $(if ($x.broke) { 'Something went wrong' } else { @() }) + $(if ($x.chars -lt 5) { "only $($x.chars) characters" } else { @() })) -join ' | ')
  }
  Check "$($res.Count) pages: no script error, nothing broken or empty" ($broken.Count -eq 0) "$($broken.Count) page(s) with problems"
  Check 'no script error at all' (@($r.state.errors).Count -eq 0) ((@($r.state.errors) | Select-Object -First 5) -join ' | ')
  Check 'every file loaded (scripts, pictures)' (@($r.state.resources).Count -eq 0) ((@($r.state.resources) | Select-Object -First 5) -join ' | ')
  Check 'the page loaded once (no reload: the status has the same version)' ($r.state.loads -eq 1) "$($r.state.loads)"
  function Res([string]$route) { return @($res | Where-Object { $_.route -eq $route })[0] }
  $h = Res '#/help'
  Check 'Help: "Program version" line' ($h.programVersion -eq "Program version $ProgramVersion") $h.programVersion
  Check 'Help: Report a problem is a short mailto link' ($h.mailto -and $h.mailto.start.StartsWith('mailto:family-tree-tests@example.com?subject=') -and $h.mailto.length -le 1800) ($h.mailto | ConvertTo-Json -Compress)
  Check 'Help: Copy the report shows the report' ($h.copy -and $h.copy.textShown -and $h.copy.hasVersion) ($h.copy | ConvertTo-Json -Compress)
  Check 'Notes: the Report a problem link' ([bool](Res '#/notes').notesReport)
  Check 'Tree: 3 to 6 generations' (@((Res '#/tree').generations).Count -eq 4 -and -not (@((Res '#/tree').generations) -match 'no button')) ((@((Res '#/tree').generations)) -join ', ')
  Check 'People: sorting and filters work' (@((Res '#/people').people).Count -ge 8) ((@((Res '#/people').people)) -join ' | ')
  $lb = @($res | Where-Object { $_.lightbox })[0]
  Check 'the picture viewer opens and closes' ($lb -and $lb.lightbox -eq 'opened, closed') $(if ($lb) { $lb.lightbox } else { 'no person with a photo' })
  $phr = @($res | Where-Object { $_.photoHelp } | ForEach-Object { $_.photoHelp })
  $withFile = @($phr | Where-Object { $_.button -eq 'Change photo' })[0]
  $without = @($phr | Where-Object { $_.button -eq 'Add a photo' })[0]
  Check 'person page: "Change photo" opens the box, which names the photo file' ($withFile -and $withFile.hiddenFirst -and $withFile.shown -and $withFile.text -match 'The photo now comes from Photos\\' -and $withFile.enlarged) ($withFile | ConvertTo-Json -Compress)
  Check 'person page: "Add a photo" gives the name and where to save it' ($without -and $without.shown -and @($without.copyName).Count -eq 2 -and @($without.copyName)[1] -eq $without.person -and @($without.copyName)[0] -eq (Join-Path (Join-Path $SnapSource 'Photos') $without.person) -and $without.text -notmatch 'Only the first time') ($without | ConvertTo-Json -Compress)
  Check 'person page: the photo is a square (corners only slightly rounded)' ($withFile -and $withFile.square -and $withFile.square -notmatch '50%') $(if ($withFile) { $withFile.square } else { '' })
  Check 'person page: the square shows the photo copy' ($withFile -and $withFile.img -match '^data/media/photos/p[0-9a-f]{12}\.(jpg|png)\?v=\d+$') $(if ($withFile) { $withFile.img } else { '' })
  $fl = @($res | Where-Object { $_.flagShown } | ForEach-Object { $_.flagShown })[0]
  Check 'person page: the flag in the corner of the square and the "Came from" chip' ($fl -and $fl.inSquare -and $fl.chip -match '^Came from ' -and $fl.loaded) ($fl | ConvertTo-Json -Compress)
  $code = @($res | Where-Object { $_.landedOn })[0]
  Check 'a number typed in the search goes to that person' ($code -and $code.landedOn -like '#/p/*') $(if ($code) { $code.landedOn } else { '' })
  $sb = @($res | Where-Object { $_.searchBox })[0]
  Check 'the search box searches' ($sb -and $sb.searchBox -eq '#/search/mill') $(if ($sb) { $sb.searchBox } else { '' })
  Note "$($res.Count) pages opened"
}

# ================================================================ settings missing / broken
Invoke-Stage 'settings' {
  $settings = Join-Path $Viewer 'family-settings.js'
  $saved = Assert-InsideOut (Join-Path $OutFull 'family-settings.saved.js')
  [IO.File]::Copy($settings, $saved, $true)
  try {
    [IO.File]::Delete((Assert-InsideOut $settings))
    $j = Invoke-ChromePage 'settings-missing' ((To-FileUrl (Join-Path $Viewer 'index-test.html')) + '?mode=idle') 6000 '__out' | ConvertFrom-Json
    Check 'missing settings: the friendly card' ($j.settingsCard -and $j.settingsProblem -eq 'missing' -and $j.main -match 'The family settings are missing') "$($j.settingsProblem) | $($j.main)"
    Check 'missing settings: no script error' (@($j.errors).Count -eq 0) (@($j.errors) -join ' | ')
    Check 'missing settings: only family-settings.js failed to load' (@($j.resources).Count -eq 1 -and @($j.resources)[0] -match 'family-settings\.js$') (@($j.resources) -join ' | ')

    Write-TestFile $settings "window.FAMILY_SETTINGS = { title: 'Broken', lines: { A: { name: 'A' } "
    $j = Invoke-ChromePage 'settings-broken' ((To-FileUrl (Join-Path $Viewer 'index-test.html')) + '?mode=idle') 6000 '__out' | ConvertFrom-Json
    Check 'broken settings: the friendly card' ($j.settingsCard -and $j.settingsProblem -eq 'broken' -and $j.main -match 'cannot be used') "$($j.settingsProblem) | $($j.main)"
    $other = @($j.errors | Where-Object { $_ -notmatch 'family-settings\.js' })
    Check 'broken settings: the only script error is the one inside family-settings.js' ($other.Count -eq 0) (@($j.errors) -join ' | ')
  } finally {
    [IO.File]::Copy($saved, (Assert-InsideOut $settings), $true)
  }
}

# ================================================================ reload when a new program version was installed
Invoke-Stage 'reload' {
  $statusFile = Join-Path $Viewer 'data\status.js'
  $saved = Assert-InsideOut (Join-Path $OutFull 'status.saved.js')
  [IO.File]::Copy($statusFile, $saved, $true)
  $orig = [IO.File]::ReadAllText($statusFile)
  try {
    $other = $orig.Replace('"version":"' + $ProgramVersion + '"', '"version":"0.0.1-test"')
    Check 'status.js has the version to replace' ($other -ne $orig)
    Write-TestFile $statusFile $other
    # (the page reads status.js as soon as it opens; 20 s of page time also covers the polls after the reload)
    $j = Invoke-ChromePage 'reload' ((To-FileUrl (Join-Path $Viewer 'index-test.html')) + '?mode=idle') 20000 '__out' | ConvertFrom-Json
    Check 'another version in status.js: the page reloads exactly once' ($j.loads -eq 2 -and $j.reloadedFor -eq '0.0.1-test') "loads $($j.loads), reloaded for '$($j.reloadedFor)'"
    Check 'reload: no script error' (@($j.errors).Count -eq 0) (@($j.errors) -join ' | ')

    $msg = 'Test: the program was updated.'
    Write-TestFile $statusFile ($orig.TrimEnd().TrimEnd(';').TrimEnd('}') + ',"programMessage":"' + $msg + '"};')
    $j = Invoke-ChromePage 'program-message' ((To-FileUrl (Join-Path $Viewer 'index-test.html')) + '?mode=idle') 12000 '__out' | ConvertFrom-Json
    Check 'same version: no reload, the program message is shown' ($j.loads -eq 1 -and $j.bar -match [regex]::Escape($msg)) "loads $($j.loads), bar '$($j.bar)'"
    Check 'program message: no script error' (@($j.errors).Count -eq 0) (@($j.errors) -join ' | ')
  } finally {
    [IO.File]::Copy($saved, (Assert-InsideOut $statusFile), $true)
  }
}

# ================================================================ Compare-Trees
Invoke-Stage 'compare' {
  $code = Invoke-PsFile (Join-Path $TestsDir 'Compare-Trees.ps1') @('-Data', (Join-Path $Viewer 'data\data.js'), '-BaseDir', $Viewer, '-NewDir', $Viewer, '-Out', (Join-Path $OutFull 'compare-trees'), '-Chrome', $ChromeExe, '-Quiet') 'compare-trees' 300
  $report = ''; $rf = Join-Path $OutFull 'compare-trees\report.txt'; if ([IO.File]::Exists($rf)) { $report = [IO.File]::ReadAllText($rf) }
  Check 'Compare-Trees.ps1 finds the test tree identical to itself' ($code -eq 0 -and $report -match 'RESULT: IDENTICAL') ("exit $code; " + (Get-Log 'compare-trees') + ' ' + ([regex]::Match($report, 'RESULT:[^\r\n]*').Value))
}

# ================================================================ e2e: the document updater on changing documents
Invoke-Stage 'e2e' {
  Import-Module (Join-Path $TestsDir 'TestDocx.psm1') -Force
  $root = Join-Path $OutFull 'e2e\life history'
  $view = Join-Path $root 'Family Tree Viewer'
  $code = Invoke-PsFile (Join-Path $TestsDir 'New-TestFamily.ps1') @('-Path', $root, '-Quiet') 'e2e-family'
  if ($code -ne 0) { Check 'the e2e test family was made' $false (Get-Log 'e2e-family'); return }
  foreach ($rel in @('index.html', 'tools\Update-FamilyTree.ps1') + @([IO.Directory]::GetFiles((Join-Path $RepoDir 'app')) | ForEach-Object { 'app\' + [IO.Path]::GetFileName($_) })) {
    Copy-TestFile (Join-Path $RepoDir $rel) (Join-Path $view $rel)
  }
  Copy-TestFile (Join-Path $RepoDir 'family-settings.example.js') (Join-Path $view 'family-settings.js')
  $data = Join-Path $view 'data'
  $script:E2eN = 0
  function Update([string]$label, [string[]]$extra = @(), [switch]$NoSource) {
    $script:E2eN++
    $a = @('-Quiet') + $extra
    if (-not $NoSource) { $a += @('-Source', $root) }
    $c = Invoke-PsFile (Join-Path $view 'tools\Update-FamilyTree.ps1') $a ('e2e-{0:D2}-{1}' -f $script:E2eN, $label)
    return $c
  }
  function DataText { return [IO.File]::ReadAllText((Join-Path $data 'data.js'), [Text.Encoding]::UTF8) }
  function Status { return Read-JsObject (Join-Path $data 'status.js') }
  function Errors { return @((Read-JsObject (Join-Path $data 'data.js')).errors) }
  function DocId([string]$rel) { return @((Read-JsObject (Join-Path $data 'data.js')).docs | Where-Object { $_.path -eq $rel })[0].id }
  $now = [DateTime]::UtcNow

  # first build, then nothing changed
  $c = Update 'first'
  $st = Status
  Check 'first update: exit 0, 27 documents' ($c -eq 0 -and $st.total -eq 27) "exit $c, total $($st.total)"
  $built1 = $st.built
  Start-Sleep -Milliseconds 1100
  $c = Update 'no-change'
  $st = Status
  Check 'nothing changed: data.js is left as it was' ($c -eq 0 -and $st.changed -eq 0 -and $st.built -eq $built1 -and (Read-JsObject (Join-Path $data 'data.js')).built -eq $built1) "changed $($st.changed), built $($st.built) / $built1"

  # added: one in an existing folder, one in a new sub-folder
  New-TestDocx -Path (Join-Path $root 'Ashworth\A4,8 Garvey Martha.docx') -Time $now.AddMinutes(-30) -Paragraphs @('Martha Garvey (A4,8)', '1840-1910', 'Descendant: Rose Ellen Marsh (A3,4)', '', 'Martha came from the hill country.')
  New-TestDocx -Path (Join-Path $root 'New Branch\The Fire of 1903.docx') -Time $now.AddMinutes(-29) -Paragraphs @('The Fire of 1903', '', 'The fire started in the mill office (A3,1) and burned for two days.')
  $c = Update 'added'
  $st = Status; $t = DataText
  Check 'added 2 documents (one in a new folder)' ($c -eq 0 -and $st.added -eq 2 -and $st.changed -eq 2 -and $t.Contains('"path":"Ashworth\\A4,8 Garvey Martha.docx"') -and $t.Contains('"path":"New Branch\\The Fire of 1903.docx"')) "exit $c, added $($st.added), changed $($st.changed)"

  # changed
  New-TestDocx -Path (Join-Path $root 'Ashworth\A3,4 Marsh Rose.docx') -Force -Time $now.AddMinutes(-20) -Paragraphs @('Rose Ellen Marsh (A3,4)', '1868-1950', '', 'EDITED VERSION of the story.')
  $c = Update 'changed'
  $st = Status; $t = DataText
  Check 'changed 1 document: the new text is in, the old text is gone' ($c -eq 0 -and $st.changed -eq 1 -and $st.added -eq 0 -and $t.Contains('EDITED VERSION') -and -not $t.Contains('recipe book')) "exit $c, changed $($st.changed)"

  # removed (a document with pictures), with things a person saved inside data\ that must be kept
  $noraRel = 'Brennan\B2,2 Quinn Nora.docx'
  $noraId = DocId $noraRel
  $noraMedia = Join-Path $data "media\$noraId"
  Write-TestFile (Join-Path $data 'cache\My notes.docx') 'pretend document'
  Write-TestFile (Join-Path $data 'media\Family photos\scan1.jpg') 'pretend photo'
  Write-TestFile (Join-Path $noraMedia 'keep me.txt') 'a note'
  [IO.File]::Delete((Assert-InsideOut (Join-Path $root $noraRel)))
  $c = Update 'removed'
  $st = Status; $t = DataText
  Check 'removed 1 document: gone from data.js and its cache' ($c -eq 0 -and $st.removed -eq 1 -and -not $t.Contains('B2,2 Quinn Nora') -and -not [IO.File]::Exists((Join-Path $data "cache\$noraId.json"))) "exit $c, removed $($st.removed)"
  Check 'removed: its generated pictures are deleted' (@([IO.Directory]::GetFiles($noraMedia) | Where-Object { [IO.Path]::GetFileName($_) -match '^\d+\.' }).Count -eq 0)
  Check 'removed: files a person put in data\ are kept' ([IO.File]::Exists((Join-Path $noraMedia 'keep me.txt')) -and [IO.File]::Exists((Join-Path $data 'cache\My notes.docx')) -and [IO.File]::Exists((Join-Path $data 'media\Family photos\scan1.jpg')))

  # photos: one replaced by a new picture, one removed, one added; a file a person put in the photo copies is kept
  function PhotoOf([string]$rel) { return @((Read-JsObject (Join-Path $data 'data.js')).photos | Where-Object { $_.path -eq $rel })[0] }
  $old = PhotoOf 'Photos\ruth.jpg'
  $gone = PhotoOf 'Photos\D3,8.jpg'
  $goneCopy = Join-Path $view ($gone.img.Split('?')[0].Replace('/', '\'))
  Write-TestFile (Join-Path $data 'media\photos\my crop.jpg') 'pretend photo'
  New-TestPhoto -Path (Join-Path $root 'Photos\ruth.jpg') -Force -Width 500 -Height 500 -Time $now.AddMinutes(-15)
  [IO.File]::Delete((Assert-InsideOut (Join-Path $root 'Photos\D3,8.jpg')))
  New-TestPhoto -Path (Join-Path $root 'Photos\A3,4 Rose.jpg') -Width 200 -Height 300 -Time $now.AddMinutes(-14)
  $c = Update 'photos'
  $new = PhotoOf 'Photos\ruth.jpg'
  Check 'photos: a replaced photo is made again (new size, new address)' ($c -eq 0 -and $new.w -eq 500 -and $new.h -eq 500 -and $new.img -ne $old.img) "exit $c; $($new.w) x $($new.h)"
  Check 'photos: a removed photo is gone, with its copy' (-not (PhotoOf 'Photos\D3,8.jpg') -and -not [IO.File]::Exists($goneCopy)) $goneCopy
  Check 'photos: an added photo is in' ((PhotoOf 'Photos\A3,4 Rose.jpg').w -eq 200)
  Check 'photos: a file a person put among the photo copies is kept' ([IO.File]::Exists((Join-Path $data 'media\photos\my crop.jpg')))

  # damaged, empty, lock file
  New-CorruptDocx -Path (Join-Path $root 'Carrow\C5,1 Broken Two.docx') -Time $now.AddMinutes(-10)
  New-WordLockFile -Path (Join-Path $root 'Carrow\~$C5,1 Broken Two.docx')
  [IO.File]::WriteAllBytes((Assert-InsideOut (Join-Path $root 'Dalby\D5,9 Empty.docx')), [byte[]]@())
  $c = Update 'damaged'
  $errs = Errors; $t = DataText
  $e1 = @($errs | Where-Object { $_.path -eq 'Carrow\C5,1 Broken Two.docx' })[0]
  $e2 = @($errs | Where-Object { $_.path -eq 'Dalby\D5,9 Empty.docx' })[0]
  Check 'a damaged document: listed with a plain message, the update still succeeds' ($c -eq 0 -and $e1 -and $e1.msg -match 'damaged' -and $e1.cached -eq $false) "exit $c; $($e1.msg)"
  Check 'an empty document: "this document is empty"' ($e2 -and $e2.msg -match 'empty') "$($e2.msg)"
  Check 'the lock file is not read' (-not $t.Contains('~$C5,1'))

  # a document held open by another program that allows no reading at all
  $samRel = 'Ashworth\A2,1 Ashworth Samuel.docx'
  $samPath = Join-Path $root $samRel
  [IO.File]::SetLastWriteTimeUtc($samPath, $now.AddMinutes(-5))
  $lock = [IO.File]::Open($samPath, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
  try { $c = Update 'locked' } finally { $lock.Dispose() }
  $e3 = @(Errors | Where-Object { $_.path -eq $samRel })[0]
  $t = DataText
  Check 'a locked document: "in use", the last version is kept' ($c -eq 0 -and $e3 -and $e3.msg -match 'in use' -and $e3.cached -eq $true -and $t.Contains('grist mill')) "exit $c; $($e3.msg); cached $($e3.cached)"
  $c = Update 'unlocked'
  Check 'after it is closed it is read again' ($c -eq 0 -and -not @(Errors | Where-Object { $_.path -eq $samRel }).Count) "exit $c"

  # a change of capital letters only
  [IO.File]::Move((Assert-InsideOut (Join-Path $root 'Stories\The Old Mill.docx')), (Assert-InsideOut (Join-Path $root 'Stories\the old mill.docx')))
  $c = Update 'case-rename'
  $t = DataText
  Check 'a rename that only changes capital letters is picked up' ($c -eq 0 -and $t.Contains('"path":"Stories\\the old mill.docx"') -and -not $t.Contains('"path":"Stories\\The Old Mill.docx"')) "exit $c"

  # a copy of the viewer inside the documents folder is not read
  Copy-TestTree $view (Join-Path $root 'Family Tree Viewer - Copy')
  New-TestDocx -Path (Join-Path $root 'Family Tree Viewer - Copy\data\A9,9 Inside Copy.docx') -Time $now -Paragraphs @('Someone (A9,9)')
  $c = Update 'viewer-copy'
  Check 'a copy of the viewer folder is skipped' ($c -eq 0 -and -not (DataText).Contains('Family Tree Viewer - Copy')) "exit $c"

  # tools\settings.txt with a relative, quoted folder (and no -Source)
  Write-TestFile (Join-Path $view 'tools\settings.txt') 'SourceFolder = ".."'
  $c = Update 'settings-txt' -NoSource
  Check 'tools\settings.txt: a relative, quoted SourceFolder' ($c -eq 0 -and (Read-JsObject (Join-Path $data 'data.js')).source -eq $root) "exit $c; source $((Read-JsObject (Join-Path $data 'data.js')).source)"
  [IO.File]::Delete((Assert-InsideOut (Join-Path $view 'tools\settings.txt')))

  # a junction in place of data\media must stop the run without touching where it points
  $victim = Join-Path $OutFull 'e2e\victim'
  Write-TestFile (Join-Path $victim 'precious.docx') 'precious'
  $media = Join-Path $data 'media'
  [IO.Directory]::Move((Assert-InsideOut $media), (Assert-InsideOut "$media.real"))
  $mk = & cmd.exe /c mklink /J "$media" "$victim"
  $isJunction = [IO.Directory]::Exists($media) -and ([IO.File]::GetAttributes($media) -band [IO.FileAttributes]::ReparsePoint)
  Check 'a junction could be made for the test' ([bool]$isJunction) "$mk"
  if ($isJunction) {
    try {
      $c = Update 'junction' @('-Full')
      $st = Status
      $left = @([IO.Directory]::GetFileSystemEntries($victim) | ForEach-Object { [IO.Path]::GetFileName($_) })
      Check 'a junction in data\ stops the update (exit 1, SAFETY STOP)' ($c -eq 1 -and $st.state -eq 'error' -and $st.msg -match 'SAFETY STOP') "exit $c; $($st.state): $($st.msg)"
      Check 'the junction target is untouched' ([IO.File]::ReadAllText((Join-Path $victim 'precious.docx')) -eq 'precious' -and $left.Count -eq 1) ($left -join ', ')
    } finally {
      [IO.Directory]::Delete((Assert-InsideOut $media))          # removes only the junction itself
      [IO.Directory]::Move((Assert-InsideOut "$media.real"), (Assert-InsideOut $media))
    }
  }
  $c = Update 'after-junction'
  Check 'after the junction is gone, the update works again' ($c -eq 0 -and (Status).state -eq 'done') "exit $c"
  Note "$($script:E2eN) updater runs"
}

# ================================================================ tests\updater\Test-*.ps1
Invoke-Stage 'updater' {
  $dir = Join-Path $TestsDir 'updater'
  $tests = @()
  if ([IO.Directory]::Exists($dir)) { $tests = @([IO.Directory]::GetFiles($dir, 'Test-*.ps1') | Sort-Object) }
  if (-not $tests.Count) { Note 'no tests\updater\Test-*.ps1 found'; return }
  foreach ($t in $tests) {
    $name = [IO.Path]::GetFileNameWithoutExtension($t)
    $own = Join-Path $OutFull "updater\$name"
    [void][IO.Directory]::CreateDirectory((Assert-InsideOut $own))
    $env:FAMILYTREE_TEST_OUT = $own
    $env:FAMILYTREE_TEST_REPO = $RepoDir
    $env:FAMILYTREE_TEST_CHROME = $ChromeExe
    $t0 = Get-Date
    $code = Invoke-PsFile $t @() "updater-$name" 900
    $log = Get-Log "updater-$name"
    if ($log.Length -gt 1500) { $log = '...' + $log.Substring($log.Length - 1500) }
    Check ("{0} ({1:N0} s)" -f $name, ((Get-Date) - $t0).TotalSeconds) ($code -eq 0) ("exit $code`n" + $log)
  }
}

# ================================================================ summary
$chromeDir = Join-Path $OutFull 'chrome'
try { if ([IO.Directory]::Exists($chromeDir) -and [IO.Directory]::GetFileSystemEntries($chromeDir).Length -eq 0) { [IO.Directory]::Delete((Assert-InsideOut $chromeDir)) } } catch { }
$total = ((Get-Date) - $StartedAt).TotalSeconds
$failed = @($Results | Where-Object { -not $_.Ok })
$lines = New-Object System.Collections.Generic.List[string]
$lines.Add('Family Tree Viewer tests  ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
$lines.Add("program: $RepoDir (version $ProgramVersion)")
$lines.Add("test files: $OutFull")
$lines.Add('')
$lines.Add('stage       checks  failed  seconds')
foreach ($s in $AllStages) {
  if (-not $StageTimes.Contains($s)) { continue }
  $mine = @($Results | Where-Object { $_.Stage -eq $s })
  $lines.Add(('{0,-10} {1,7} {2,7} {3,8:N1}' -f $s, $mine.Count, @($mine | Where-Object { -not $_.Ok }).Count, $StageTimes[$s]))
}
foreach ($x in @($Results | Where-Object { $_.Stage -notin $AllStages })) { $lines.Add(('{0,-10} {1}' -f $x.Stage, $x.Name)) }
$lines.Add('')
$lines.Add(('total: {0} checks, {1} failed, {2:N0} s, {3} Chrome runs' -f $Results.Count, $failed.Count, $total, $script:ChromeRuns))
$lines.Add($(if ($failed.Count) { 'RESULT: FAILED' } else { 'RESULT: PASSED' }))
$lines.Add('')
foreach ($x in $Results) { $lines.Add(('{0}  {1,-9} {2}{3}' -f $(if ($x.Ok) { 'pass' } else { 'FAIL' }), $x.Stage, $x.Name, $(if (-not $x.Ok -and $x.Detail) { "`n        " + ($x.Detail -replace "`n", "`n        ") } else { '' }))) }
[IO.File]::WriteAllText((Join-Path $OutFull 'results.txt'), (($lines -join "`r`n") + "`r`n"), $Utf8)
Write-Host ''
for ($i = 4; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '^(pass|FAIL)  ') { break }; Write-Host $lines[$i] }
Write-Host "details: $(Join-Path $OutFull 'results.txt')"
if ($failed.Count) { exit 1 }
exit 0
