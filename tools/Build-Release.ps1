<#
  Build-Release.ps1
  -----------------
  Makes the release files of the Family Tree Viewer program from the allow-list tools\program-files.txt:
    family-tree-viewer-<version>.zip          exactly the listed files, with "/" paths, nothing else
    family-tree-viewer-<version>.zip.sha256   "<lowercase hex SHA-256>  family-tree-viewer-<version>.zip"
  and then checks the zip with the installer's own rules (tools\Update-Program.ps1 -ValidateZip).

  Usage (Windows PowerShell 5.1):
    powershell -NoProfile -ExecutionPolicy Bypass -File tools\Build-Release.ps1 [-Root <program folder>] [-OutDir <folder>]
        [-Version <x.y.z or vx.y.z>] [-ReleaseJsonBaseUrl <address or folder>] [-Quiet]

    -Root      the program folder (default: the folder above this script)
    -OutDir    where to write the files (default: %TEMP%\FamilyTree-Release). Created if needed; an older zip
               or .sha256 of the same version there is replaced.
    -Version   the version the release must have (e.g. the git tag "v1.0.1"); it must equal app\version.js
    -ReleaseJsonBaseUrl  also write release.json, shaped like GitHub's "latest release" answer, whose download
               addresses are <this>/<file name> (for local tests with Update-Program.ps1 -ReleaseUrl)

  Exit code: 0 = done, 1 = something is wrong (nothing usable was written).
  The rules: every listed file exists; every path is relative, with "/", no "..", no ":", no backslash;
  nothing under data/, dev/, updates/, program-previous/, and never family-settings.js or tools/settings.txt;
  no "~" (a short 8.3 name could stand for another file); the list includes itself and the required files
  (index.html, both .cmd files, app/version.js, app/config.js, tools/Update-FamilyTree.ps1, Update-Program.ps1,
  program-files.txt, Check-Tree.ps1, check-tree.html); .cmd files have Windows (CR LF) line endings;
  app\version.js holds the version.
#>
param(
  [string]$Root = '',
  [string]$OutDir = '',
  [string]$Version = '',
  [string]$ReleaseJsonBaseUrl = '',
  [switch]$Quiet
)
$ErrorActionPreference = 'Stop'
function Say([string]$msg) { if (-not $Quiet) { Write-Host $msg } }
function Fail([string]$msg) { Write-Host "BUILD-RELEASE ERROR: $msg"; exit 1 }

if (-not $Root) { $Root = Split-Path -Parent $PSScriptRoot }
$RootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\')
$ListFile = Join-Path $RootFull 'tools\program-files.txt'
if (-not [IO.File]::Exists($ListFile)) { Fail "no tools\program-files.txt in $RootFull" }

# ---------- the same path rules as tools\Update-Program.ps1 (Test-ProgramPath)
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
    if ($s.Contains('~')) { return 'a "~" in the name (it could be the short name of another file)' }
  }
  if ($ForbiddenFirstFolders -contains $segs[0]) { return "inside $($segs[0])/ (it belongs to the family or to the updater, never to the program)" }
  foreach ($x in $ForbiddenFiles) { if ($rel -ieq $x) { return "$x belongs to the family, never to the program" } }
  return ''
}

# ---------- the list
$files = New-Object System.Collections.Generic.List[string]
$seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
$problems = New-Object System.Collections.Generic.List[string]
$n = 0
foreach ($line in ([IO.File]::ReadAllText($ListFile) -split "\r?\n")) {
  $n++
  $t = $line.Trim().TrimStart([char]0xFEFF).Trim()
  if (-not $t -or $t.StartsWith('#')) { continue }
  $why = Test-ProgramPath $t
  if ($why) { $problems.Add("tools\program-files.txt line ${n} '$t': $why"); continue }
  if (-not $seen.Add($t)) { $problems.Add("tools\program-files.txt line ${n} '$t' is listed twice"); continue }
  $full = Join-Path $RootFull ($t.Replace('/', '\'))
  if (-not [IO.File]::Exists($full)) { $problems.Add("'$t' is listed but does not exist in $RootFull"); continue }
  if ((([IO.File]::GetAttributes($full)) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { $problems.Add("'$t' is a link"); continue }
  if ($t.EndsWith('.cmd', [StringComparison]::OrdinalIgnoreCase)) {
    $bytes = [IO.File]::ReadAllBytes($full)
    for ($i = 0; $i -lt $bytes.Length; $i++) { if ($bytes[$i] -eq 10 -and ($i -eq 0 -or $bytes[$i - 1] -ne 13)) { $problems.Add("'$t' must have Windows (CR LF) line endings"); break } }
  }
  $files.Add($t)
}
if (-not $seen.Contains('tools/program-files.txt')) { $problems.Add('tools\program-files.txt does not list itself') }
foreach ($req in @('index.html', 'Open Family Tree.cmd', 'Go back to the previous version.cmd', 'app/version.js', 'app/config.js',
    'tools/Update-FamilyTree.ps1', 'tools/Update-Program.ps1', 'tools/program-files.txt', 'tools/Check-Tree.ps1', 'tools/check-tree.html')) {
  if (-not $seen.Contains($req)) { $problems.Add("the list has no $req") }
}

# ---------- the version
$verFile = Join-Path $RootFull 'app\version.js'
$fileVersion = ''
if ([IO.File]::Exists($verFile)) {
  $m = [regex]::Match([IO.File]::ReadAllText($verFile), 'FAMILY_VERSION\s*=\s*[''"]([0-9A-Za-z.+-]{1,40})[''"]')
  if ($m.Success) { $fileVersion = $m.Groups[1].Value }
}
if ($fileVersion -notmatch '^\d{1,6}\.\d{1,6}\.\d{1,6}$') { $problems.Add("app\version.js must hold a version like '1.0.0' (found '$fileVersion')") }
if ($Version) {
  $want = $Version.Trim() -replace '^[vV]', ''
  if ($want -ne $fileVersion) { $problems.Add("the requested version $Version is not the version in app\version.js ($fileVersion)") }
}
if ($problems.Count) { foreach ($p in $problems) { Write-Host "  $p" }; Fail "$($problems.Count) problem(s); no release was made" }

# ---------- the zip
if (-not $OutDir) { $OutDir = Join-Path $env:TEMP 'FamilyTree-Release' }
$OutFull = [IO.Path]::GetFullPath($OutDir).TrimEnd('\')
if ($OutFull.StartsWith($RootFull + '\', [StringComparison]::OrdinalIgnoreCase)) {
  foreach ($f in $files) { if ($OutFull.StartsWith((Join-Path $RootFull ($f.Replace('/', '\'))), [StringComparison]::OrdinalIgnoreCase)) { Fail '-OutDir cannot be inside a program file' } }
}
if (-not [IO.Directory]::Exists($OutFull)) { [void][IO.Directory]::CreateDirectory($OutFull) }
$zipName = "family-tree-viewer-$fileVersion.zip"
$zipPath = Join-Path $OutFull $zipName
$shaPath = "$zipPath.sha256"
foreach ($p in @($zipPath, $shaPath)) { if ([IO.File]::Exists($p)) { [IO.File]::Delete($p) } }

Add-Type -AssemblyName System.IO.Compression
$fs = New-Object IO.FileStream($zipPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
try {
  $zip = New-Object IO.Compression.ZipArchive($fs, [IO.Compression.ZipArchiveMode]::Create, $true)
  try {
    foreach ($f in $files) {
      $src = Join-Path $RootFull ($f.Replace('/', '\'))
      $entry = $zip.CreateEntry($f, [IO.Compression.CompressionLevel]::Optimal)
      $entry.LastWriteTime = New-Object DateTimeOffset([IO.File]::GetLastWriteTime($src))
      $out = $entry.Open()
      try { $in = [IO.File]::OpenRead($src); try { $in.CopyTo($out) } finally { $in.Dispose() } } finally { $out.Dispose() }
    }
  } finally { $zip.Dispose() }
} finally { $fs.Dispose() }

$sha = [Security.Cryptography.SHA256]::Create()
$zs = [IO.File]::OpenRead($zipPath)
try { $hex = (($sha.ComputeHash($zs) | ForEach-Object { $_.ToString('x2') }) -join '') } finally { $zs.Dispose(); $sha.Dispose() }
[IO.File]::WriteAllText($shaPath, "$hex  $zipName`n", (New-Object Text.ASCIIEncoding))

# ---------- check it with the installer's own rules
$updater = Join-Path $RootFull 'tools\Update-Program.ps1'
$check = & (Join-Path $PSHOME 'powershell.exe') -NoProfile -ExecutionPolicy Bypass -File $updater -ValidateZip $zipPath
$checkExit = $LASTEXITCODE
if ($checkExit -ne 0) {
  Write-Host ($check -join "`n")
  foreach ($p in @($zipPath, $shaPath)) { if ([IO.File]::Exists($p)) { [IO.File]::Delete($p) } }
  Fail 'the zip does not pass the installer''s own check (Update-Program.ps1 -ValidateZip); it was deleted'
}

# ---------- optional: a "latest release" answer for local tests
if ($ReleaseJsonBaseUrl) {
  $base = $ReleaseJsonBaseUrl.TrimEnd('/', '\')
  if ($base -match '^[A-Za-z][A-Za-z0-9+.-]*://') { $zipUrl = "$base/$zipName"; $shaUrl = "$base/$zipName.sha256" }
  else { $zipUrl = Join-Path $base $zipName; $shaUrl = Join-Path $base "$zipName.sha256" }
  $esc = { param($s) '"' + ([string]$s).Replace('\', '\\').Replace('"', '\"') + '"' }
  $json = '{"tag_name":' + (& $esc "v$fileVersion") + ',"name":' + (& $esc $fileVersion) + ',"draft":false,"prerelease":false,"assets":[' +
    '{"name":' + (& $esc $zipName) + ',"size":' + (New-Object IO.FileInfo($zipPath)).Length + ',"browser_download_url":' + (& $esc $zipUrl) + '},' +
    '{"name":' + (& $esc "$zipName.sha256") + ',"size":' + (New-Object IO.FileInfo($shaPath)).Length + ',"browser_download_url":' + (& $esc $shaUrl) + '}]}'
  [IO.File]::WriteAllText((Join-Path $OutFull 'release.json'), $json, (New-Object Text.UTF8Encoding($false)))
}

Say "Release $fileVersion : $($files.Count) program files"
Say "  $zipPath"
Say "  $shaPath  ($hex)"
if ($ReleaseJsonBaseUrl) { Say "  $(Join-Path $OutFull 'release.json')" }
exit 0
