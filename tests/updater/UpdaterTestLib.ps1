<#
  UpdaterTestLib.ps1: shared helpers for tests\updater\Test-*.ps1 (dot-sourced; not a test itself).

  Everything happens in a fresh folder FTU-<name>-<time>-<random> under -WorkDir (default: %RUNNER_TEMP% or
  %TEMP%), which is deleted at the end. Nothing else is written, except the updater's own temporary copies in
  %TEMP% (which it deletes itself) and the named locks it shares with any document update on this computer.
  No network: releases are local files or come from a small web server on 127.0.0.1 run by the test itself.
  The family is the made-up one of family-settings.example.js; its Word documents are generated here.
#>
$ErrorActionPreference = 'Stop'
$script:RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$script:PowerShellExe = Join-Path $PSHOME 'powershell.exe'
$script:Passes = 0
$script:Failures = 0
$script:TestRoot = ''

function Check([bool]$cond, [string]$what) {
  if ($cond) { $script:Passes++; Write-Host "  ok    $what" }
  else { $script:Failures++; Write-Host "  FAIL  $what" -ForegroundColor Red }
}
function Step([string]$what) { Write-Host ''; Write-Host "== $what" }
function Complete-Test([string]$name) {
  Write-Host ''
  if ($script:Failures -eq 0) { Write-Host "$name PASSED ($($script:Passes) checks)"; return 0 }
  Write-Host "$name FAILED ($($script:Failures) of $($script:Passes + $script:Failures) checks failed)" -ForegroundColor Red
  return 1
}

# ---------------------------------------------------------------- the test folder
function New-TestRoot([string]$name, [string]$workDir) {
  if (-not $workDir) { $workDir = $env:RUNNER_TEMP }
  if (-not $workDir) { $workDir = $env:TEMP }
  $root = Join-Path ([IO.Path]::GetFullPath($workDir)) ("FTU-$name-" + (Get-Date -Format 'HHmmss') + '-' + ('{0:x4}' -f (Get-Random -Maximum 65536)))
  [void][IO.Directory]::CreateDirectory($root)
  $script:TestRoot = $root
  return $root
}
function Remove-TestRoot {
  if (-not $script:TestRoot) { return }
  if ($env:FTU_KEEP -eq '1') { Write-Host "  (FTU_KEEP=1: the test folder is kept: $script:TestRoot)"; return }
  $full = [IO.Path]::GetFullPath($script:TestRoot).TrimEnd('\')
  if ([IO.Path]::GetFileName($full) -notmatch '^FTU-') { throw "SAFETY STOP: not a test folder: $full" }
  for ($k = 0; $k -lt 10; $k++) {
    try { if ([IO.Directory]::Exists($full)) { [IO.Directory]::Delete('\\?\' + $full, $true) }; return } catch { Start-Sleep -Milliseconds 700 }
  }
  Write-Host "  (could not delete the test folder $full)"
}
function Assert-InTest([string]$path) {
  $f = [IO.Path]::GetFullPath($path)
  if (-not $f.StartsWith($script:TestRoot + '\', [StringComparison]::OrdinalIgnoreCase)) { throw "SAFETY STOP: $f is outside the test folder" }
  return $f
}
function Write-TestFile([string]$path, [string]$text) {
  $f = Assert-InTest $path
  [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($f))
  [IO.File]::WriteAllText($f, $text, (New-Object Text.UTF8Encoding($false)))
}

# ---------------------------------------------------------------- Word documents (minimal .docx files)
function New-Docx([string]$path, [string[]]$paragraphs) {
  Add-Type -AssemblyName System.IO.Compression
  $f = Assert-InTest $path
  [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($f))
  $parts = [ordered]@{
    '[Content_Types].xml' = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>'
    '_rels/.rels'         = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>'
    'word/document.xml'   = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>' +
      ((@($paragraphs) | ForEach-Object { '<w:p><w:r><w:t xml:space="preserve">' + [Security.SecurityElement]::Escape($_) + '</w:t></w:r></w:p>' }) -join '') + '</w:body></w:document>'
  }
  $fs = [IO.File]::Create($f)
  try {
    $zip = New-Object IO.Compression.ZipArchive($fs, [IO.Compression.ZipArchiveMode]::Create)
    try {
      foreach ($k in $parts.Keys) {
        $w = New-Object IO.StreamWriter($zip.CreateEntry($k).Open(), (New-Object Text.UTF8Encoding($false)))
        try { $w.Write($parts[$k]) } finally { $w.Dispose() }
      }
    } finally { $zip.Dispose() }
  } finally { $fs.Dispose() }
}
# The made-up family of family-settings.example.js: 6 life histories and 1 story.
function New-SyntheticDocs([string]$dir) {
  New-Docx (Join-Path $dir 'Ashworth\A1,1 Ashworth Henry.docx') @('Henry James Ashworth (A1,1)', '1920-1995',
    'Father: George William Ashworth (A2,1)(1890-1960)', 'Mother: Clara Fenwick (A2,2)(1895-1970)', 'Birth: 3/14/1920, Millbrook, IL',
    'Henry grew up on a small farm and later worked at the mill.')
  New-Docx (Join-Path $dir 'Ashworth\A2,1 Ashworth George.docx') @('George William Ashworth (A2,1)', '1890-1960',
    'Father: Samuel Ashworth (A3,1)(1860-1930)', 'Mother: Lydia Penrose (A3,2)(1865-1940)', 'George was a carpenter.')
  New-Docx (Join-Path $dir 'Brennan\B1,1 Brennan Margaret.docx') @('Margaret Ann Brennan (B1,1)', '1922-2001',
    'Father: Patrick Joseph Brennan (B2,1)(1895-1970)', 'Mother: Rose Pemberton (B2,2)(1898-1975)', 'Margaret taught school for forty years.')
  New-Docx (Join-Path $dir 'Brennan\B2,1 Brennan Patrick.docx') @('Patrick Joseph Brennan (B2,1)', '1895-1970',
    'Father: Michael Brennan (B3,1)', 'Patrick came across the ocean as a young man.')
  New-Docx (Join-Path $dir 'Carrow\C2,1 Carrow Edwin.docx') @('Edwin Thomas Carrow (C2,1)', '1898-1975',
    'Father: John Carrow (C3,1)(1870-1940)', 'Descendant: Walter James Carrow (C1,1)', 'Edwin kept bees.')
  New-Docx (Join-Path $dir 'Dalby\D2,3 Dalby Arthur.docx') @('Arthur Dalby (D2,3)', '1900-1980',
    'Mother: Ellen Shaw (D3,6)', 'Arthur drove the first motor bus in town.')
  New-Docx (Join-Path $dir 'The Old Mill.docx') @('The Old Mill', 'The mill stood by the river for a hundred years.')
}

# ---------------------------------------------------------------- program copies and releases
function Get-ProgramFiles([string]$programDir) {
  $list = Join-Path $programDir 'tools\program-files.txt'
  if (-not [IO.File]::Exists($list)) {
    # a program from before 1.0 (no allow-list): every file in its folder
    return @([IO.Directory]::GetFiles($programDir, '*', [IO.SearchOption]::AllDirectories) | ForEach-Object { $_.Substring($programDir.Length + 1).Replace('\', '/') })
  }
  return @([IO.File]::ReadAllLines($list) | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') })
}
function Copy-Program([string]$from, [string]$to) {
  foreach ($rel in (Get-ProgramFiles $from)) {
    $dest = Assert-InTest (Join-Path $to ($rel.Replace('/', '\')))
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($dest))
    [IO.File]::Copy((Join-Path $from ($rel.Replace('/', '\'))), $dest, $true)
  }
}
# replaces text in a program file, keeping its encoding (with or without a byte order mark)
function Edit-TestFile([string]$path, [string]$find, [string]$replace) {
  $f = Assert-InTest $path
  $bytes = [IO.File]::ReadAllBytes($f)
  $bom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
  $text = (New-Object Text.UTF8Encoding($false)).GetString($bytes)
  if ($bom) { $text = $text.Substring(1) }
  if ($text.IndexOf($find, [StringComparison]::Ordinal) -lt 0) { throw "Edit-TestFile: '$find' not found in $f" }
  $text = $text.Replace($find, $replace)
  [IO.File]::WriteAllText($f, $text, (New-Object Text.UTF8Encoding($bom)))
}
function Set-ProgramVersion([string]$programDir, [string]$version) {
  $f = Assert-InTest (Join-Path $programDir 'app\version.js')
  $text = [regex]::Replace([IO.File]::ReadAllText($f), "FAMILY_VERSION\s*=\s*'[^']*'", "FAMILY_VERSION = '$version'")
  [IO.File]::WriteAllText($f, $text, (New-Object Text.UTF8Encoding($false)))
}
# A program copy of the repository at $version (optionally changed by $edit), and its release files in
# <root>\releases\<version>\ (zip, .sha256 and release.json with download addresses under $baseUrl).
function New-TestRelease([string]$version, [scriptblock]$edit, [string]$baseUrl) {
  $prog = Join-Path $script:TestRoot "programs\$version"
  Copy-Program $script:RepoRoot $prog
  Set-ProgramVersion $prog $version
  if ($edit) { & $edit $prog }
  $out = Join-Path $script:TestRoot "releases\$version"
  if (-not $baseUrl) { $baseUrl = $out }
  $o = & $script:PowerShellExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $prog 'tools\Build-Release.ps1') -Root $prog -OutDir $out -ReleaseJsonBaseUrl $baseUrl -Quiet
  if ($LASTEXITCODE -ne 0) { throw "Build-Release failed for $version : $($o -join ' ')" }
  return @{ Version = $version; Program = $prog; Dir = $out; Zip = (Join-Path $out "family-tree-viewer-$version.zip"); Json = (Join-Path $out 'release.json') }
}
# A "latest release" answer that points somewhere else (e.g. a web address of the test server)
function Write-ReleaseJson([string]$path, [string]$version, [string]$zipUrl, [string]$shaUrl) {
  $e = { param($s) '"' + ([string]$s).Replace('\', '\\').Replace('"', '\"') + '"' }
  Write-TestFile $path ('{"tag_name":' + (& $e "v$version") + ',"assets":[{"name":' + (& $e "family-tree-viewer-$version.zip") + ',"browser_download_url":' + (& $e $zipUrl) +
    '},{"name":' + (& $e "family-tree-viewer-$version.zip.sha256") + ',"browser_download_url":' + (& $e $shaUrl) + '}]}')
}
# A release zip with hand-made content (to test the installer's refusals); the .sha256 is correct.
function New-CustomZip([string]$dir, [string]$version, [hashtable]$entries) {
  Add-Type -AssemblyName System.IO.Compression
  $zipPath = Assert-InTest (Join-Path $dir "family-tree-viewer-$version.zip")
  [void][IO.Directory]::CreateDirectory($dir)
  $fs = [IO.File]::Create($zipPath)
  try {
    $zip = New-Object IO.Compression.ZipArchive($fs, [IO.Compression.ZipArchiveMode]::Create)
    try {
      foreach ($k in $entries.Keys) {
        $s = $zip.CreateEntry($k).Open()
        try { $b = $entries[$k]; if ($b -is [string]) { $b = [Text.Encoding]::UTF8.GetBytes($b) }; $s.Write($b, 0, $b.Length) } finally { $s.Dispose() }
      }
    } finally { $zip.Dispose() }
  } finally { $fs.Dispose() }
  $sha = [Security.Cryptography.SHA256]::Create()
  $hex = (($sha.ComputeHash([IO.File]::ReadAllBytes($zipPath)) | ForEach-Object { $_.ToString('x2') }) -join '')
  [IO.File]::WriteAllText("$zipPath.sha256", "$hex  family-tree-viewer-$version.zip`n")
  return $zipPath
}
# the files of a built release, as a hashtable name -> bytes (to make bad zips from a good one)
function Read-ZipEntries([string]$zipPath) {
  Add-Type -AssemblyName System.IO.Compression
  $h = [ordered]@{}
  $fs = [IO.File]::OpenRead($zipPath)
  try {
    $zip = New-Object IO.Compression.ZipArchive($fs, [IO.Compression.ZipArchiveMode]::Read)
    try {
      foreach ($e in $zip.Entries) { $ms = New-Object IO.MemoryStream; $s = $e.Open(); $s.CopyTo($ms); $s.Dispose(); $h[$e.FullName] = $ms.ToArray() }
    } finally { $zip.Dispose() }
  } finally { $fs.Dispose() }
  return $h
}

# ---------------------------------------------------------------- an installation to update
# <root>\<name>\Family Tree Viewer with the given program, the example family's settings, a tools\settings.txt
# pointing at the shared synthetic documents, a few files that are not the program's, and a first data\ build.
function New-TestViewer([string]$name, [string]$programDir, [string]$docsDir, [switch]$NoSettings) {
  $v = Join-Path $script:TestRoot "$name\Family Tree Viewer"
  Copy-Program $programDir $v
  if (-not $NoSettings) { [IO.File]::Copy((Join-Path $script:RepoRoot 'family-settings.example.js'), (Assert-InTest (Join-Path $v 'family-settings.js')), $true) }
  Write-TestFile (Join-Path $v 'tools\settings.txt') "SourceFolder = $docsDir`r`n"
  Write-TestFile (Join-Path $v 'CLAUDE.md') "notes that belong to this computer`r`n"
  Write-TestFile (Join-Path $v 'my own notes.txt') "not part of the program`r`n"
  Write-TestFile (Join-Path $v 'dev\private\secret.txt') "private`r`n"
  Write-TestFile (Join-Path $v 'data\keep-me.txt') "a file in data that no update may touch`r`n"
  $o = & $script:PowerShellExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $v 'tools\Update-FamilyTree.ps1') -Quiet
  if ($LASTEXITCODE -ne 0) { throw "the first document update in $v failed: $($o -join ' ')" }
  return $v
}
function Copy-TestViewer([string]$from, [string]$name) {
  $to = Assert-InTest (Join-Path $script:TestRoot "$name\Family Tree Viewer")
  foreach ($f in [IO.Directory]::GetFiles($from, '*', [IO.SearchOption]::AllDirectories)) {
    $d = Join-Path $to $f.Substring($from.Length + 1)
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($d))
    [IO.File]::Copy($f, $d, $true)
  }
  return $to
}
function Get-FileHashHex([string]$path) {
  $sha = [Security.Cryptography.SHA256]::Create()
  try { return (($sha.ComputeHash([IO.File]::ReadAllBytes($path)) | ForEach-Object { $_.ToString('x2') }) -join '') } finally { $sha.Dispose() }
}
# every file of the installation except updates\ and program-previous\ (name -> sha256)
function Get-Snapshot([string]$viewer) {
  $h = @{}
  foreach ($f in [IO.Directory]::GetFiles($viewer, '*', [IO.SearchOption]::AllDirectories)) {
    $rel = $f.Substring($viewer.Length + 1).Replace('\', '/')
    $first = $rel.Split('/')[0]
    if ($first -eq 'updates' -or $first -eq 'program-previous') { continue }
    $h[$rel] = Get-FileHashHex $f
  }
  return $h
}
# The files that belong to the family or the computer, never to the program: they must never change.
# (data\status.js and data\update-log.txt are rewritten by every document update, so they are left out.)
function Test-ProtectedSame($before, [string]$viewer, [string]$when) {
  $after = Get-Snapshot $viewer
  $bad = @()
  foreach ($k in $before.Keys) {
    $prot = ($k -eq 'family-settings.js' -or $k -eq 'tools/settings.txt' -or $k -eq 'CLAUDE.md' -or $k -eq 'HANDOFF.md' -or $k -eq 'my own notes.txt' -or $k.StartsWith('dev/') -or $k.StartsWith('data/'))
    if (-not $prot -or $k -eq 'data/status.js' -or $k -eq 'data/update-log.txt') { continue }
    if ($after[$k] -ne $before[$k]) { $bad += $k }
  }
  foreach ($k in $after.Keys) { if (($k.StartsWith('data/') -or $k.StartsWith('dev/')) -and -not $before.ContainsKey($k)) { $bad += "$k (new)" } }
  Check ($bad.Count -eq 0) "$when : family-settings.js, tools\settings.txt, data\, dev\ and the other files are unchanged$(if ($bad.Count) { ' (changed: ' + ($bad -join ', ') + ')' })"
}
# The program files of the installation are exactly those of $programDir (and no other program files).
function Test-ProgramIs([string]$viewer, [string]$programDir, [string]$what) {
  $bad = @()
  foreach ($rel in (Get-ProgramFiles $programDir)) {
    $a = Join-Path $viewer ($rel.Replace('/', '\')); $b = Join-Path $programDir ($rel.Replace('/', '\'))
    if (-not [IO.File]::Exists($a) -or (Get-FileHashHex $a) -ne (Get-FileHashHex $b)) { $bad += $rel }
  }
  Check ($bad.Count -eq 0) "$what$(if ($bad.Count) { ' (different: ' + ($bad -join ', ') + ')' })"
}

# ---------------------------------------------------------------- running the updater like the icon does
# (a copy of the installed tools\Update-Program.ps1, run from elsewhere with -Viewer)
function Invoke-Updater([string]$viewer, [string[]]$more, [string]$scriptPath) {
  if (-not $scriptPath) { $scriptPath = Join-Path $viewer 'tools\Update-Program.ps1' }
  $copy = Assert-InTest (Join-Path $script:TestRoot ('FamilyTree-Update-Program-test-' + (Get-Random) + '.ps1'))
  [IO.File]::Copy($scriptPath, $copy, $true)
  $all = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $copy, '-Viewer', $viewer) + @($more)
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $o = & $script:PowerShellExe @all
  $code = $LASTEXITCODE
  [IO.File]::Delete($copy)
  $text = (@($o) -join "`n")
  $m = [regex]::Match($text, 'RESULT: (\S*)')
  $res = ''
  if ($m.Success) { $res = $m.Groups[1].Value }
  Write-Host ("  (updater: exit {0}, result '{1}', {2:N1} s)" -f $code, $res, ($sw.ElapsedMilliseconds / 1000))
  return @{ Code = $code; Out = $text; Result = $res }
}
function Get-UpdaterLog([string]$viewer) {
  $f = Join-Path $viewer 'updates\program-update-log.txt'
  if ([IO.File]::Exists($f)) { return [IO.File]::ReadAllText($f) }
  return ''
}
function Get-UpdaterState([string]$viewer) {
  $h = @{}
  $f = Join-Path $viewer 'updates\state.txt'
  if ([IO.File]::Exists($f)) { foreach ($l in [IO.File]::ReadAllLines($f)) { if ($l -match '^([^#=]+)=(.*)$') { $h[$Matches[1]] = $Matches[2] } } }
  return $h
}
function Set-CheckedToday([string]$viewer) {
  # the once-a-day check counts as done today, so the updater does not ask anyone for a release
  Write-TestFile (Join-Path $viewer 'updates\state.txt') ("lastCheckDay=" + (Get-Date).ToString('yyyy-MM-dd') + "`r`n")
}
function Get-InstalledVersion([string]$viewer) {
  $f = Join-Path $viewer 'app\version.js'
  if (-not [IO.File]::Exists($f)) { return '' }
  $m = [regex]::Match([IO.File]::ReadAllText($f), "FAMILY_VERSION\s*=\s*'([^']*)'")
  return $m.Groups[1].Value
}
function Get-StatusText([string]$viewer) {
  # (shared read: a document update may be replacing the file right now)
  $f = Join-Path $viewer 'data\status.js'
  for ($k = 0; $k -lt 10; $k++) {
    try {
      if (-not [IO.File]::Exists($f)) { return '' }
      $fs = New-Object IO.FileStream($f, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
      try { return (New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8)).ReadToEnd() } finally { $fs.Dispose() }
    } catch { Start-Sleep -Milliseconds 100 }
  }
  return ''
}

# ---------------------------------------------------------------- a tiny web server on 127.0.0.1 (in this process)
# Serves files from $docRoot; any path starting with /fail500 answers HTTP 500; a POST answers 200.
# Every request is recorded in .Log as "<METHOD> <path> TAB <body>".
function Start-FakeServer([string]$docRoot) {
  $listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
  $listener.Start()
  $log = [Collections.ArrayList]::Synchronized((New-Object Collections.ArrayList))
  $ps = [PowerShell]::Create()
  [void]$ps.AddScript({
      param($listener, $docRoot, $log)
      while ($true) {
        try { $client = $listener.AcceptTcpClient() } catch { break }
        try {
          $client.ReceiveTimeout = 5000
          $stream = $client.GetStream()
          $ms = New-Object IO.MemoryStream
          $buf = New-Object byte[] 65536
          $headEnd = -1
          while ($headEnd -lt 0) {
            $n = $stream.Read($buf, 0, $buf.Length)
            if ($n -le 0) { break }
            $ms.Write($buf, 0, $n)
            $headEnd = [Text.Encoding]::ASCII.GetString($ms.ToArray()).IndexOf("`r`n`r`n")
          }
          if ($headEnd -lt 0) { continue }
          $head = [Text.Encoding]::ASCII.GetString($ms.ToArray(), 0, $headEnd)
          $lines = $head -split "`r`n"
          $first = $lines[0].Split(' ')
          $len = 0
          foreach ($l in $lines) { if ($l -match '^(?i)Content-Length:\s*(\d+)') { $len = [int]$Matches[1] } }
          if ($len -gt 0) {
            foreach ($l in $lines) { if ($l -match '^(?i)Expect:\s*100-continue') { $c = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 100 Continue`r`n`r`n"); $stream.Write($c, 0, $c.Length) } }
          }
          while ($ms.Length - ($headEnd + 4) -lt $len) { $n = $stream.Read($buf, 0, $buf.Length); if ($n -le 0) { break }; $ms.Write($buf, 0, $n) }
          $body = ''
          if ($len -gt 0) { $body = [Text.Encoding]::UTF8.GetString($ms.ToArray(), $headEnd + 4, $len) }
          [void]$log.Add($first[0] + ' ' + $first[1] + "`t" + $body)
          $status = '200 OK'; $bytes = [Text.Encoding]::ASCII.GetBytes('ok')
          $path = [Uri]::UnescapeDataString($first[1].Split('?')[0])
          if ($path.StartsWith('/fail500')) { $status = '500 Internal Server Error'; $bytes = [Text.Encoding]::ASCII.GetBytes('server error') }
          elseif ($first[0] -eq 'GET') {
            $file = Join-Path $docRoot ($path.TrimStart('/').Replace('/', '\'))
            if ($path.Contains('..') -or -not [IO.File]::Exists($file)) { $status = '404 Not Found'; $bytes = [Text.Encoding]::ASCII.GetBytes('not found') }
            else { $bytes = [IO.File]::ReadAllBytes($file) }
          }
          $h = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 $status`r`nContent-Length: $($bytes.Length)`r`nContent-Type: application/octet-stream`r`nConnection: close`r`n`r`n")
          $stream.Write($h, 0, $h.Length)
          $stream.Write($bytes, 0, $bytes.Length)
          $stream.Flush()
        } catch { } finally { $client.Close() }
      }
    }).AddArgument($listener).AddArgument($docRoot).AddArgument($log)
  $handle = $ps.BeginInvoke()
  $port = $listener.LocalEndpoint.Port
  return @{ Port = $port; Base = "http://127.0.0.1:$port"; Listener = $listener; PS = $ps; Handle = $handle; Log = $log }
}
function Stop-FakeServer($server) {
  if (-not $server) { return }
  try { $server.Listener.Stop() } catch { }
  try { [void]$server.Handle.AsyncWaitHandle.WaitOne(3000) } catch { }
  try { $server.PS.Dispose() } catch { }
}
# a port on 127.0.0.1 where nothing listens
function Get-DeadPort {
  $l = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
  $l.Start(); $p = $l.LocalEndpoint.Port; $l.Stop()
  return $p
}
# turns on automatic reports in an installation's family-settings.js (to the test server)
function Set-ReportForm([string]$viewer, [string]$formUrl) {
  Edit-TestFile (Join-Path $viewer 'family-settings.js') "    formUrl: ''," "    formUrl: '$formUrl',"
}
