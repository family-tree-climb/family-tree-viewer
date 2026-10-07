<#
  Update-Program.ps1
  ------------------
  Keeps the Family Tree Viewer PROGRAM up to date, with automatic rollback. (The life-history documents are
  read by tools\Update-FamilyTree.ps1; this script runs that first, exactly as before.)

  What the desktop icon does ("Open Family Tree.cmd" runs a TEMP copy of this script, because an update may
  replace this very file):
    1. Opens the tree in the web browser at once and runs the document update, exactly as
       tools\Update-FamilyTree.ps1 -Open -Quiet did before 1.0 (index.html is opened first; the document update
       runs inside this PowerShell; if another document update is busy, it is not waited for).
       If it fails, an automatic problem report is sent (at most once a day per kind of problem).
    2. At most once a day: asks GitHub for the latest release (time-out 5 s; offline or any error: one log
       line, nothing else). Nothing happens unless the release is newer than the installed version.
    3. Downloads the release zip and its .sha256 into updates\<version>\, checks the hash, unpacks it and
       checks it against the allow-list rules (tools\program-files.txt).
    4. Measures the tree with tools\Check-Tree.ps1 (the "before" picture).
    5. Installs: under the document-update lock, saves the current program files (with a manifest) into
       updates\<version>\previous\, copies the new files in, and removes files that are no longer part of
       the program. Once the new version is accepted, that saved copy becomes program-previous\ (so after a
       version was taken back, program-previous\ still holds the version before the current one).
       A file the new version brings that already existed here without being a program file (e.g. private
       notes) is first copied to updates\kept\<date>\, which is never deleted.
    6. Verifies: runs the NEW document update and Check-Tree again. If anything is wrong (failed update,
       unreadable data.js, a tree that cannot be built, fewer documents attached or fewer known people, a
       root person missing), the previous version is put back and a problem report is sent. The previous
       version is then checked the same way: if it works, the new version is never tried again; if it has
       problems too (so the computer may be at fault), the new version is tried again on another day, and
       only counts as bad after 3 such days. While the documents cannot be read, no new version is tried
       (for at most 3 days).
    7. Writes one line for the open page ("programMessage" in data\status.js); the page reloads itself when
       it sees the new version.

  Usage (Windows PowerShell 5.1):
    powershell -NoProfile -ExecutionPolicy Bypass -File Update-Program.ps1 -Viewer <viewer folder> [options]
      -Open              open the tree in the web browser (the desktop icon)
      -CheckNow          ignore the once-a-day rule
      -Rollback          put back the previous version from program-previous\ ("Go back to the previous version.cmd")
      -InstallZip <zip>  install this release zip (family-tree-viewer-<version>.zip, with its .sha256 next to it)
                         instead of asking GitHub; -Force also installs an older or the same version
      -SettingsFrom <f>  only for the first install over a program from before 1.0: the family-settings.js to
                         use when the viewer has none (an existing family-settings.js is never replaced)
      -ReleaseUrl <url>  for tests: a "latest release" JSON (http(s) address or local file) instead of GitHub
      -NoDocumentUpdate  skip step 1 (tests, or when the documents were just read)
      -ValidateZip <zip> only check a release zip against the rules and print the result (changes nothing)
      -SelfTest          only check that this script starts and can read the installation (changes nothing)
      -Chrome <exe>|none passed to Check-Tree.ps1 ("none" = no health-check page; exit code and data.js decide)
      -MutexWaitSec <n>  how long to wait for a running document update before installing (default 600)
      -PauseInSwapSec <n> for tests: pause while the files are being swapped (the lock is held)
      -Quiet             no console output

  Exit code: 0 = done (nothing to do, installed, rolled back on request, or offline: quietly skipped)
             1 = something failed (release refused, new version taken back, document update failed, error)
             2 = could not run (wrong -Viewer, family-settings.js missing, nothing to roll back, busy)

  SAFETY PROMISE
    * The life-history documents are never opened by this script (Update-FamilyTree.ps1 reads them, read-only).
    * Inside the viewer folder it only changes: files named in the installed or the new tools\program-files.txt,
      updates\, program-previous\ and the "programMessage" line of data\status.js. On the first install
      over a program from before 1.0 it may also CREATE family-settings.js from -SettingsFrom (never replace it).
    * data\ (except status.js), dev\, family-settings.js and tools\settings.txt are never touched, and nothing
      outside the viewer folder is (except this script's own temporary copies in %TEMP%).
    * Every write and delete checks the full path first and refuses junctions and symbolic links.
    * Every file it writes goes through a temporary file that is flushed to the disk before it is moved into
      place. An install interrupted by a power cut is undone at the next start (as far as the saved copies
      allow; if not every file can be put back, the latest release is installed completely).
    * Automatic reports carry error lines only, with folders and document file names replaced by
      "<folder>" and the document's number.
#>
param(
  [string]$Viewer = '',
  [switch]$Open,
  [switch]$CheckNow,
  [switch]$Rollback,
  [string]$InstallZip = '',
  [switch]$Force,
  [string]$SettingsFrom = '',
  [string]$ReleaseUrl = '',
  [switch]$NoDocumentUpdate,
  [string]$ValidateZip = '',
  [switch]$SelfTest,
  [string]$Chrome = '',
  [int]$MutexWaitSec = 600,
  [int]$PauseInSwapSec = 0,
  [switch]$Quiet
)
$ErrorActionPreference = 'Stop'

# -Open (the desktop icon): open the tree in the web browser FIRST, before anything else, exactly as
# Update-FamilyTree.ps1 -Open does (the page shows what is there now and refreshes itself when the documents
# have been read). Not when an earlier program update was interrupted: that is repaired first (below).
# $global:FamilyTreeUpdaterStarted tells the launcher in "Open Family Tree.cmd" that this script runs and takes
# care of reading the documents; if it stays $false (e.g. this file could not even be parsed), the launcher
# runs tools\Update-FamilyTree.ps1 -Open -Quiet itself.
$global:FamilyTreeUpdaterStarted = $true
$script:PageOpened = $false
if ($Open -and -not $Rollback -and -not $SelfTest -and -not $ValidateZip) {
  try {
    $early = $Viewer
    if (-not $early) { $early = Split-Path -Parent $PSScriptRoot }
    if (-not [System.IO.File]::Exists((Join-Path $early 'updates\install-in-progress.txt')) -and [System.IO.File]::Exists((Join-Path $early 'index.html'))) {
      Start-Process -FilePath (Join-Path $early 'index.html')
      $script:PageOpened = $true
    }
  } catch { }
}

# ------------------------------------------------------------------------------------------------
# The GitHub repository that publishes the releases (the only place it is named).
$RepoSlug = 'family-tree-climb/family-tree-viewer'
$LatestReleaseUrl = "https://api.github.com/repos/$RepoSlug/releases/latest"
# ------------------------------------------------------------------------------------------------

# The program files of the versions before 1.0, which had no tools\program-files.txt. Used only to
# upgrade such an installation; anything else in its folder (CLAUDE.md, HANDOFF.md, dev\, ...) is left alone.
$PreOneProgramFiles = @('index.html', 'Open Family Tree.cmd', 'README.txt', 'app/app.js', 'app/config.js', 'app/genealogy.js',
  'app/render.js', 'app/style.css', 'tools/Update-FamilyTree.ps1', 'tools/Install-FamilyTree.ps1', 'tools/family-tree.ico')
# A release must contain these (also the emergency "Go back" and the health check, so no release can drop them).
$RequiredFiles = @('index.html', 'Open Family Tree.cmd', 'Go back to the previous version.cmd', 'app/version.js', 'app/config.js',
  'tools/Update-FamilyTree.ps1', 'tools/Update-Program.ps1', 'tools/program-files.txt', 'tools/Check-Tree.ps1', 'tools/check-tree.html')

$DocMutexName = 'Local\FamilyTreeViewerUpdate'            # the document update's lock (Update-FamilyTree.ps1)
# One program updater at a time per installation: 'Local\FamilyTreeViewerProgramUpdate-<16 hex of the SHA-1
# of the viewer folder, lower case>' (set below, once the folder is known).
$ProgramMutexName = ''
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$script:TestMode = [bool]$ReleaseUrl
$script:MayWrite = $false
$script:AllowedTargets = $null       # program files that may be written right now (during install / rollback)
$script:MayCreateSettings = $false   # only while copying -SettingsFrom on a first install
$script:DocumentsFailed = $false     # the document update of this start failed (step 1)
$script:NotRestored = New-Object System.Collections.Generic.List[string]
$script:LogLines = New-Object System.Collections.Generic.List[string]
$script:State = @{}

function Say([string]$msg) { if (-not $Quiet) { Write-Host $msg } }
function Write-Log([string]$msg) {
  $script:LogLines.Add((Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + '  ' + $msg)
  Say $msg
}

# ---------------------------------------------------------------- small helpers
$script:JsonEsc = New-Object System.Text.RegularExpressions.Regex('[\\"\u0000-\u001f]')
$script:JsonEval = [System.Text.RegularExpressions.MatchEvaluator] {
  param($m)
  $c = [int][char]$m.Value
  switch ($c) { 34 { '\"' } 92 { '\\' } 10 { '\n' } 13 { '\r' } 9 { '\t' } default { '\u{0:x4}' -f $c } }
}
function JStr([string]$s) { return '"' + $script:JsonEsc.Replace([string]$s, $script:JsonEval) + '"' }
function Read-Shared([string]$path) {
  $fs = New-Object IO.FileStream($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
  try { return (New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8, $true)).ReadToEnd() } finally { $fs.Dispose() }
}
function Get-FileSha256([string]$path) {
  $sha = [Security.Cryptography.SHA256]::Create()
  $fs = New-Object IO.FileStream($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::Read -bor [IO.FileShare]::Delete))
  try { return (($sha.ComputeHash($fs) | ForEach-Object { $_.ToString('x2') }) -join '') } finally { $fs.Dispose(); $sha.Dispose() }
}
function Get-Short([string]$s, [int]$max) { if (-not $s) { return '' }; $s = $s.Trim(); if ($s.Length -gt $max) { return $s.Substring(0, $max) + '...' }; return $s }
function Get-UtcNow { return (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }
function Get-Today { return (Get-Date).ToString('yyyy-MM-dd') }

# ---------------------------------------------------------------- versions
function Get-VersionFromText([string]$text) {
  $m = [regex]::Match([string]$text, 'FAMILY_VERSION\s*=\s*[''"]([0-9A-Za-z.+-]{1,40})[''"]')
  if ($m.Success) { return $m.Groups[1].Value }
  return ''
}
function ConvertTo-VersionParts([string]$v) {
  $m = [regex]::Match([string]$v, '^\s*[vV]?(\d{1,6})\.(\d{1,6})\.(\d{1,6})')
  if (-not $m.Success) { return $null }
  return , ([int[]]@([int]$m.Groups[1].Value, [int]$m.Groups[2].Value, [int]$m.Groups[3].Value))
}
function Compare-Versions([string]$a, [string]$b) {
  $x = ConvertTo-VersionParts $a; $y = ConvertTo-VersionParts $b
  if (-not $x) { $x = @(0, 0, 0) }
  if (-not $y) { $y = @(0, 0, 0) }
  for ($i = 0; $i -lt 3; $i++) { if ($x[$i] -lt $y[$i]) { return -1 }; if ($x[$i] -gt $y[$i]) { return 1 } }
  return 0
}
function Get-ReleaseVersion([string]$tag) {
  # a release tag is v<major>.<minor>.<patch> (numbers only); returns '' for anything else
  $m = [regex]::Match([string]$tag, '^\s*[vV]?(\d{1,6})\.(\d{1,6})\.(\d{1,6})\s*$')
  if (-not $m.Success) { return '' }
  return '{0}.{1}.{2}' -f [int]$m.Groups[1].Value, [int]$m.Groups[2].Value, [int]$m.Groups[3].Value
}
function Show-Version([string]$v) { if ($v) { return $v } return 'from before 1.0' }

# ---------------------------------------------------------------- the allow-list rules
# A program file path: relative, with "/", no "..", no ":", no backslash, never inside the family's or the
# updater's own folders. Returns '' when the path is acceptable, otherwise the reason.
$ForbiddenFirstFolders = @('data', 'dev', 'updates', 'program-previous', '.git')
$ForbiddenFiles = @('family-settings.js', 'tools/settings.txt')
function Test-ProgramPath([string]$rel) {
  if (-not $rel) { return 'empty name' }
  if ($rel.Length -gt 200) { return 'name too long' }
  if ($rel.Contains('\')) { return 'backslash in the name' }
  if ($rel.Contains(':')) { return 'colon in the name (a drive letter or a stream)' }
  if ($rel.StartsWith('/')) { return 'absolute path' }
  if ($rel -match '[\x00-\x1f<>"|?*]') { return 'character not allowed in a file name' }
  $segs = $rel.Split('/')
  foreach ($s in $segs) {
    if ($s -eq '') { return 'empty folder name ("//" or a "/" at the end)' }
    if ($s -eq '.' -or $s -eq '..') { return '"." or ".." in the path' }
    if ($s.EndsWith('.') -or $s.EndsWith(' ') -or $s.StartsWith(' ')) { return 'a name that starts with a space or ends with a dot or a space' }
    if ($s -match '^(con|prn|aux|nul|com[0-9]|lpt[0-9])(\..*)?$') { return 'a reserved Windows name' }
    # "~" could be a short (8.3) alias of another file, e.g. FAMILY~1.JS for family-settings.js
    if ($s.Contains('~')) { return 'a "~" in the name (it could be the short name of another file)' }
  }
  if ($ForbiddenFirstFolders -contains $segs[0]) { return "inside $($segs[0])/ (it belongs to the family or to the updater, never to the program)" }
  foreach ($x in $ForbiddenFiles) { if ($rel -ieq $x) { return "$x belongs to the family, never to the program" } }
  return ''
}
# Reads an allow-list text. Returns @{ Files = list; Problems = list }.
function Read-ProgramList([string]$text) {
  $files = New-Object System.Collections.Generic.List[string]
  $problems = New-Object System.Collections.Generic.List[string]
  $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
  $n = 0
  foreach ($line in ([string]$text -split "\r?\n")) {
    $n++
    $t = $line.Trim().TrimStart([char]0xFEFF).Trim()
    if (-not $t -or $t.StartsWith('#')) { continue }
    $why = Test-ProgramPath $t
    if ($why) { $problems.Add("line ${n} '$t': $why"); continue }
    if (-not $seen.Add($t)) { $problems.Add("line ${n} '$t' is listed twice"); continue }
    $files.Add($t)
  }
  if (-not $seen.Contains('tools/program-files.txt')) { $problems.Add('it does not list itself (tools/program-files.txt)') }
  return @{ Files = $files; Problems = $problems }
}

# Checks a release zip against the rules; with $extractTo also unpacks it there.
# Returns @{ Ok; Problems; Files; Version }.
function Test-ReleaseZip([string]$zipPath, [string]$expectVersion, [string]$extractTo) {
  Add-Type -AssemblyName System.IO.Compression
  $problems = New-Object System.Collections.Generic.List[string]
  $result = @{ Ok = $false; Problems = $problems; Files = $null; Version = '' }
  $zip = $null
  try {
    $fs = [IO.File]::Open($zipPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try { $zip = New-Object IO.Compression.ZipArchive($fs, [IO.Compression.ZipArchiveMode]::Read) } catch { $fs.Dispose(); throw }
  } catch { $problems.Add("it is not a readable zip file ($($_.Exception.Message))"); return $result }
  try {
    $entries = @($zip.Entries)
    if ($entries.Count -gt 1000) { $problems.Add("it holds too many files ($($entries.Count))"); return $result }
    $names = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $fileEntries = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)
    [long]$total = 0
    foreach ($e in $entries) {
      $name = $e.FullName
      $isDir = $name.EndsWith('/') -and $e.Length -eq 0
      $check = $name
      if ($isDir) { $check = $name.Substring(0, $name.Length - 1) }
      $why = Test-ProgramPath $check
      if ($why) { $problems.Add("'$name': $why"); continue }
      if (-not $names.Add($check)) { $problems.Add("'$name' is in it twice"); continue }
      if ($isDir) { continue }
      if ($e.Length -gt 50MB) { $problems.Add("'$name' is too big ($($e.Length) bytes)"); continue }
      $total += $e.Length
      $fileEntries[$name] = $e
    }
    if ($total -gt 200MB) { $problems.Add("it unpacks to too much ($total bytes)") }
    if (-not $fileEntries.ContainsKey('tools/program-files.txt')) { $problems.Add('it has no tools/program-files.txt'); return $result }
    $listEntry = $fileEntries['tools/program-files.txt']
    if ($listEntry.Length -gt 256KB) { $problems.Add('its tools/program-files.txt is too big'); return $result }
    $sr = New-Object IO.StreamReader($listEntry.Open(), [Text.Encoding]::UTF8, $true)
    try { $listText = $sr.ReadToEnd() } finally { $sr.Dispose() }
    $list = Read-ProgramList $listText
    foreach ($p in $list.Problems) { $problems.Add("its tools/program-files.txt: $p") }
    $listed = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($f in $list.Files) { [void]$listed.Add($f) }
    foreach ($name in $fileEntries.Keys) { if (-not $listed.Contains($name)) { $problems.Add("'$name' is not listed in its tools/program-files.txt") } }
    foreach ($f in $list.Files) { if (-not $fileEntries.ContainsKey($f)) { $problems.Add("'$f' is listed but not in the zip") } }
    foreach ($req in $RequiredFiles) { if (-not $listed.Contains($req)) { $problems.Add("it has no $req") } }
    if ($fileEntries.ContainsKey('app/version.js')) {
      $sr = New-Object IO.StreamReader($fileEntries['app/version.js'].Open(), [Text.Encoding]::UTF8, $true)
      try { $result.Version = Get-VersionFromText $sr.ReadToEnd() } finally { $sr.Dispose() }
      if ($expectVersion -and (Get-ReleaseVersion $result.Version) -ne $expectVersion) {
        $problems.Add("its app/version.js says '$($result.Version)', not $expectVersion")
      }
    }
    $result.Files = $list.Files
    if ($problems.Count -eq 0 -and $extractTo) {
      $root = [IO.Path]::GetFullPath($extractTo).TrimEnd('\')
      foreach ($f in $list.Files) {
        $dest = [IO.Path]::GetFullPath((Join-Path $root ($f.Replace('/', '\'))))
        if (-not $dest.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) { throw "SAFETY STOP: '$f' would unpack outside $root" }
        $dest = Assert-Writable $dest
        Ensure-Dir ([IO.Path]::GetDirectoryName($dest))
        $in = $fileEntries[$f].Open()
        try {
          $out = New-Object IO.FileStream($dest, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
          try { $in.CopyTo($out) } finally { $out.Dispose() }
        } finally { $in.Dispose() }
      }
    }
  } finally { $zip.Dispose() }
  $result.Ok = ($problems.Count -eq 0)
  return $result
}

# ---------------------------------------------------------------- guarded writes inside the viewer folder
function Get-ViewerPath([string]$rel) {
  $full = [IO.Path]::GetFullPath((Join-Path $ViewerRoot ($rel.Replace('/', '\'))))
  if (-not $full.StartsWith($ViewerRoot + '\', [StringComparison]::OrdinalIgnoreCase)) { throw "SAFETY STOP: '$rel' is outside the viewer folder" }
  return $full
}
function Get-RelPath([string]$full) { return $full.Substring($ViewerRoot.Length + 1).Replace('\', '/') }
# no junction or symbolic link anywhere from the viewer folder down to $full
function Assert-NoLinks([string]$full) {
  $p = $full.TrimEnd('\')
  while ($p) {
    if ([IO.File]::Exists($p) -or [IO.Directory]::Exists($p)) {
      if (([IO.File]::GetAttributes($p) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "SAFETY STOP: $p is a link to somewhere else; nothing more was changed" }
    }
    if ($p.Length -le $ViewerRoot.Length) { break }
    $p = [IO.Path]::GetDirectoryName($p)
  }
}
# Every write and delete goes through this: it returns the full path, or stops everything.
function Assert-Writable([string]$path) {
  if (-not $script:MayWrite) { throw 'SAFETY STOP: this mode changes nothing' }
  $full = [IO.Path]::GetFullPath($path).TrimEnd('\')
  if (-not $full.StartsWith($ViewerRoot + '\', [StringComparison]::OrdinalIgnoreCase)) { throw "SAFETY STOP: refusing to change anything outside the viewer folder: $full" }
  $rel = Get-RelPath $full
  $first = $rel.Split('/')[0]
  $ok = $false
  if ($first -ieq 'updates' -or $first -ieq 'program-previous') { $ok = $true }
  elseif ($rel -ieq 'data/status.js') { $ok = $true }
  elseif ($rel -ieq 'family-settings.js') { $ok = $script:MayCreateSettings -and -not [IO.File]::Exists($full) }
  elseif ($script:AllowedTargets -and $script:AllowedTargets.Contains($rel)) { $ok = ((Test-ProgramPath $rel) -eq '') }
  if (-not $ok) { throw "SAFETY STOP: refusing to change '$rel' (not a program file)" }
  Assert-NoLinks $full
  return $full
}
function Ensure-Dir([string]$dir) {
  $d = [IO.Path]::GetFullPath($dir).TrimEnd('\')
  if ($d -ieq $ViewerRoot) { return }
  if (-not $d.StartsWith($ViewerRoot + '\', [StringComparison]::OrdinalIgnoreCase)) { throw "SAFETY STOP: refusing to make a folder outside the viewer folder: $d" }
  if ([IO.Directory]::Exists($d)) { Assert-NoLinks $d; return }
  Ensure-Dir ([IO.Path]::GetDirectoryName($d))
  if (-not $script:MayWrite) { throw 'SAFETY STOP: this mode changes nothing' }
  $rel = Get-RelPath $d
  $first = $rel.Split('/')[0]
  $ok = ($first -ieq 'updates' -or $first -ieq 'program-previous')
  if (-not $ok -and $script:AllowedTargets) { foreach ($t in $script:AllowedTargets) { if ($t.StartsWith($rel + '/', [StringComparison]::OrdinalIgnoreCase)) { $ok = $true; break } } }
  if (-not $ok) { throw "SAFETY STOP: refusing to make the folder '$rel'" }
  if ([IO.File]::Exists($d)) { throw "SAFETY STOP: '$rel' is a file, not a folder" }
  Assert-NoLinks $d
  [void][IO.Directory]::CreateDirectory($d)
}
function New-TempPath {
  $dir = Join-Path $ViewerRoot 'updates\tmp'
  Ensure-Dir $dir
  return Assert-Writable (Join-Path $dir ([Guid]::NewGuid().ToString('n') + '.tmp'))
}
# moves a finished temporary file into place (a fresh file: never written into an existing one)
function Move-Into([string]$tmp, [string]$dest) {
  $last = ''
  for ($try = 0; $try -lt 20; $try++) {
    try {
      if ([IO.File]::Exists($dest)) { [IO.File]::Replace($tmp, $dest, [NullString]::Value) } else { [IO.File]::Move($tmp, $dest) }
      return
    } catch {
      $last = $_.Exception.Message
      if ($try -ge 3) {
        try {
          if ([IO.File]::Exists($dest)) { [IO.File]::SetAttributes($dest, [IO.FileAttributes]::Normal); [IO.File]::Delete($dest) }
          [IO.File]::Move($tmp, $dest); return
        } catch { $last = $_.Exception.Message }
      }
      Start-Sleep -Milliseconds 200
    }
  }
  try { if ([IO.File]::Exists($tmp)) { [IO.File]::Delete($tmp) } } catch { }
  throw "could not write $dest ($last)"
}
# The temporary file is written through to the disk (Flush(true)) before it is moved into place, so a power
# cut can never leave a saved copy, a manifest or the install marker that looks complete but holds zeros.
function Open-TempForWrite([string]$tmp) {
  return New-Object IO.FileStream($tmp, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None, 65536, [IO.FileOptions]::WriteThrough)
}
function Write-OurFile([string]$path, $content) {
  $dest = Assert-Writable $path
  Ensure-Dir ([IO.Path]::GetDirectoryName($dest))
  $tmp = New-TempPath
  $bytes = $content
  if (-not ($content -is [byte[]])) { $bytes = $Utf8NoBom.GetBytes([string]$content) }
  $out = Open-TempForWrite $tmp
  try { $out.Write($bytes, 0, $bytes.Length); $out.Flush($true) } finally { $out.Dispose() }
  Move-Into $tmp $dest
}
function Copy-OurFile([string]$source, [string]$path) {
  $dest = Assert-Writable $path
  Ensure-Dir ([IO.Path]::GetDirectoryName($dest))
  $tmp = New-TempPath
  $in = New-Object IO.FileStream($source, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::Read -bor [IO.FileShare]::Delete))
  try {
    $out = Open-TempForWrite $tmp
    try { $in.CopyTo($out); $out.Flush($true) } finally { $out.Dispose() }
  } finally { $in.Dispose() }
  [IO.File]::SetLastWriteTimeUtc($tmp, [IO.File]::GetLastWriteTimeUtc($source))
  Move-Into $tmp $dest
}
function Remove-OurFile([string]$path) {
  $full = Assert-Writable $path
  if ([IO.Directory]::Exists($full)) { throw "SAFETY STOP: '$(Get-RelPath $full)' is a folder, not a file" }
  for ($try = 0; $try -lt 10; $try++) {
    try { if ([IO.File]::Exists($full)) { [IO.File]::SetAttributes($full, [IO.FileAttributes]::Normal); [IO.File]::Delete($full) }; return }
    catch { if ($try -eq 9) { throw }; Start-Sleep -Milliseconds 200 }
  }
}
# deletes one of the updater's own folders (updates\..., program-previous); refuses if anything inside is a link
function Remove-OurTree([string]$path) {
  $full = Assert-Writable $path
  $first = (Get-RelPath $full).Split('/')[0]
  if (-not ($first -ieq 'updates' -or $first -ieq 'program-previous')) { throw "SAFETY STOP: refusing to delete the folder $full" }
  if (-not [IO.Directory]::Exists($full)) { return }
  $dirs = New-Object System.Collections.Generic.List[string]
  $files = New-Object System.Collections.Generic.List[string]
  $stack = New-Object System.Collections.Generic.Stack[string]
  $stack.Push($full)
  while ($stack.Count) {
    $d = $stack.Pop()
    $dirs.Add($d)
    foreach ($e in (New-Object IO.DirectoryInfo('\\?\' + $d)).EnumerateFileSystemInfos()) {
      if ($e.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "SAFETY STOP: $($e.FullName) is a link to somewhere else; nothing was deleted" }
      $plain = $e.FullName.Substring(4)
      if ($e -is [IO.DirectoryInfo]) { $stack.Push($plain) } else { $files.Add($plain) }
    }
  }
  foreach ($f in $files) { [IO.File]::SetAttributes('\\?\' + $f, [IO.FileAttributes]::Normal); [IO.File]::Delete('\\?\' + $f) }
  for ($i = $dirs.Count - 1; $i -ge 0; $i--) { [IO.Directory]::Delete('\\?\' + $dirs[$i]) }
}

# ---------------------------------------------------------------- log, state, status line
$script:LogFile = ''
$script:StateFile = ''
function Save-Log {
  if (-not $script:MayWrite -or $script:LogLines.Count -eq 0) { return }
  try {
    $old = @()
    if ([IO.File]::Exists($script:LogFile)) { $old = @((Read-Shared $script:LogFile) -split "\r?\n" | Where-Object { $_ -ne '' }) }
    $all = @($old) + @($script:LogLines)
    if ($all.Count -gt 500) { $all = $all[($all.Count - 500)..($all.Count - 1)] }
    Write-OurFile $script:LogFile (($all -join "`r`n") + "`r`n")
    $script:LogLines.Clear()
  } catch { }
}
function Read-State {
  $h = @{}
  try {
    if ([IO.File]::Exists($script:StateFile)) {
      foreach ($line in ((Read-Shared $script:StateFile) -split "\r?\n")) {
        if ($line -match '^\s*([A-Za-z0-9._-]+)\s*=(.*)$') { $h[$Matches[1]] = $Matches[2].Trim() }
      }
    }
  } catch { }
  return $h
}
function Save-State {
  $lines = @('# Family Tree Viewer program updater: what it remembers between runs (safe to delete).')
  foreach ($k in ($script:State.Keys | Sort-Object)) { $lines += ($k + '=' + ([string]$script:State[$k]).Replace("`r", ' ').Replace("`n", ' ')) }
  Write-OurFile $script:StateFile (($lines -join "`r`n") + "`r`n")
}
function Get-BadVersions { return @(([string]$script:State['badVersions']).Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
function Add-BadVersion([string]$v) {
  if (-not $v) { return }
  $bad = Get-BadVersions
  if ($bad -notcontains $v) { $script:State['badVersions'] = (@($bad) + $v) -join ',' }
}
# A version that was taken back while the previous version had problems on this computer too: that may be the
# computer's fault, not the version's, so it is only remembered as bad after this happened on 3 different days.
# Returns the number of different days.
function Add-FailedDay([string]$v) {
  $k = "failedDays.$v"
  $days = @(([string]$script:State[$k]).Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
  $today = Get-Today
  if ($days -notcontains $today) { $days = @($days) + $today }
  $script:State[$k] = $days -join ','
  return $days.Count
}

# One line for the open page: data\status.js gets (or replaces) "programMessage", written atomically
# under the document-update lock. The next document update writes status.js anew without it.
function Set-ProgramMessage([string]$msg) {
  try {
    $file = Join-Path $ViewerRoot 'data\status.js'
    if (-not [IO.File]::Exists($file)) { return }
    $lock = New-Object System.Threading.Mutex($false, $DocMutexName)
    $have = $false
    try {
      try { $have = $lock.WaitOne([TimeSpan]::FromSeconds(120)) } catch [System.Threading.AbandonedMutexException] { $have = $true }
      if (-not $have) { Write-Log 'the message for the open page was not written (a document update was busy)'; return }
      $text = Read-Shared $file
      $m = [regex]::Match($text, '^\s*window\.FAMILY_STATUS\s*=\s*\{(.*)\}\s*;?\s*$', [Text.RegularExpressions.RegexOptions]::Singleline)
      if (-not $m.Success) { Write-Log 'data\status.js has an unexpected form; no message written'; return }
      $body = $m.Groups[1].Value
      $field = '"programMessage"\s*:\s*"(?:[^"\\]|\\.)*"'
      $body = [regex]::Replace($body, '\s*,\s*' + $field, '')
      $body = [regex]::Replace($body, $field + '\s*,?', '')
      $body = $body.Trim()
      $sep = ','
      if (-not $body) { $sep = '' }
      Write-OurFile $file ('window.FAMILY_STATUS = {' + $body + $sep + '"programMessage":' + (JStr $msg) + '};')
    } finally {
      if ($have) { $lock.ReleaseMutex() }
      $lock.Dispose()
    }
  } catch { Write-Log "the message for the open page could not be written: $($_.Exception.Message)" }
}

# ---------------------------------------------------------------- network (or local files in test mode)
function Get-WebProblem($err) {
  $ex = $err.Exception
  while ($ex -and -not ($ex -is [System.Net.WebException])) { $ex = $ex.InnerException }
  if ($ex) {
    if ($ex.Response) { try { return 'HTTP ' + [int]$ex.Response.StatusCode } catch { } }
    return [string]$ex.Status + ': ' + $ex.Message
  }
  $ex = $err.Exception
  while ($ex.InnerException) { $ex = $ex.InnerException }
  return $ex.Message
}
function Set-Tls12 {
  try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
}
# Returns the bytes at an address. In normal use only https addresses are allowed; with -ReleaseUrl
# (tests) also http, file:/// addresses and plain file paths.
function Get-Remote([string]$url, [int]$timeoutMs, [long]$maxBytes, [string]$accept) {
  if ($url -match '^(?i)https?://') {
    if (-not $script:TestMode -and $url -notmatch '^(?i)https://') { throw "refusing an address that is not https: $url" }
    Set-Tls12
    $req = [System.Net.HttpWebRequest][System.Net.WebRequest]::Create($url)
    $req.Method = 'GET'
    $req.Timeout = $timeoutMs
    $req.ReadWriteTimeout = $timeoutMs
    $req.UserAgent = 'family-tree-viewer-updater'
    $req.Accept = $accept
    $req.AllowAutoRedirect = $true
    $req.MaximumAutomaticRedirections = 5
    $resp = $req.GetResponse()
    try {
      if ($resp.ContentLength -gt $maxBytes) { throw "the download is too big ($($resp.ContentLength) bytes)" }
      $stream = $resp.GetResponseStream()
      $ms = New-Object IO.MemoryStream
      $buf = New-Object byte[] 65536
      while (($n = $stream.Read($buf, 0, $buf.Length)) -gt 0) {
        $ms.Write($buf, 0, $n)
        if ($ms.Length -gt $maxBytes) { throw 'the download is too big' }
      }
      return , $ms.ToArray()
    } finally { $resp.Close() }
  }
  if (-not $script:TestMode) { throw "refusing an address that is not https: $url" }
  $local = $url
  if ($url -match '^(?i)file:') { $local = ([Uri]$url).LocalPath }
  if (-not [IO.File]::Exists($local)) { throw "not found: $local" }
  if ((New-Object IO.FileInfo($local)).Length -gt $maxBytes) { throw 'the file is too big' }
  return , [IO.File]::ReadAllBytes($local)
}

# ---------------------------------------------------------------- automatic problem reports (Google Form)
# The settings are read from family-settings.js with a simple regular expression, one line at a time, after
# the "report:" line:   formUrl: '...',   and inside formFields:   version: 'entry.1',  when: ...  what: ...  details: ...
function Read-ReportSettings {
  $r = @{ formUrl = ''; version = ''; when = ''; what = ''; details = '' }
  try {
    $file = Join-Path $ViewerRoot 'family-settings.js'
    if (-not [IO.File]::Exists($file)) { return $r }
    $inReport = $false
    foreach ($line in ((Read-Shared $file) -split "\r?\n")) {
      if (-not $inReport) { if ($line -match '^\s*report\s*:') { $inReport = $true }; continue }
      foreach ($k in @('formUrl', 'version', 'when', 'what', 'details')) {
        if ($line -match ('^\s*' + $k + '\s*:\s*''([^'']*)''')) { $r[$k] = $Matches[1].Trim() }
      }
    }
  } catch { }
  return $r
}
# A report never names the family's folders or documents: a path inside the viewer folder becomes
# "<viewer folder>\...", any other path "<folder>", and a document's file name only its number ("document C4,1").
function Get-DocumentLabel([string]$name) {
  $m = [regex]::Match([string]$name, '([A-Za-z]{1,2})\s*(\d{1,3})\s*[,.]\s*(\d{1,6})')
  if ($m.Success) { return 'document ' + $m.Groups[1].Value.ToUpperInvariant() + $m.Groups[2].Value + ',' + $m.Groups[3].Value }
  return 'a document'
}
function Protect-ReportText([string]$s) {
  if (-not $s) { return '' }
  $s = [regex]::Replace($s, '(?i)(\\\\\?\\)?[a-z]:\\[^\r\n:*?"<>|'']*', [System.Text.RegularExpressions.MatchEvaluator] {
      param($m)
      $p = $m.Value.TrimEnd()
      $tail = $m.Value.Substring($p.Length)
      if ($p.StartsWith('\\?\')) { $p = $p.Substring(4) }
      if ($p -match '(?i)\.docx?$') { return (Get-DocumentLabel ([IO.Path]::GetFileName($p))) + $tail }
      if ($p.StartsWith($ViewerRoot, [StringComparison]::OrdinalIgnoreCase)) { return '<viewer folder>' + $p.Substring($ViewerRoot.Length) + $tail }
      return '<folder>' + $tail
    })
  $s = [regex]::Replace($s, '(?i)(could not read )(.+?)( : )', [System.Text.RegularExpressions.MatchEvaluator] {
      param($m) return $m.Groups[1].Value + (Get-DocumentLabel $m.Groups[2].Value) + $m.Groups[3].Value })
  $s = [regex]::Replace($s, '(?i)[^\r\n:*?"<>|''\\/]*[^\s:*?"<>|''\\/]\.docx?\b', [System.Text.RegularExpressions.MatchEvaluator] {
      param($m) return ' ' + (Get-DocumentLabel $m.Value) })
  return $s
}
# kind: a short word for the kind of problem; details: error lines only (never document text, file names or
# folders), max 1500 characters. At most one report per kind per day; a failure to send is only logged.
function Send-Report([string]$kind, [string]$details) {
  try {
    $cfg = Read-ReportSettings
    if (-not $cfg.formUrl) { Write-Log "no automatic report sent ($kind): no report formUrl in family-settings.js"; return }
    if ($cfg.formUrl -notmatch '^(?i)(https://|http://(127\.0\.0\.1|localhost)[:/])') { Write-Log "no automatic report sent ($kind): the formUrl in family-settings.js is not an https address"; return }
    foreach ($k in @('version', 'when', 'what', 'details')) { if (-not $cfg[$k]) { Write-Log "no automatic report sent ($kind): report.formFields.$k is empty in family-settings.js"; return } }
    $today = Get-Today
    if ($script:State["report.$kind"] -eq $today) { Write-Log "automatic report '$kind' was already sent today"; return }
    $script:State["report.$kind"] = $today
    try { Save-State } catch { }
    $details = Get-Short (Protect-ReportText $details) 1500
    $fields = [ordered]@{}
    $fields[$cfg.version] = (Show-Version (Get-InstalledVersion))
    $fields[$cfg.when] = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')
    $fields[$cfg.what] = $kind
    $fields[$cfg.details] = $details
    $body = (@($fields.Keys | ForEach-Object { [Uri]::EscapeDataString($_) + '=' + [Uri]::EscapeDataString([string]$fields[$_]) }) -join '&')
    Set-Tls12
    $req = [System.Net.HttpWebRequest][System.Net.WebRequest]::Create($cfg.formUrl)
    $req.Method = 'POST'
    $req.ContentType = 'application/x-www-form-urlencoded'
    $req.Timeout = 10000
    $req.ReadWriteTimeout = 10000
    $req.UserAgent = 'family-tree-viewer-updater'
    $req.ServicePoint.Expect100Continue = $false
    $bytes = [Text.Encoding]::UTF8.GetBytes($body)
    $req.ContentLength = $bytes.Length
    $rs = $req.GetRequestStream()
    try { $rs.Write($bytes, 0, $bytes.Length) } finally { $rs.Close() }
    $resp = $req.GetResponse()
    $code = [int]$resp.StatusCode
    $resp.Close()
    Write-Log "automatic report sent ($kind, answer $code)"
  } catch { Write-Log "the automatic report ($kind) could not be sent: $(Get-WebProblem $_)" }
}

# ---------------------------------------------------------------- running the other scripts
function Format-Arg([string]$a) {
  if ($a -ne '' -and $a -notmatch '[\s"]') { return $a }
  $a = [regex]::Replace($a, '(\\*)"', '$1$1\"')
  $a = [regex]::Replace($a, '(\\+)$', '$1$1')
  return '"' + $a + '"'
}
# Runs a PowerShell script in its own hidden process. Returns @{ ExitCode; TimedOut; Out; Err }.
function Invoke-Script([string]$file, [string[]]$scriptArgs, [int]$timeoutSec, [bool]$capture, [bool]$killOnTimeout) {
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = Join-Path $PSHOME 'powershell.exe'
  $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File ' + (Format-Arg $file) + ' ' + ((@($scriptArgs) | ForEach-Object { Format-Arg $_ }) -join ' ')
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  if ($capture) {
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8; $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
  }
  $p = [System.Diagnostics.Process]::Start($psi)
  $outTask = $null; $errTask = $null
  if ($capture) { $outTask = $p.StandardOutput.ReadToEndAsync(); $errTask = $p.StandardError.ReadToEndAsync() }
  $r = @{ ExitCode = -1; TimedOut = $false; Out = ''; Err = '' }
  if (-not $p.WaitForExit([Math]::Max(1, $timeoutSec) * 1000)) {
    $r.TimedOut = $true
    if ($killOnTimeout) { try { & taskkill.exe /T /F /PID $p.Id | Out-Null } catch { }; [void]$p.WaitForExit(10000) }
    return $r
  }
  $p.WaitForExit()
  $r.ExitCode = $p.ExitCode
  if ($capture) {
    if ($outTask.Wait(10000)) { $r.Out = $outTask.Result }
    if ($errTask.Wait(10000)) { $r.Err = $errTask.Result }
  }
  return $r
}
# What the last document update said (data\status.js "msg"), for reports and the log.
function Get-StatusMessage {
  try {
    $file = Join-Path $ViewerRoot 'data\status.js'
    if (-not [IO.File]::Exists($file)) { return '' }
    $m = [regex]::Match((Read-Shared $file), '"msg"\s*:\s*"((?:[^"\\]|\\.)*)"')
    if ($m.Success) { return [regex]::Unescape($m.Groups[1].Value) }
  } catch { }
  return ''
}
function Get-ErrorLines {
  # the last problem lines of the document update's own log (no document text is ever written there)
  try {
    $file = Join-Path $ViewerRoot 'data\update-log.txt'
    if (-not [IO.File]::Exists($file)) { return '' }
    $lines = @((Read-Shared $file) -split "\r?\n" | Where-Object { $_ -match 'FAILED|SAFETY|could not|cannot|Cannot' })
    if ($lines.Count -gt 6) { $lines = $lines[($lines.Count - 6)..($lines.Count - 1)] }
    return ($lines -join "`n")
  } catch { return '' }
}
# The document update. $inProcess: run it inside this PowerShell (step 1, as the icon did before 1.0: the
# same process opens the web browser, and no second PowerShell has to start); otherwise in its own process,
# with a time limit (used for the checks of a new version, whose code is not trusted yet).
function Invoke-DocumentUpdate([string]$toolsDir, [bool]$openPage, [int]$timeoutSec, [bool]$killOnTimeout, [bool]$inProcess) {
  $file = Join-Path $toolsDir 'Update-FamilyTree.ps1'
  if (-not [IO.File]::Exists($file)) { return @{ ExitCode = -2; TimedOut = $false; Why = 'tools\Update-FamilyTree.ps1 is missing' } }
  if ($inProcess) {
    $r = @{ ExitCode = 0; TimedOut = $false; Why = '' }
    $global:LASTEXITCODE = 0
    try {
      if ($openPage) { & $file -Open -Quiet | Out-Null } else { & $file -Quiet | Out-Null }
      $r.ExitCode = [int]$global:LASTEXITCODE
    } catch { $r.ExitCode = -3; $r.Why = "it could not be run: $($_.Exception.Message)"; return $r }
    if ($r.ExitCode -ne 0) { $r.Why = "exit code $($r.ExitCode)"; $sm = Get-StatusMessage; if ($sm) { $r.Why += ": $sm" } }
    return $r
  }
  $a = @('-Quiet')
  if ($openPage) { $a = @('-Open', '-Quiet') }
  $r = Invoke-Script $file $a $timeoutSec $false $killOnTimeout
  $r.Why = ''
  if ($r.TimedOut) { $r.Why = "it did not finish within $([int]($timeoutSec / 60)) minutes" }
  elseif ($r.ExitCode -ne 0) { $r.Why = "exit code $($r.ExitCode)"; $sm = Get-StatusMessage; if ($sm) { $r.Why += ": $sm" } }
  return $r
}

# ---------------------------------------------------------------- the installation
function Get-InstalledVersion {
  try {
    $file = Join-Path $ViewerRoot 'app\version.js'
    if ([IO.File]::Exists($file)) { return Get-VersionFromText (Read-Shared $file) }
  } catch { }
  return ''
}
function Get-InstalledList {
  $file = Join-Path $ViewerRoot 'tools\program-files.txt'
  if ([IO.File]::Exists($file)) {
    $l = Read-ProgramList (Read-Shared $file)
    if ($l.Problems.Count) { throw "the installed tools\program-files.txt has problems: $($l.Problems -join '; ')" }
    return @{ Files = $l.Files; Kind = 'tools\program-files.txt' }
  }
  $files = New-Object System.Collections.Generic.List[string]
  foreach ($f in $PreOneProgramFiles) { $files.Add($f) }
  return @{ Files = $files; Kind = 'the built-in list of the program files from before 1.0' }
}
function Test-DataJs {
  $file = Join-Path $ViewerRoot 'data\data.js'
  if (-not [IO.File]::Exists($file)) { return @{ Ok = $false; Why = 'data\data.js is missing' } }
  try {
    $t = Read-Shared $file
    $i = $t.IndexOf('window.FAMILY_DATA')
    if ($i -lt 0) { throw 'there is no window.FAMILY_DATA in it' }
    $a = $t.IndexOf('{', $i); $b = $t.LastIndexOf('}')
    if ($a -lt 0 -or $b -le $a) { throw 'it is cut short' }
    Add-Type -AssemblyName System.Web.Extensions
    $ser = New-Object System.Web.Script.Serialization.JavaScriptSerializer
    $ser.MaxJsonLength = [int]::MaxValue
    $ser.RecursionLimit = 10000
    $o = $ser.DeserializeObject($t.Substring($a, $b - $a + 1))
    if (-not ($o -is [System.Collections.Generic.IDictionary[string, object]]) -or -not $o.ContainsKey('docs')) { throw 'it has no list of documents' }
    return @{ Ok = $true; Docs = @($o['docs']).Count; Built = [string]$o['built'] }
  } catch { return @{ Ok = $false; Why = "data\data.js cannot be read ($($_.Exception.Message))" } }
}

# The health check: Check-Tree.ps1 from $checkerDir, run on this installation. Returns its JSON as an object.
function Invoke-Check([string]$checkerDir) {
  $file = Join-Path $checkerDir 'Check-Tree.ps1'
  if (-not [IO.File]::Exists($file)) { return [pscustomobject]@{ skipped = $true; reason = 'no Check-Tree.ps1' } }
  $a = @('-Viewer', $ViewerRoot)
  if ($Chrome) { $a += @('-Chrome', $Chrome) }
  $r = Invoke-Script $file $a 420 $true $true
  $line = @(([string]$r.Out) -split "\r?\n" | Where-Object { $_.Trim().StartsWith('{') }) | Select-Object -Last 1
  if (-not $line) { return [pscustomobject]@{ noAnswer = $true; reason = ("Check-Tree.ps1 printed no result (exit code $($r.ExitCode)) " + (Get-Short $r.Err 300)) } }
  try { return ($line | ConvertFrom-Json) } catch { return [pscustomobject]@{ noAnswer = $true; reason = "Check-Tree.ps1 printed something unreadable: $(Get-Short $line 200)" } }
}
function Format-Health($h) {
  if ($h.skipped) { return "not measured ($($h.reason))" }
  if ($h.noAnswer) { return "no answer ($($h.reason))" }
  $roots = @()
  if ($h.roots) { foreach ($p in $h.roots.PSObject.Properties) { $roots += ($p.Name + $(if ($p.Value) { '' } else { '(MISSING)' })) } }
  $s = "version $(Show-Version $h.version), $($h.docs) documents, $($h.personDocs) attached to people, $($h.peopleKnown) known people, roots: $($roots -join ' '), $($h.errors) unreadable"
  if ($h.buildError) { $s += ", BUILD ERROR: $($h.buildError)" }
  return $s
}
function Test-HealthAnswer($h) { return ($h -and -not $h.skipped -and -not $h.noAnswer) }
# Compares the health before and after; returns the reasons to go back (empty = fine).
function Compare-Health($before, $after, [string]$newVersion) {
  $reasons = New-Object System.Collections.Generic.List[string]
  if ($after.skipped) { return , $reasons }
  if ($after.noAnswer) {
    if (Test-HealthAnswer $before) { $reasons.Add("the health check gave no answer with the new version ($($after.reason))") }
    return , $reasons
  }
  if ($after.buildError) { $reasons.Add("the family tree cannot be built with the new version: $($after.buildError)"); return , $reasons }
  if ($after.version -and $newVersion -and (Get-ReleaseVersion $after.version) -ne $newVersion) { $reasons.Add("the installed app\version.js says $($after.version), not $newVersion") }
  if ((Test-HealthAnswer $before) -and -not $before.buildError) {
    $pd0 = [double]$before.personDocs; $pd1 = [double]$after.personDocs
    if (($pd0 - $pd1) -gt [Math]::Max(3.0, 0.02 * $pd0)) { $reasons.Add("documents attached to people dropped from $pd0 to $pd1") }
    $pk0 = [double]$before.peopleKnown; $pk1 = [double]$after.peopleKnown
    if (($pk0 - $pk1) -gt (0.02 * $pk0)) { $reasons.Add("known people dropped from $pk0 to $pk1") }
    if ($before.roots) {
      foreach ($p in $before.roots.PSObject.Properties) {
        if ($p.Value -and -not ($after.roots -and $after.roots.($p.Name))) { $reasons.Add("the root person '$($p.Name)' is missing") }
      }
    }
  }
  return , $reasons
}

# The saved program files ("program-previous\", and while an install is being checked "updates\<version>\previous\")
# have a manifest.txt in a stable format, read by later versions too:
#   key=value lines (version, installing, date, list), then one line per program file:
#   F <tab> sha256 <tab> path   the file was saved here and is put back when going back
#   N <tab> <tab> path          the file did not exist before; it is removed when going back
#   end=<number of F and N lines>   (written last: a manifest without it is incomplete)
function Read-Manifest([string]$dir) {
  $file = Join-Path $dir 'manifest.txt'
  $man = @{ Exists = $false; Complete = $false; Version = ''; Installing = ''; Saved = (New-Object System.Collections.Generic.List[object]); New = (New-Object System.Collections.Generic.List[string]); Problems = (New-Object System.Collections.Generic.List[string]) }
  if (-not [IO.File]::Exists($file)) { return $man }
  $man.Exists = $true
  $count = 0; $end = -1
  foreach ($line in ((Read-Shared $file) -split "\r?\n")) {
    if (-not $line -or $line.StartsWith('#')) { continue }
    $parts = $line.Split("`t")
    if ($parts.Length -eq 3 -and ($parts[0] -eq 'F' -or $parts[0] -eq 'N')) {
      $why = Test-ProgramPath $parts[2]
      if ($why) { $man.Problems.Add("'$($parts[2])': $why"); continue }
      if ($parts[0] -eq 'F') { $man.Saved.Add(@{ Path = $parts[2]; Sha = $parts[1] }) } else { $man.New.Add($parts[2]) }
      $count++
    } elseif ($line -match '^version=(.*)$') { $man.Version = $Matches[1].Trim() }
    elseif ($line -match '^installing=(.*)$') { $man.Installing = $Matches[1].Trim() }
    elseif ($line -match '^end=(\d+)$') { $end = [int]$Matches[1] }
  }
  $man.Complete = ($end -eq $count -and $man.Problems.Count -eq 0)
  return $man
}
function Test-SameSha([string]$file, [string]$sha) {
  try { return ([IO.File]::Exists($file) -and (Get-FileSha256 $file) -eq $sha) } catch { return $false }
}
# Puts the program saved in $dir back (call with the document-update lock held).
# Every saved copy is checked first. A program file that already holds the saved content is left as it is; a
# saved copy that is missing or damaged may be replaced by an identical copy in program-previous\.
# Without $bestEffort nothing is changed unless every file can be put back. With $bestEffort (repairing an
# interrupted install) everything that can be put back is put back, and $script:NotRestored lists the rest.
# A manifest line whose path is another name of a different file (e.g. an 8.3 short name) is left alone.
function Restore-Previous([string]$dir, [bool]$bestEffort) {
  $script:NotRestored = New-Object System.Collections.Generic.List[string]
  $man = Read-Manifest $dir
  if (-not $man.Exists) { throw "there is no saved previous version ($dir\manifest.txt)" }
  if (-not $man.Complete) { throw "the saved previous version is incomplete; nothing was changed $($man.Problems -join '; ')" }
  $other = Join-Path $ViewerRoot 'program-previous'
  $targets = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
  $copies = New-Object System.Collections.Generic.List[object]
  $removes = New-Object System.Collections.Generic.List[string]
  foreach ($s in $man.Saved) {
    $full = Get-ViewerPath $s.Path
    if ((Get-RelPath $full) -ine $s.Path) { Write-Log "'$($s.Path)' is another name for '$(Get-RelPath $full)'; it is left alone"; continue }
    [void]$targets.Add($s.Path)
    if (Test-SameSha $full $s.Sha) { continue }
    $src = ''
    foreach ($cand in @((Join-Path $dir ($s.Path.Replace('/', '\'))), (Join-Path $other ($s.Path.Replace('/', '\'))))) {
      if (Test-SameSha $cand $s.Sha) { $src = $cand; break }
    }
    if ($src) { $copies.Add(@{ From = $src; To = $full }) } else { $script:NotRestored.Add($s.Path) }
  }
  if ($script:NotRestored.Count -and -not $bestEffort) { throw "the saved copy of $($script:NotRestored -join ', ') is missing or damaged; nothing was changed" }
  foreach ($n in $man.New) {
    $full = Get-ViewerPath $n
    if ((Get-RelPath $full) -ine $n) { Write-Log "'$n' is another name for '$(Get-RelPath $full)'; it is left alone"; continue }
    [void]$targets.Add($n)
    $removes.Add($full)
  }
  $script:AllowedTargets = $targets
  try {
    foreach ($c in $copies) { Copy-OurFile $c.From $c.To }
    foreach ($r in $removes) { Remove-OurFile $r }
  } finally { $script:AllowedTargets = $null }
  return $man
}
function Enter-Lock([System.Threading.Mutex]$m, [int]$seconds) {
  try { return $m.WaitOne([TimeSpan]::FromSeconds([Math]::Max(0, $seconds))) } catch [System.Threading.AbandonedMutexException] { return $true }
}

# Saves the current program into $backupDir (with its manifest) and copies the new one in. Call with the
# document-update lock held. $script:SwapStarted tells the caller whether anything in the program changed.
function Install-Files([string]$oldVersion, [string]$newVersion, [string]$filesDir, $newList, $oldList, [string]$backupDir) {
  $script:SwapStarted = $false
  Remove-OurTree $backupDir
  Ensure-Dir $backupDir
  $all = New-Object System.Collections.Generic.List[string]
  $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
  foreach ($f in @($oldList.Files) + @($newList)) { if ($seen.Add($f)) { $all.Add($f) } }
  $lines = New-Object System.Collections.Generic.List[string]
  $lines.Add("# Family Tree Viewer: the program files as they were before version $newVersion was installed.")
  $lines.Add('# "Go back to the previous version.cmd" (tools\Update-Program.ps1 -Rollback) puts them back.')
  $lines.Add('# F <tab> sha256 <tab> path = saved here;  N <tab> <tab> path = did not exist before (removed when going back)')
  $lines.Add("version=$oldVersion")
  $lines.Add("installing=$newVersion")
  $lines.Add('date=' + (Get-UtcNow))
  $lines.Add("list=$($oldList.Kind)")
  $oldSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
  foreach ($f in $oldList.Files) { [void]$oldSet.Add($f) }
  foreach ($rel in $all) {
    $cur = Get-ViewerPath $rel
    # a listed name must be the file's own name, never another name of a different file (an 8.3 short name)
    if ((Get-RelPath $cur) -ine $rel) { throw "SAFETY STOP: '$rel' is another name for '$(Get-RelPath $cur)'; nothing was changed" }
    Assert-NoLinks $cur
    if ([IO.Directory]::Exists($cur)) { throw "SAFETY STOP: '$rel' is a folder in the installation, not a file; nothing was changed" }
  }
  $n = 0
  $keptDir = ''
  foreach ($rel in $all) {
    $cur = Get-ViewerPath $rel
    if ([IO.File]::Exists($cur)) {
      if (-not $oldSet.Contains($rel)) {
        # this computer has a file of that name that was never part of the program (e.g. private notes);
        # the new version brings its own, so a copy is kept for good in updates\kept\<date>\ first
        if (-not $keptDir) { $keptDir = Join-Path $ViewerRoot ('updates\kept\' + (Get-Date).ToString('yyyy-MM-dd_HHmmss')) }
        Copy-OurFile $cur (Join-Path $keptDir ($rel.Replace('/', '\')))
        Write-Log "'$rel' was not part of the program here, but version $newVersion brings its own: a copy of the old one is kept in $(Get-RelPath $keptDir)"
      }
      $saved = Join-Path $backupDir ($rel.Replace('/', '\'))
      Copy-OurFile $cur $saved
      $lines.Add("F`t" + (Get-FileSha256 $saved) + "`t" + $rel)
    } else { $lines.Add("N`t`t" + $rel) }
    $n++
  }
  $lines.Add("end=$n")
  Write-OurFile (Join-Path $backupDir 'manifest.txt') (($lines -join "`r`n") + "`r`n")
  Write-OurFile (Join-Path $ViewerRoot 'updates\install-in-progress.txt') ("installing=$newVersion`r`nprevious=$oldVersion`r`nbackup=" + (Get-RelPath ([IO.Path]::GetFullPath($backupDir))) + "`r`ndate=$(Get-UtcNow)`r`n")
  $newSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
  foreach ($f in $newList) { [void]$newSet.Add($f) }
  $targets = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
  foreach ($f in $all) { [void]$targets.Add($f) }
  $script:AllowedTargets = $targets
  try {
    $script:SwapStarted = $true
    if ($PauseInSwapSec -gt 0) { Write-Log "pausing $PauseInSwapSec s inside the swap (-PauseInSwapSec, for tests)"; Start-Sleep -Seconds $PauseInSwapSec }
    foreach ($rel in $newList) { Copy-OurFile (Join-Path $filesDir ($rel.Replace('/', '\'))) (Get-ViewerPath $rel) }
    foreach ($rel in $oldList.Files) { if (-not $newSet.Contains($rel)) { Remove-OurFile (Get-ViewerPath $rel) } }
  } finally { $script:AllowedTargets = $null }
}

# Puts back the program saved in $dir; returns '' or what went wrong. With $bestEffort (see Restore-Previous)
# the files that could not be put back are in $script:NotRestored.
function Undo-Install([string]$why, [string]$dir, [bool]$bestEffort) {
  $script:NotRestored = New-Object System.Collections.Generic.List[string]
  $lock = New-Object System.Threading.Mutex($false, $DocMutexName)
  $have = $false
  try {
    $have = Enter-Lock $lock ([Math]::Max($MutexWaitSec, 600))
    if (-not $have) { return 'the document update lock could not be taken' }
    $man = Restore-Previous $dir $bestEffort
    Remove-OurFile (Join-Path $ViewerRoot 'updates\install-in-progress.txt')
    if ($script:NotRestored.Count) { Write-Log "the previous version ($(Show-Version $man.Version)) was put back as far as possible ($why); no good saved copy of: $($script:NotRestored -join ', ')" }
    else { Write-Log "the previous version ($(Show-Version $man.Version)) was put back ($why)" }
    return ''
  } catch { return $_.Exception.Message }
  finally { if ($have) { $lock.ReleaseMutex() }; $lock.Dispose() }
}
# Notes in the install marker that the install did not just stop (power cut) but failed and could not be
# taken back; the next start puts the previous version back without counting it as an interruption.
function Set-MarkerFailed([string]$what) {
  try {
    $marker = Join-Path $ViewerRoot 'updates\install-in-progress.txt'
    if ([IO.File]::Exists($marker)) { Write-OurFile $marker ((Read-Shared $marker).TrimEnd() + "`r`nfailed=$what`r`n") }
  } catch { }
}
function Copy-OurTree([string]$from, [string]$to) {
  $src = [IO.Path]::GetFullPath($from).TrimEnd('\')
  foreach ($f in [IO.Directory]::GetFiles($src, '*', [IO.SearchOption]::AllDirectories)) { Assert-NoLinks $f; Copy-OurFile $f (Join-Path $to $f.Substring($src.Length + 1)) }
}
# Makes the saved program ($backupDir) the new program-previous\. The old program-previous\ is only moved
# aside (into updates\) until the new one is in place, and put back if that fails, so program-previous\ is
# never lost. Returns '' when done, otherwise what went wrong.
function Set-ProgramPrevious([string]$backupDir) {
  $prev = Join-Path $ViewerRoot 'program-previous'
  $aside = ''
  try {
    if ([IO.Directory]::Exists($prev)) {
      $aside = Join-Path $ViewerRoot ('updates\previous-old-' + [Guid]::NewGuid().ToString('n').Substring(0, 8))
      [IO.Directory]::Move((Assert-Writable $prev), (Assert-Writable $aside))
    }
  } catch { return "program-previous could not be replaced ($($_.Exception.Message)); it still holds the version before" }
  $err = ''
  try { [IO.Directory]::Move((Assert-Writable $backupDir), (Assert-Writable $prev)) }
  catch {
    $err = $_.Exception.Message
    try { Copy-OurTree $backupDir $prev; $err = '' }
    catch {
      $err += " / copying it: $($_.Exception.Message)"
      try { Remove-OurTree $prev } catch { }
    }
  }
  if ($err) {
    if (-not $aside) { return "the previous version could not be saved in program-previous ($err)" }
    try { [IO.Directory]::Move((Assert-Writable $aside), (Assert-Writable $prev)) }
    catch { return "the previous version could not be saved in program-previous ($err), and the older copy could not be put back there either (it is in $(Get-RelPath $aside))" }
    return "the previous version could not be saved in program-previous ($err); program-previous still holds the version before"
  }
  if ($aside) { try { Remove-OurTree $aside } catch { Write-Log "could not remove $(Get-RelPath $aside) ($($_.Exception.Message))" } }
  return ''
}
# leftovers of downloads that were interrupted (updates\<x.y.z>\), except $keep
function Remove-OldDownloads([string]$keep) {
  $up = Join-Path $ViewerRoot 'updates'
  if (-not [IO.Directory]::Exists($up)) { return }
  foreach ($d in [IO.Directory]::GetDirectories($up)) {
    $name = [IO.Path]::GetFileName($d)
    if ($name -match '^\d+\.\d+\.\d+$' -and $name -ne $keep) { try { Remove-OurTree $d } catch { Write-Log "could not remove $d ($($_.Exception.Message))" } }
  }
}

# The whole install of one release (zip already downloaded or given). Returns a result word.
# The current program is saved in updates\<version>\previous\ while the new one is checked; only when the new
# version is accepted does that become program-previous\ (so after a version was taken back, program-previous\
# still holds the version before the current one, for "Go back to the previous version.cmd").
function Install-Release([string]$newVersion, [string]$zipPath) {
  $oldVersion = Get-InstalledVersion
  $verDir = Join-Path $ViewerRoot "updates\$newVersion"
  $filesDir = Join-Path $verDir 'files'
  $backupDir = Join-Path $verDir 'previous'
  Remove-OldDownloads $newVersion
  Remove-OurTree $filesDir
  Remove-OurTree $backupDir
  Ensure-Dir $filesDir
  $check = Test-ReleaseZip $zipPath $newVersion $filesDir
  if (-not $check.Ok) {
    $what = "version $newVersion was refused: " + ($check.Problems -join '; ')
    Write-Log $what
    try { Remove-OurTree $verDir } catch { }
    Send-Report 'program-update-refused' $what
    return 'refused'
  }
  $oldList = Get-InstalledList
  Write-Log "release $newVersion checked: $($check.Files.Count) program files (installed: $(Show-Version $oldVersion), $($oldList.Files.Count) files from $($oldList.Kind))"

  # the health check of the installed program is used before AND after (so both are measured the same way);
  # a program from before 1.0 has none, so the new version's is used
  $checker = Join-Path $ViewerRoot 'updates\checker'
  Remove-OurTree $checker
  $from = Join-Path $ViewerRoot 'tools'
  if (-not ([IO.File]::Exists((Join-Path $from 'Check-Tree.ps1')) -and [IO.File]::Exists((Join-Path $from 'check-tree.html')))) { $from = Join-Path $filesDir 'tools' }
  foreach ($f in @('Check-Tree.ps1', 'check-tree.html')) { if ([IO.File]::Exists((Join-Path $from $f))) { Copy-OurFile (Join-Path $from $f) (Join-Path $checker $f) } }
  $before = Invoke-Check $checker
  Write-Log ('health before: ' + (Format-Health $before))
  Save-Log

  # ---- install, under the document-update lock (no document update can run in the middle of the swap)
  $lock = New-Object System.Threading.Mutex($false, $DocMutexName)
  $have = $false
  $failed = ''
  try {
    $have = Enter-Lock $lock $MutexWaitSec
    if (-not $have) {
      Write-Log "a document update was still running after $MutexWaitSec s; version $newVersion will be installed another time"
      try { Remove-OurTree $verDir; Remove-OurTree $checker } catch { }
      $script:State.Remove('lastCheckDay')
      return 'busy'
    }
    if (-not [IO.File]::Exists((Join-Path $ViewerRoot 'family-settings.js')) -and $SettingsFrom) {
      $script:MayCreateSettings = $true
      try {
        $dest = Assert-Writable (Join-Path $ViewerRoot 'family-settings.js')
        $bytes = [IO.File]::ReadAllBytes($script:SettingsSource)
        $out = New-Object IO.FileStream($dest, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $out.Write($bytes, 0, $bytes.Length) } finally { $out.Dispose() }
        Write-Log "family-settings.js was created from $($script:SettingsSource)"
      } finally { $script:MayCreateSettings = $false }
    }
    try { Install-Files $oldVersion $newVersion $filesDir $check.Files $oldList $backupDir }
    catch {
      $failed = $_.Exception.Message
      if ($script:SwapStarted) {
        try { [void](Restore-Previous $backupDir $false); Remove-OurFile (Join-Path $ViewerRoot 'updates\install-in-progress.txt') } catch { $failed += " / AND PUTTING BACK THE PREVIOUS VERSION FAILED: $($_.Exception.Message)" }
      }
    }
  } finally {
    if ($have) { $lock.ReleaseMutex() }
    $lock.Dispose()
  }
  if ($failed) {
    Write-Log "version $newVersion could not be installed: $failed"
    if ($failed -notmatch 'PUTTING BACK') { try { Remove-OurTree $verDir; Remove-OurTree $checker } catch { } }
    else { Set-MarkerFailed 'the swap' }    # (e.g. a file held open by a virus scanner: not an interruption)
    Send-Report 'program-update-failed' "installing $newVersion failed: $failed"
    return 'failed'
  }
  Write-Log "version $newVersion was copied in; checking it"
  Save-Log

  # ---- verify
  $reasons = New-Object System.Collections.Generic.List[string]
  $du = Invoke-DocumentUpdate (Join-Path $ViewerRoot 'tools') $false 2700 $true $false
  if ($du.ExitCode -ne 0) { $reasons.Add("the document update with the new version failed ($($du.Why))") }
  $data = Test-DataJs
  if (-not $data.Ok) { $reasons.Add($data.Why) }
  $selfTest = Invoke-Script (Join-Path $ViewerRoot 'tools\Update-Program.ps1') @('-SelfTest', '-Quiet', '-Viewer', $ViewerRoot) 120 $true $true
  if ($selfTest.ExitCode -ne 0 -or $selfTest.Out -notmatch 'SELFTEST OK') { $reasons.Add("the new tools\Update-Program.ps1 does not work (exit code $($selfTest.ExitCode)) $(Get-Short ($selfTest.Out + ' ' + $selfTest.Err) 300)") }
  if ($reasons.Count -eq 0) {
    $after = Invoke-Check $checker
    if ($after.noAnswer -and (Test-HealthAnswer $before)) {
      Write-Log "the health check gave no answer; trying once more in 10 s ($($after.reason))"
      Start-Sleep -Seconds 10
      $after = Invoke-Check $checker
    }
    Write-Log ('health after:  ' + (Format-Health $after))
    $healthReasons = Compare-Health $before $after $newVersion
    if ($healthReasons.Count -and ($after.buildError -or $after.noAnswer)) {
      # The check page of the installed (older) version may not know how to load the new version. A second
      # opinion from the new version's own check page (when it is a different one) can clear the doubt.
      $own = Join-Path $ViewerRoot 'tools'
      $differs = $false
      foreach ($f in @('Check-Tree.ps1', 'check-tree.html')) {
        $a = Join-Path $checker $f; $b = Join-Path $own $f
        if ([IO.File]::Exists($a) -and [IO.File]::Exists($b) -and (Get-FileSha256 $a) -ne (Get-FileSha256 $b)) { $differs = $true }
      }
      if ($differs) {
        $after2 = Invoke-Check $own
        Write-Log ('health after, measured by the new version''s own check page: ' + (Format-Health $after2))
        if ((Test-HealthAnswer $after2) -and -not $after2.buildError) {
          $second = Compare-Health $before $after2 $newVersion
          if ($second.Count -eq 0) { Write-Log 'the new version''s own check page finds the tree healthy, so the first answer is not held against it'; $healthReasons = $second }
        }
      }
    }
    foreach ($x in $healthReasons) { $reasons.Add($x) }
  }

  if ($reasons.Count -eq 0) {
    # accepted: the saved program becomes program-previous\
    try { Remove-OurTree $checker } catch { }
    Remove-OurFile (Join-Path $ViewerRoot 'updates\install-in-progress.txt')
    $script:State['installed'] = "$newVersion " + (Get-UtcNow)
    [void]$script:State.Remove("failedDays.$newVersion")
    [void]$script:State.Remove('reinstall')
    $kept = Set-ProgramPrevious $backupDir
    if ($kept) {
      # the saved copy stays in updates\<version>\previous\ (removed at the next install)
      Write-Log $kept
      Write-Log "INSTALLED version $newVersion (previous: $(Show-Version $oldVersion), NOT saved in program-previous)"
    } else {
      try { Remove-OurTree $verDir } catch { }
      Write-Log "INSTALLED version $newVersion (previous: $(Show-Version $oldVersion), saved in program-previous)"
    }
    Set-ProgramMessage "The family tree program was updated to version $newVersion."
    return 'installed'
  }

  # ---- go back
  $why = $reasons -join '; '
  Write-Log "version $newVersion does not work properly: $why"
  Save-Log
  $undo = Undo-Install "version $newVersion did not work" $backupDir $false
  if ($undo) {
    Write-Log "PUTTING BACK THE PREVIOUS VERSION FAILED: $undo"
    Set-MarkerFailed 'taking it back'
    # whether the new version or this computer is at fault is not known
    if (-not $script:DocumentsFailed -and (Add-FailedDay $newVersion) -ge 3) { Add-BadVersion $newVersion }
    try { Remove-OurTree $checker } catch { }
    Send-Report 'rollback-failed' "version $newVersion did not work ($why) and putting back $(Show-Version $oldVersion) failed: $undo"
    return 'failed'
  }
  # Is it the new version, or this computer? The previous version is checked again the same way: only when it
  # works is the new version remembered as bad at once (a short-lived problem on the computer, e.g. the
  # documents folder not being there or a hiccup of the health check, must not block a good version for good).
  $oldProblems = New-Object System.Collections.Generic.List[string]
  $du2 = Invoke-DocumentUpdate (Join-Path $ViewerRoot 'tools') $false 2700 $true $false
  if ($du2.ExitCode -ne 0) { $oldProblems.Add("the document update with the previous version failed too ($($du2.Why))") }
  else {
    $data2 = Test-DataJs
    if (-not $data2.Ok) { $oldProblems.Add("with the previous version: $($data2.Why)") }
    else {
      $back = Invoke-Check $checker
      Write-Log ('health with the previous version again: ' + (Format-Health $back))
      if ($back.noAnswer -and (Test-HealthAnswer $before)) { $oldProblems.Add('the health check gives no answer with the previous version either') }
      elseif (-not $back.skipped -and -not $back.noAnswer -and $back.buildError) { $oldProblems.Add('the tree cannot be built with the previous version either') }
    }
  }
  try { Remove-OurTree $checker } catch { }
  try { Remove-OurTree $verDir } catch { }
  if ($oldProblems.Count -eq 0) {
    Add-BadVersion $newVersion
    Write-Log "ROLLED BACK: version $newVersion was taken back and will not be tried again; $(Show-Version $oldVersion) is in use"
  } else {
    $days = 0
    if (-not $script:DocumentsFailed) { $days = Add-FailedDay $newVersion }
    if ($days -ge 3) {
      Add-BadVersion $newVersion
      Write-Log "ROLLED BACK: version $newVersion was taken back ($($oldProblems -join '; ')); it failed on $days different days and will not be tried again; $(Show-Version $oldVersion) is in use"
    } else {
      Write-Log "ROLLED BACK: version $newVersion was taken back, but the previous version has problems on this computer too ($($oldProblems -join '; ')), so it is tried again on another day; $(Show-Version $oldVersion) is in use"
    }
  }
  Set-ProgramMessage "A new version of the family tree program ($newVersion) did not work properly, so the previous version is still in use. Nothing was lost."
  Send-Report 'program-update-rolled-back' "version $newVersion was taken back: $why"
  return 'rolled-back'
}

# Asks GitHub (or -ReleaseUrl) for the latest release and installs it when it is newer. Returns a result word.
function Update-FromRelease {
  $today = Get-Today
  if (-not $script:DocumentsFailed) { [void]$script:State.Remove('documentsFailedDays') }
  if (-not $CheckNow -and $script:State['lastCheckDay'] -eq $today) { return 'checked-today' }
  if ($script:DocumentsFailed) {
    # The documents could not be read just now (e.g. their folder is not there): a new version could not be
    # checked properly, so the check waits for a start where they can be read. After 3 such days it goes ahead
    # anyway, because a new version may be what fixes the document update.
    $days = @(([string]$script:State['documentsFailedDays']).Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($days -notcontains $today) { $days = @($days) + $today }
    if ($days.Count -gt 5) { $days = $days[($days.Count - 5)..($days.Count - 1)] }
    $script:State['documentsFailedDays'] = $days -join ','
    if ($days.Count -lt 3) { Write-Log 'the documents could not be read, so the check for a new program version waits for a start where they can'; return 'documents-failed' }
    Write-Log "the documents could not be read on $($days.Count) different days; checking for a new program version anyway"
  }
  $script:State['lastCheckDay'] = $today
  $script:State['lastCheck'] = Get-UtcNow
  Save-State
  $url = $LatestReleaseUrl
  if ($ReleaseUrl) { $url = $ReleaseUrl }
  try {
    $bytes = Get-Remote $url 5000 2MB 'application/vnd.github+json'
    $rel = ($Utf8NoBom.GetString($bytes).TrimStart([char]0xFEFF)) | ConvertFrom-Json
  } catch {
    Write-Log "could not check for a new program version ($(Get-WebProblem $_)); will try again tomorrow"
    return 'offline'
  }
  $newVersion = Get-ReleaseVersion ([string]$rel.tag_name)
  if (-not $newVersion) { Write-Log "the latest release has no usable version tag ('$([string]$rel.tag_name)')"; return 'no-release' }
  $installed = Get-InstalledVersion
  $script:State['latestSeen'] = $newVersion
  # "reinstall": an interrupted install could not be undone completely, so the program is a mix of two versions
  # and the latest release is installed completely, even when its version number is the installed one
  $reinstall = [string]$script:State['reinstall']
  if ((Compare-Versions $newVersion $installed) -le 0 -and -not $reinstall) { Write-Log "the program is up to date (installed $(Show-Version $installed), latest release $newVersion)"; return 'up-to-date' }
  if ((Get-BadVersions) -contains $newVersion) { Write-Log "version $newVersion was taken back before and is not tried again"; return 'bad-version' }
  if ($reinstall) { Write-Log "the program files are a mix of two versions (since $reinstall); installing release $newVersion completely" }
  if (-not (Test-SettingsReady)) { return 'settings-missing' }

  $zipName = "family-tree-viewer-$newVersion.zip"
  $zipUrl = ''; $shaUrl = ''
  foreach ($as in @($rel.assets)) {
    if (-not $as) { continue }
    if ([string]$as.name -eq $zipName) { $zipUrl = [string]$as.browser_download_url }
    elseif ([string]$as.name -eq "$zipName.sha256") { $shaUrl = [string]$as.browser_download_url }
  }
  if (-not $zipUrl -or -not $shaUrl) {
    $what = "release $newVersion has no $zipName and $zipName.sha256"
    Write-Log $what
    Send-Report 'program-update-refused' $what
    return 'refused'
  }
  Write-Log "a new program version is available: $newVersion (installed: $(Show-Version $installed)); downloading"
  Save-Log
  $verDir = Join-Path $ViewerRoot "updates\$newVersion"
  Remove-OurTree $verDir
  Ensure-Dir $verDir
  $zipFile = Join-Path $verDir $zipName
  try {
    $shaBytes = Get-Remote $shaUrl 30000 64KB 'application/octet-stream'
    $zipBytes = Get-Remote $zipUrl 120000 50MB 'application/octet-stream'
  } catch {
    Write-Log "the download of $newVersion failed ($(Get-WebProblem $_)); will try again tomorrow"
    try { Remove-OurTree $verDir } catch { }
    return 'offline'
  }
  Write-OurFile "$zipFile.sha256" $shaBytes
  Write-OurFile $zipFile $zipBytes
  Write-Log "downloaded $zipName ($($zipBytes.Length) bytes)"
  Save-Log
  $want =[regex]::Match([Text.Encoding]::ASCII.GetString($shaBytes), '^\s*([0-9a-fA-F]{64})(\s|$)')
  $got = Get-FileSha256 $zipFile
  if (-not $want.Success -or $want.Groups[1].Value.ToLowerInvariant() -ne $got) {
    $what = "version $newVersion was refused: the zip's SHA-256 ($got) does not match its .sha256 file"
    Write-Log $what
    try { Remove-OurTree $verDir } catch { }
    Send-Report 'program-update-refused' $what
    return 'refused'
  }
  return Install-Release $newVersion $zipFile
}

# family-settings.js must exist (or be given with -SettingsFrom) before any program of 1.0 or later is installed:
# the program cannot invent the family's settings.
function Test-SettingsReady {
  if ([IO.File]::Exists((Join-Path $ViewerRoot 'family-settings.js'))) {
    if ($SettingsFrom) { Write-Log 'family-settings.js already exists; it is kept as it is (-SettingsFrom is not used)' }
    return $true
  }
  if (-not $SettingsFrom) {
    Write-Log 'family-settings.js is missing next to index.html, so no new program version is installed (the first install over a program from before 1.0 needs -SettingsFrom <family-settings.js>)'
    return $false
  }
  $f = [IO.Path]::GetFullPath($SettingsFrom)
  $why = ''
  if (-not [IO.File]::Exists($f)) { $why = 'it does not exist' }
  elseif ((New-Object IO.FileInfo($f)).Length -gt 1MB) { $why = 'it is too big' }
  elseif ((Read-Shared $f) -notmatch 'window\.FAMILY_SETTINGS\s*=') { $why = 'it does not define window.FAMILY_SETTINGS' }
  if ($why) { Write-Log "the settings file given with -SettingsFrom ($f) cannot be used: $why"; return $false }
  $script:SettingsSource = $f
  return $true
}

# An install that was interrupted (computer switched off in the middle): put the previous version back.
function Repair-InterruptedInstall {
  $marker = Join-Path $ViewerRoot 'updates\install-in-progress.txt'
  if (-not [IO.File]::Exists($marker)) { return }
  $ver = ''; $backup = ''; $failedBefore = $false
  try {
    $text = Read-Shared $marker
    $m = [regex]::Match($text, 'installing=(\d+\.\d+\.\d+)'); if ($m.Success) { $ver = $m.Groups[1].Value }
    $m = [regex]::Match($text, 'backup=(updates/\d+\.\d+\.\d+/previous)\s'); if ($m.Success) { $backup = $m.Groups[1].Value }
    $failedBefore = ($text -match '(?m)^failed=')
  } catch { }
  if ($failedBefore) { Write-Log "the installation of version $ver failed earlier and could not be taken back then; putting the previous version back" }
  else { Write-Log "the installation of version $ver was interrupted; putting the previous version back" }
  $dir = Join-Path $ViewerRoot 'program-previous'      # (installs before the backup= line saved straight into program-previous)
  if ($backup) { $dir = Get-ViewerPath $backup }
  # best effort: whatever can be put back is put back, so the program is never left stuck half-way
  $undo = Undo-Install 'interrupted installation' $dir $true
  if ($undo) { Write-Log "putting the previous version back failed: $undo"; Send-Report 'rollback-failed' "interrupted installation of $ver; putting back failed: $undo"; Save-Log; return }
  if ($script:NotRestored.Count) {
    # some files had no good saved copy: the program is now a mix of two versions, so the latest release is
    # installed completely at this start (not counted against version $ver)
    $script:State['reinstall'] = "$ver " + (Get-UtcNow)
    [void]$script:State.Remove('lastCheckDay')
    Write-Log 'the latest release will be installed completely, because not every file could be put back'
    Send-Report 'rollback-failed' "interrupted installation of $ver; no good saved copy of: $($script:NotRestored -join ', ')"
  }
  if ($ver) { try { Remove-OurTree (Join-Path $ViewerRoot "updates\$ver") } catch { } }
  if (-not $failedBefore -and $script:NotRestored.Count -eq 0) {
    $k = "interrupted.$ver"
    $count = 0; [void][int]::TryParse([string]$script:State[$k], [ref]$count)
    $script:State[$k] = $count + 1
    if ($count + 1 -ge 3) { Add-BadVersion $ver; Write-Log "version $ver was interrupted 3 times and is not tried again" }
  }
  Save-Log
}

function Remove-OldTempCopies {
  try {
    $limit = (Get-Date).AddDays(-2)
    foreach ($f in [IO.Directory]::GetFiles($env:TEMP, 'FamilyTree-*.ps1')) {
      if ([IO.Path]::GetFileName($f) -notmatch '^FamilyTree-(Update-Program|Rollback)-\d+\.ps1$') { continue }
      if ($PSCommandPath -and $f -ieq $PSCommandPath) { continue }
      if ([IO.File]::GetLastWriteTime($f) -lt $limit) { [IO.File]::Delete($f) }
    }
  } catch { }
}

# =====================================================================================
# main
# =====================================================================================
if ($ValidateZip) {
  # only checks a release zip (e.g. before publishing it); changes nothing
  $zipFull = [IO.Path]::GetFullPath($ValidateZip)
  if (-not [IO.File]::Exists($zipFull)) { Write-Output "NOT FOUND: $zipFull"; exit 2 }
  $ver = ''
  $nm = [regex]::Match([IO.Path]::GetFileName($zipFull), '^family-tree-viewer-(\d+\.\d+\.\d+)\.zip$')
  if ($nm.Success) { $ver = Get-ReleaseVersion $nm.Groups[1].Value }
  $res = Test-ReleaseZip $zipFull $ver ''
  if ([IO.File]::Exists("$zipFull.sha256")) {
    $want = [regex]::Match([IO.File]::ReadAllText("$zipFull.sha256"), '^\s*([0-9a-fA-F]{64})(\s|$)')
    if (-not $want.Success -or $want.Groups[1].Value.ToLowerInvariant() -ne (Get-FileSha256 $zipFull)) { $res.Problems.Add('the .sha256 file does not match the zip'); $res.Ok = $false }
  }
  if ($res.Ok) { Write-Output "ZIP OK: version $($res.Version), $($res.Files.Count) program files"; exit 0 }
  Write-Output 'ZIP REFUSED:'
  foreach ($p in $res.Problems) { Write-Output "  $p" }
  exit 1
}

if (-not $Viewer) { $Viewer = Split-Path -Parent $PSScriptRoot }
$ViewerRoot = [IO.Path]::GetFullPath($Viewer).TrimEnd('\')
if ($ViewerRoot.Length -le 3 -or -not [IO.File]::Exists((Join-Path $ViewerRoot 'tools\Update-FamilyTree.ps1'))) {
  Write-Output "This is not a Family Tree Viewer folder (no tools\Update-FamilyTree.ps1): $ViewerRoot"
  $global:FamilyTreeUpdaterStarted = $false
  exit 2
}
if (([IO.File]::GetAttributes($ViewerRoot) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { Write-Output "SAFETY STOP: $ViewerRoot is a link to somewhere else"; $global:FamilyTreeUpdaterStarted = $false; exit 2 }

if ($SelfTest) {
  try {
    $l = Get-InstalledList
    Write-Output "SELFTEST OK version $(Show-Version (Get-InstalledVersion)), $($l.Files.Count) program files"
    exit 0
  } catch { Write-Output "SELFTEST FAILED: $($_.Exception.Message)"; exit 1 }
}

$script:MayWrite = $true
$sha1 = [Security.Cryptography.SHA1]::Create()
$ProgramMutexName = 'Local\FamilyTreeViewerProgramUpdate-' + ((($sha1.ComputeHash([Text.Encoding]::UTF8.GetBytes($ViewerRoot.ToLowerInvariant())) | Select-Object -First 8) | ForEach-Object { $_.ToString('x2') }) -join '')
$sha1.Dispose()
$script:LogFile = Join-Path $ViewerRoot 'updates\program-update-log.txt'
$script:StateFile = Join-Path $ViewerRoot 'updates\state.txt'
$exitCode = 0
$result = ''
$programLock = New-Object System.Threading.Mutex($false, $ProgramMutexName)
$haveProgramLock = $false
try {
  $wait = 0
  if ($Rollback -or $InstallZip) { $wait = $MutexWaitSec }
  $haveProgramLock = Enter-Lock $programLock $wait
  if ($haveProgramLock) {
    $script:State = Read-State
    try { Repair-InterruptedInstall } catch { Write-Log "repairing an interrupted program update failed: $($_.Exception.Message)" }
  }

  # 1. the documents, exactly as before: Update-FamilyTree.ps1, run inside this PowerShell. With -Open the page
  #    is already open (see the top); as with Update-FamilyTree.ps1 -Open, when another document update is busy
  #    (it will refresh the page) this one does not wait for it.
  if (-not $Rollback -and -not $NoDocumentUpdate) {
    $runIt = $true
    if ($Open) {
      if (-not $script:PageOpened) {
        try { $index = Join-Path $ViewerRoot 'index.html'; if ([IO.File]::Exists($index)) { Start-Process -FilePath $index } } catch { Write-Log "could not open the web browser: $($_.Exception.Message)" }
      }
      $probe = New-Object System.Threading.Mutex($false, $DocMutexName)
      $runIt = Enter-Lock $probe 2
      if ($runIt) { $probe.ReleaseMutex() }
      $probe.Dispose()
    }
    if ($runIt) {
      $du = Invoke-DocumentUpdate (Join-Path $ViewerRoot 'tools') $false 3600 $false $true
      if ($du.ExitCode -ne 0) {
        Write-Log "the document update failed ($($du.Why))"
        if ($haveProgramLock) { Send-Report 'document-update-failed' ("document update: $($du.Why)`n" + (Get-ErrorLines)) }
        $script:DocumentsFailed = $true
        $exitCode = 1
      }
    }
  }
  if (-not $haveProgramLock) {
    if ($Rollback -or $InstallZip) { Write-Log 'another program update is running; try again later'; $exitCode = 2 }
    $result = 'busy'
  }
  elseif ($Rollback) {
    $prevDir = Join-Path $ViewerRoot 'program-previous'
    $man = Read-Manifest $prevDir
    if (-not $man.Exists) { Write-Output 'There is no previous version to go back to (the program-previous folder is empty).'; $result = 'nothing-to-roll-back'; $exitCode = 2 }
    else {
      $current = Get-InstalledVersion
      Write-Log "going back to the previous version ($(Show-Version $man.Version)) on request; installed now: $(Show-Version $current)"
      $undo = Undo-Install 'on request' $prevDir $false
      if ($undo) { Write-Log "GOING BACK FAILED: $undo"; $result = 'rollback-failed'; $exitCode = 1 }
      else {
        if ($current -and (Compare-Versions $current $man.Version) -ne 0) { Add-BadVersion $current }
        $du = Invoke-DocumentUpdate (Join-Path $ViewerRoot 'tools') $false 2700 $true $false
        if ($du.ExitCode -ne 0) { Write-Log "the document update after going back failed ($($du.Why))" }
        Set-ProgramMessage "The family tree program went back to the previous version ($(Show-Version $man.Version))."
        Write-Output "Done: the previous version ($(Show-Version $man.Version)) of the family tree program is back in use."
        $result = 'rolled-back-on-request'
      }
    }
  }
  elseif ($InstallZip) {
    $zipFull = [IO.Path]::GetFullPath($InstallZip)
    $nm = [regex]::Match([IO.Path]::GetFileName($zipFull), '^family-tree-viewer-(\d+\.\d+\.\d+)\.zip$')
    if (-not [IO.File]::Exists($zipFull) -or -not $nm.Success) { Write-Log "not a release zip (family-tree-viewer-<version>.zip): $zipFull"; $result = 'refused'; $exitCode = 2 }
    elseif (-not [IO.File]::Exists("$zipFull.sha256")) { Write-Log "the .sha256 file is missing next to $zipFull"; $result = 'refused'; $exitCode = 2 }
    else {
      $newVersion = Get-ReleaseVersion $nm.Groups[1].Value
      $installed = Get-InstalledVersion
      $want = [regex]::Match([IO.File]::ReadAllText("$zipFull.sha256"), '^\s*([0-9a-fA-F]{64})(\s|$)')
      if ((Compare-Versions $newVersion $installed) -le 0 -and $installed -and -not $Force) { Write-Log "version $newVersion is not newer than the installed $installed (use -Force to install it anyway)"; $result = 'up-to-date' }
      elseif (-not (Test-SettingsReady)) { $result = 'settings-missing'; $exitCode = 2 }
      elseif (-not $want.Success -or $want.Groups[1].Value.ToLowerInvariant() -ne (Get-FileSha256 $zipFull)) { Write-Log "version $newVersion was refused: the zip does not match its .sha256 file"; $result = 'refused'; $exitCode = 1 }
      else {
        Write-Log "installing $zipFull (installed: $(Show-Version $installed))"
        $result = Install-Release $newVersion $zipFull
      }
    }
  }
  else {
    $result = Update-FromRelease
    if ($result -eq 'settings-missing') { $exitCode = 2 }
  }
  if ($result -in @('refused', 'rolled-back', 'failed', 'rollback-failed')) { $exitCode = 1 }
} catch {
  $msg = $_.Exception.Message
  Write-Log "PROGRAM UPDATE STOPPED: $msg"
  if ($haveProgramLock) { Send-Report 'program-update-failed' "unexpected problem: $msg" }
  $result = 'error'
  $exitCode = 1
} finally {
  if ($haveProgramLock) {
    if ($result) { $script:State['lastResult'] = "$result " + (Get-UtcNow) }
    try { Save-State } catch { }
    Remove-OldTempCopies
    try { $programLock.ReleaseMutex() } catch { }
  }
  $programLock.Dispose()
  # the quiet outcomes already wrote their one line (or none); the others end with a RESULT line in the log
  if ($result -and @('checked-today', 'busy', 'offline', 'up-to-date', 'bad-version', 'no-release', 'settings-missing', 'documents-failed') -notcontains $result) { Write-Log "RESULT: $result" } else { Say "RESULT: $result" }
  Save-Log
}
exit $exitCode
