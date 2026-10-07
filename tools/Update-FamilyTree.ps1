<#
  Update-FamilyTree.ps1
  ---------------------
  Reads the life-history Word documents (.docx) and refreshes the Family Tree Viewer.

  SAFETY PROMISE
    * Every document in the life-history folder is opened READ-ONLY (and shared, so Word can keep it open).
    * Nothing outside this viewer's own "data" folder is ever created, changed, moved or deleted.
    * The only things ever removed are this script's own old picture copies / cache files inside
      "Family Tree Viewer\data" (guarded by Assert-InsideDataFolder below).

  Usage (normally run by the "Family Tree" desktop shortcut):
    powershell -NoProfile -ExecutionPolicy Bypass -File Update-FamilyTree.ps1 [-Open] [-Quiet] [-Full] [-Source <folder>]
#>
param(
  [switch]$Open,     # open the viewer in the web browser right away (it refreshes itself when the update finishes)
  [switch]$Quiet,    # no console output (used by the background task)
  [switch]$Full,     # ignore the cache and re-read every document
  [string]$Source    # life-history folder; default = the folder that contains "Family Tree Viewer"
)

$ErrorActionPreference = 'Stop'
$BuilderVersion = 4

$Viewer  = Split-Path -Parent $PSScriptRoot
$DataDir = Join-Path $Viewer 'data'
$CacheDir = Join-Path $DataDir 'cache'
$MediaDir = Join-Path $DataDir 'media'
$LogFile = Join-Path $DataDir 'update-log.txt'

function Say([string]$msg) { if (-not $Quiet) { Write-Host $msg } }

# Log lines are collected and written once at the end (see Save-Log), always as a fresh file.
$script:LogLines = New-Object System.Collections.Generic.List[string]
function Write-Log([string]$msg) {
  $script:LogLines.Add((Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + '  ' + $msg)
}

# Every write/delete goes through these guards: they refuse any path outside the viewer's data folder,
# and any path that passes through a junction or symbolic link (which could lead somewhere else).
$DataDirFull = [System.IO.Path]::GetFullPath($DataDir).TrimEnd('\') + '\'
function Assert-InsideDataFolder([string]$path) {
  $full = [System.IO.Path]::GetFullPath($path)
  if (-not $full.StartsWith($DataDirFull, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "SAFETY STOP: refusing to write or delete outside the viewer data folder: $full"
  }
  $p = $full
  while ($p -and $p.TrimEnd('\').Length -ge $DataDirFull.TrimEnd('\').Length) {
    if ([System.IO.File]::Exists($p) -or [System.IO.Directory]::Exists($p)) {
      if ([System.IO.File]::GetAttributes($p) -band [System.IO.FileAttributes]::ReparsePoint) {
        throw "SAFETY STOP: $p is a link to somewhere else; nothing was changed"
      }
    }
    $p = [System.IO.Path]::GetDirectoryName($p)
  }
  return $full
}
function Write-DataFile([string]$path, [string]$text) {
  $full = Assert-InsideDataFolder $path
  $tmp = "$full.tmp"
  # a fresh file every time (never write into an existing one, which could be a hard link)
  if ([System.IO.File]::Exists($tmp)) { [System.IO.File]::Delete($tmp) }
  [System.IO.File]::WriteAllText($tmp, $text, (New-Object System.Text.UTF8Encoding($false)))
  $lastErr = ''
  for ($try = 0; $try -lt 20; $try++) {
    try {
      # [NullString]::Value: PowerShell would otherwise pass "" (not null) as the backup file name
      if ([System.IO.File]::Exists($full)) { [System.IO.File]::Replace($tmp, $full, [NullString]::Value) } else { [System.IO.File]::Move($tmp, $full) }
      return
    } catch {
      $lastErr = $_.Exception.Message
      if ($try -ge 3) {
        # fall back to delete + move (our own generated file only)
        try { if ([System.IO.File]::Exists($full)) { [System.IO.File]::Delete($full) }; [System.IO.File]::Move($tmp, $full); return } catch { $lastErr = $_.Exception.Message }
      }
      Start-Sleep -Milliseconds 150
    }
  }
  throw "Could not write $full ($lastErr)"
}
# Only names this script makes itself are ever deleted; anything else found in data\ is left alone.
$GenCacheName = '^d[0-9a-f]{12}\.(json|key)(\.tmp)?$'          # data\cache\d1a2b3c4d5e6f.json / .key
$GenMediaDir  = '^d[0-9a-f]{12}(\.new|\.old)?$'                # data\media\d1a2b3c4d5e6f\
$GenMediaFile = '^\d+\.(png|jpe?g|gif|bmp|webp|svg)$'          # data\media\<doc>\3.jpg
function Remove-GeneratedFile([string]$path) {
  $full = Assert-InsideDataFolder $path
  if ([System.IO.File]::Exists($full)) { [System.IO.File]::Delete($full) }
}
function Remove-MediaFolder([string]$path) {
  $full = Assert-InsideDataFolder $path
  if (-not [System.IO.Directory]::Exists($full)) { return }
  if ([System.IO.Path]::GetFileName($full) -notmatch $GenMediaDir) { Write-Log "left $full alone (not made by this program)"; return }
  foreach ($f in [System.IO.Directory]::GetFiles($full)) {
    if ([System.IO.Path]::GetFileName($f) -match $GenMediaFile) { Remove-GeneratedFile $f } else { Write-Log "left $f alone (not made by this program)" }
  }
  if ([System.IO.Directory]::GetFileSystemEntries($full).Length -eq 0) { [System.IO.Directory]::Delete($full) }
}
function Move-MediaFolder([string]$from, [string]$to) {
  [System.IO.Directory]::Move((Assert-InsideDataFolder $from), (Assert-InsideDataFolder $to))
}
function Save-Log {
  try {
    $old = @()
    if ([System.IO.File]::Exists($LogFile)) { $old = [System.IO.File]::ReadAllLines($LogFile) }
    $all = @($old) + @($script:LogLines)
    if ($all.Count -gt 600) { $all = $all[($all.Count - 600)..($all.Count - 1)] }
    Write-DataFile $LogFile (($all -join "`r`n") + "`r`n")
    $script:LogLines.Clear()
  } catch { }
}

# Which folder holds the life-history documents (normally the folder that contains "Family Tree Viewer").
function Resolve-Source([string]$given) {
  $settings = Join-Path $PSScriptRoot 'settings.txt'
  if (-not $given -and [System.IO.File]::Exists($settings)) {
    foreach ($line in [System.IO.File]::ReadAllLines($settings)) {
      if ($line -match '^\s*SourceFolder\s*=\s*(.*?)\s*$') { $given = $Matches[1].Trim().Trim('"').Trim() }
    }
  }
  if (-not $given) { $given = Split-Path -Parent $Viewer }
  if (-not [System.IO.Path]::IsPathRooted($given)) { $given = Join-Path $Viewer $given }
  $full = [System.IO.Path]::GetFullPath($given).TrimEnd('\')
  if ($full.Length -le 3) { throw "The documents folder cannot be a whole drive ($full). Check tools\settings.txt." }
  if (-not [System.IO.Directory]::Exists($full)) { throw "Cannot find the life-history folder: $full" }
  return $full
}

# Every file under the documents folder. Copes with very long paths and folder names that end in a
# dot or space; never follows junctions/links; skips this viewer and any copy of it; a folder that
# cannot be opened is reported and the rest carries on.
function Get-SourceFiles([string]$root, [string]$skipDir) {
  $files = New-Object System.Collections.Generic.List[object]
  $script:FolderProblems = New-Object System.Collections.Generic.List[string]
  $prefix = '\\?\'
  if ($root.StartsWith('\\')) { $prefix = '\\?\UNC\'; $rootLong = $prefix + $root.Substring(2) } else { $rootLong = $prefix + $root }
  $stack = New-Object System.Collections.Generic.Stack[string]
  $stack.Push($rootLong)
  while ($stack.Count) {
    $dirLong = $stack.Pop()
    try {
      foreach ($e in (New-Object System.IO.DirectoryInfo($dirLong)).EnumerateFileSystemInfos()) {
        if ($e.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { continue }
        if ($e -is [System.IO.DirectoryInfo]) {
          $plain = Get-PlainPath $e.FullName
          if (($plain.TrimEnd('\') + '\').StartsWith($skipDir, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
          if ([System.IO.File]::Exists($e.FullName + '\tools\Update-FamilyTree.ps1')) { continue }   # a copy of this viewer
          $stack.Push($e.FullName)
        } else {
          $files.Add($e)
        }
      }
    } catch {
      $script:FolderProblems.Add((Get-PlainPath $dirLong))
      Write-Log "could not look inside the folder $(Get-PlainPath $dirLong): $($_.Exception.Message)"
    }
  }
  return , $files
}
function Get-PlainPath([string]$p) {
  if ($p.StartsWith('\\?\UNC\')) { return '\\' + $p.Substring(8) }
  if ($p.StartsWith('\\?\')) { return $p.Substring(4) }
  return $p
}

# ---------- JSON helpers ----------
$script:JsonEsc = New-Object System.Text.RegularExpressions.Regex('[\\"\u0000-\u001f  ]')
$script:JsonEval = [System.Text.RegularExpressions.MatchEvaluator] {
  param($m)
  $c = [int][char]$m.Value
  switch ($c) { 34 { '\"' } 92 { '\\' } 10 { '\n' } 13 { '\r' } 9 { '\t' } default { '\u{0:x4}' -f $c } }
}
function JStr([string]$s) {
  if ($null -eq $s) { return 'null' }
  return '"' + $script:JsonEsc.Replace($s, $script:JsonEval) + '"'
}

# ---------- program version (app\version.js, the single source of truth) ----------
# Copied into status.js as "version", so an open page sees that a program update was installed and
# reloads itself. '' when the file is missing or unreadable; status.js then has no "version" (as before).
function Get-ProgramVersion {
  try {
    $versionFile = Join-Path $Viewer 'app\version.js'
    if (-not [System.IO.File]::Exists($versionFile)) { return '' }
    $versionMatch = [regex]::Match([System.IO.File]::ReadAllText($versionFile), 'FAMILY_VERSION\s*=\s*[''"]([0-9A-Za-z.+-]{1,40})[''"]')
    if ($versionMatch.Success) { return $versionMatch.Groups[1].Value }
  } catch { }
  return ''
}
$ProgramVersion = Get-ProgramVersion

# ---------- status file (the open web page watches this) ----------
$StatusFile = Join-Path $DataDir 'status.js'
function Write-Status([string]$state, [int]$done, [int]$total, [string]$extra) {
  $now = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
  if (-not $extra) { $extra = '' }
  $versionJson = ''
  if ($ProgramVersion) { $versionJson = ",`"version`":" + (JStr $ProgramVersion) }
  $js = "window.FAMILY_STATUS = {`"state`":$(JStr $state),`"time`":$(JStr $now),`"done`":$done,`"total`":$total$versionJson$extra};"
  try { Write-DataFile $StatusFile $js } catch { }
}

# ---------- docx reading ----------
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.Drawing

$NsW   = 'http://schemas.openxmlformats.org/wordprocessingml/2006/main'
$NsR   = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships'
$NT = New-Object System.Xml.NameTable
$NS = New-Object System.Xml.XmlNamespaceManager($NT)
$NS.AddNamespace('w', $NsW)
$NS.AddNamespace('r', $NsR)
$NS.AddNamespace('wp', 'http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing')
$NS.AddNamespace('a', 'http://schemas.openxmlformats.org/drawingml/2006/main')
$NS.AddNamespace('pic', 'http://schemas.openxmlformats.org/drawingml/2006/picture')
$NS.AddNamespace('v', 'urn:schemas-microsoft-com:vml')
$NS.AddNamespace('mc', 'http://schemas.openxmlformats.org/markup-compatibility/2006')
$NS.AddNamespace('rel', 'http://schemas.openxmlformats.org/package/2006/relationships')
$ElementNode = [System.Xml.XmlNodeType]::Element
# wrappers whose contents are shown as normal text (deleted text, bookmarks, proofing marks are skipped)
$PassThrough = @{ smartTag = 1; customXml = 1; ins = 1; moveTo = 1; dir = 1; bdo = 1; sdtContent = 1 }

# Word's "Strict Open XML" format uses other names for the same things; translate them on reading.
$StrictNames = [ordered]@{
  'http://purl.oclc.org/ooxml/wordprocessingml/main' = 'http://schemas.openxmlformats.org/wordprocessingml/2006/main'
  'http://purl.oclc.org/ooxml/officeDocument/relationships' = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships'
  'http://purl.oclc.org/ooxml/drawingml/wordprocessingDrawing' = 'http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing'
  'http://purl.oclc.org/ooxml/drawingml/picture' = 'http://schemas.openxmlformats.org/drawingml/2006/picture'
  'http://purl.oclc.org/ooxml/drawingml/main' = 'http://schemas.openxmlformats.org/drawingml/2006/main'
}
function Read-ZipXml($zip, [string]$name) {
  $e = $zip.GetEntry($name)
  if (-not $e) { return $null }
  $sr = New-Object System.IO.StreamReader($e.Open(), $true)
  try { $text = $sr.ReadToEnd() } finally { $sr.Dispose() }
  if ($text.Contains('purl.oclc.org/ooxml/')) { foreach ($k in $StrictNames.Keys) { $text = $text.Replace($k, $StrictNames[$k]) } }
  $x = New-Object System.Xml.XmlDocument($NT)
  $x.PreserveWhitespace = $true
  $x.XmlResolver = $null
  $x.LoadXml($text)
  return $x
}

function Resolve-PartPath([string]$target) {
  # relationship targets are relative to the main part's folder (normally word/) unless they start with /
  if ($target.StartsWith('/')) { $p = $target.TrimStart('/') } else { $p = $script:MainDir + $target }
  $parts = New-Object System.Collections.Generic.List[string]
  foreach ($seg in $p.Split('/')) {
    if ($seg -eq '..') { if ($parts.Count) { $parts.RemoveAt($parts.Count - 1) } }
    elseif ($seg -and $seg -ne '.') { $parts.Add($seg) }
  }
  return ($parts -join '/')
}

$JpegCodec = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.MimeType -eq 'image/jpeg' }
function Save-Bitmap($bmp, [string]$path, [bool]$jpeg) {
  $full = Assert-InsideDataFolder $path
  if ($jpeg) {
    $ep = New-Object System.Drawing.Imaging.EncoderParameters(1)
    $ep.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter([System.Drawing.Imaging.Encoder]::Quality, [long]88)
    $bmp.Save($full, $JpegCodec, $ep)
  } else {
    $bmp.Save($full, [System.Drawing.Imaging.ImageFormat]::Png)
  }
}

# Copies one embedded picture out of the .docx into data\media\<doc>\, applying Word's crop and
# converting formats browsers can't show (EMF/WMF/TIFF). Returns the web path or $null.
function Export-Media([string]$partPath, $crop, [int]$dispW, [int]$dispH) {
  $key = "$partPath|$($crop.l)|$($crop.t)|$($crop.r)|$($crop.b)"
  if ($script:MediaMap.ContainsKey($key)) { return $script:MediaMap[$key] }
  $entry = $script:Zip.GetEntry($partPath)
  if (-not $entry) { $script:Warn.Add("picture missing inside document: $partPath"); return $null }
  $ext = [System.IO.Path]::GetExtension($partPath).ToLowerInvariant()
  $ms = New-Object System.IO.MemoryStream
  $es = $entry.Open(); $es.CopyTo($ms); $es.Dispose()
  $bytes = $ms.ToArray()

  if (-not [System.IO.Directory]::Exists($script:DocMediaDir)) {
    [void][System.IO.Directory]::CreateDirectory((Assert-InsideDataFolder $script:DocMediaDir))
  }
  $script:MediaN++
  $n = $script:MediaN
  $webOk = @('.png', '.jpg', '.jpeg', '.gif', '.bmp', '.webp', '.svg')
  $hasCrop = ($crop.l -gt 0 -or $crop.t -gt 0 -or $crop.r -gt 0 -or $crop.b -gt 0)
  $isMeta = @('.emf', '.wmf') -contains $ext
  $needsWork = $hasCrop -or $isMeta -or ($webOk -notcontains $ext) -or ($bytes.Length -gt 3MB)
  $result = $null

  if (-not $needsWork) {
    $out = Join-Path $script:DocMediaDir "$n$ext"
    [System.IO.File]::WriteAllBytes((Assert-InsideDataFolder $out), $bytes)
    $result = "data/media/$($script:DocId)/$n$ext" + "?v=$($script:Ver)"
  } else {
    $img = $null; $bmp = $null
    try {
      $ms.Position = 0
      $img = [System.Drawing.Image]::FromStream($ms)
      if ($isMeta) {
        # draw the vector picture onto a white canvas at twice its displayed size
        $tw = [Math]::Max(1, [Math]::Min(2000, $dispW * 2)); $th = [Math]::Max(1, [Math]::Min(2000, $dispH * 2))
        if ($dispW -le 0 -or $dispH -le 0) { $tw = [Math]::Min(1600, $img.Width); $th = [Math]::Min(1600, $img.Height) }
        $bmp = New-Object System.Drawing.Bitmap($tw, $th)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.Clear([System.Drawing.Color]::White)
        $g.SmoothingMode = 'AntiAlias'
        $g.DrawImage($img, 0, 0, $tw, $th)
        $g.Dispose()
      } else {
        # honour the camera's rotation flag so the picture looks the way Word shows it
        if ($img.PropertyIdList -contains 0x0112) {
          $o = [int]$img.GetPropertyItem(0x0112).Value[0]
          switch ($o) { 3 { $img.RotateFlip('Rotate180FlipNone') } 6 { $img.RotateFlip('Rotate90FlipNone') } 8 { $img.RotateFlip('Rotate270FlipNone') } }
        }
        $bmp = New-Object System.Drawing.Bitmap($img)
      }
      if ($hasCrop) {
        $l = [Math]::Max(0, $crop.l) / 100000.0; $t = [Math]::Max(0, $crop.t) / 100000.0
        $r = [Math]::Max(0, $crop.r) / 100000.0; $b = [Math]::Max(0, $crop.b) / 100000.0
        $x = [int]([Math]::Floor($bmp.Width * $l)); $y = [int]([Math]::Floor($bmp.Height * $t))
        $cw = [int]([Math]::Round($bmp.Width * (1 - $l - $r))); $ch = [int]([Math]::Round($bmp.Height * (1 - $t - $b)))
        if ($x + $cw -gt $bmp.Width) { $cw = $bmp.Width - $x }
        if ($y + $ch -gt $bmp.Height) { $ch = $bmp.Height - $y }
        if ($cw -ge 2 -and $ch -ge 2) {
          $rect = New-Object System.Drawing.Rectangle($x, $y, $cw, $ch)
          $c2 = $bmp.Clone($rect, $bmp.PixelFormat)
          $bmp.Dispose(); $bmp = $c2
        }
      }
      $maxSide = 2000
      if ($bmp.Width -gt $maxSide -or $bmp.Height -gt $maxSide) {
        $scale = $maxSide / [double]([Math]::Max($bmp.Width, $bmp.Height))
        $nw = [int]($bmp.Width * $scale); $nh = [int]($bmp.Height * $scale)
        $small = New-Object System.Drawing.Bitmap($nw, $nh)
        $g = [System.Drawing.Graphics]::FromImage($small)
        $g.InterpolationMode = 'HighQualityBicubic'
        $g.DrawImage($bmp, 0, 0, $nw, $nh)
        $g.Dispose(); $bmp.Dispose(); $bmp = $small
      }
      $jpeg = @('.jpg', '.jpeg') -contains $ext
      if ($jpeg) { $outExt = '.jpg' } else { $outExt = '.png' }
      Save-Bitmap $bmp (Join-Path $script:DocMediaDir "$n$outExt") $jpeg
      $result = "data/media/$($script:DocId)/$n$outExt" + "?v=$($script:Ver)"
    } catch {
      if ($webOk -contains $ext) {
        $out = Join-Path $script:DocMediaDir "$n$ext"
        [System.IO.File]::WriteAllBytes((Assert-InsideDataFolder $out), $bytes)
        $result = "data/media/$($script:DocId)/$n$ext" + "?v=$($script:Ver)"
      } else {
        $script:Warn.Add("could not convert picture $partPath ($ext): $($_.Exception.Message)")
      }
    } finally {
      if ($bmp) { $bmp.Dispose() }
      if ($img) { $img.Dispose() }
    }
  }
  $script:MediaMap[$key] = $result
  return $result
}

function Get-IntAttr($node, [string]$name, [string]$nsUri) {
  if (-not $node) { return 0 }
  $v = $node.GetAttribute($name, $nsUri)
  if (-not $v) { $v = $node.GetAttribute($name) }
  [long]$n = 0
  if ([long]::TryParse($v, [ref]$n)) { return $n }
  return 0
}

function Add-Text($runs, [string]$text, [int]$flags, [string]$href, [int]$size) {
  if (-not $text) { return }
  if ($runs.Count -gt 0) {
    $last = $runs[$runs.Count - 1]
    if ($last.ContainsKey('t') -and $last.f -eq $flags -and $last.h -eq $href -and $last.z -eq $size) {
      $last.t = $last.t + $text
      return
    }
  }
  $runs.Add(@{ t = $text; f = $flags; h = $href; z = $size })
}

function Add-Drawing($node, $runs, $extra) {
  # one drawing can hold one picture, a group of pictures, or a text box
  $extent = $node.SelectSingleNode('.//wp:extent', $NS)
  $docPr = $node.SelectSingleNode('.//wp:docPr', $NS)
  $alt = ''
  if ($docPr) { $alt = $docPr.GetAttribute('descr'); if (-not $alt) { $alt = $docPr.GetAttribute('title') } }
  $blips = $node.SelectNodes('.//a:blip', $NS)
  foreach ($blip in $blips) {
    $rid = $blip.GetAttribute('embed', $NsR)
    if (-not $rid -or -not $script:Rels.ContainsKey($rid)) { continue }
    $part = Resolve-PartPath $script:Rels[$rid].Target
    $fill = $blip.ParentNode
    $src = $null
    if ($fill) { $src = $fill.SelectSingleNode('a:srcRect', $NS) }
    $crop = @{ l = (Get-IntAttr $src 'l' ''); t = (Get-IntAttr $src 't' ''); r = (Get-IntAttr $src 'r' ''); b = (Get-IntAttr $src 'b' '') }
    $cx = 0; $cy = 0
    if ($blips.Count -gt 1) {
      $picExt = $fill.ParentNode.SelectSingleNode('pic:spPr/a:xfrm/a:ext', $NS)
      if ($picExt) { $cx = Get-IntAttr $picExt 'cx' ''; $cy = Get-IntAttr $picExt 'cy' '' }
    }
    if ($cx -le 0 -and $extent) { $cx = Get-IntAttr $extent 'cx' ''; $cy = Get-IntAttr $extent 'cy' '' }
    $wpx = [int]($cx / 9525); $hpx = [int]($cy / 9525)
    $web = Export-Media $part $crop $wpx $hpx
    if ($web) { $runs.Add(@{ img = $web; w = $wpx; h = $hpx; alt = $alt }) }
  }
  foreach ($tx in $node.SelectNodes('.//w:txbxContent', $NS)) {
    foreach ($b in (Get-Blocks $tx)) { $extra.Add($b) }
  }
}

function Add-Vml($node, $runs, $extra) {
  foreach ($im in $node.SelectNodes('.//v:imagedata', $NS)) {
    $rid = $im.GetAttribute('id', $NsR)
    if (-not $rid -or -not $script:Rels.ContainsKey($rid)) { continue }
    $part = Resolve-PartPath $script:Rels[$rid].Target
    $wpx = 0; $hpx = 0
    $shape = $im.ParentNode
    if ($shape -and $shape.GetAttribute('style') -match 'width:\s*([\d.]+)pt.*?height:\s*([\d.]+)pt') {
      $wpx = [int]([double]$Matches[1] * 96 / 72); $hpx = [int]([double]$Matches[2] * 96 / 72)
    }
    $web = Export-Media $part @{ l = 0; t = 0; r = 0; b = 0 } $wpx $hpx
    if ($web) { $runs.Add(@{ img = $web; w = $wpx; h = $hpx; alt = $im.GetAttribute('title') }) }
  }
  foreach ($tx in $node.SelectNodes('.//w:txbxContent', $NS)) {
    foreach ($b in (Get-Blocks $tx)) { $extra.Add($b) }
  }
}

function Test-On($el) {
  # <w:b/> is on; <w:b w:val="0|false|off"/> is off
  if (-not $el) { return $false }
  $v = $el.GetAttribute('val', $NsW)
  return -not ($v -eq '0' -or $v -eq 'false' -or $v -eq 'off' -or $v -eq 'none')
}

function Add-Run($r, $runs, $state, $extra) {
  $flags = 0; $size = 0
  $rPr = $null
  foreach ($c in $r.ChildNodes) { if ($c.LocalName -eq 'rPr') { $rPr = $c; break } }
  if ($rPr) {
    foreach ($p in $rPr.ChildNodes) {
      if ($p.NodeType -ne $ElementNode) { continue }
      switch ($p.LocalName) {
        'b'         { if (Test-On $p) { $flags = $flags -bor 1 } }
        'i'         { if (Test-On $p) { $flags = $flags -bor 2 } }
        'u'         { if (Test-On $p) { $flags = $flags -bor 4 } }
        'strike'    { if (Test-On $p) { $flags = $flags -bor 32 } }
        'dstrike'   { if (Test-On $p) { $flags = $flags -bor 32 } }
        'vertAlign' { $va = $p.GetAttribute('val', $NsW); if ($va -eq 'superscript') { $flags = $flags -bor 8 } elseif ($va -eq 'subscript') { $flags = $flags -bor 16 } }
        'sz'        { $size = [int](Get-IntAttr $p 'val' $NsW) }
        'vanish'    { if (Test-On $p) { return } }   # hidden text is not shown in Word either
      }
    }
  }
  foreach ($c in $r.ChildNodes) {
    if ($c.NodeType -ne $ElementNode) { continue }
    $inInstr = $false
    foreach ($fld in $state.fields) { if ($fld.phase -eq 'instr') { $inInstr = $true } }
    $href = $state.href
    foreach ($fld in $state.fields) { if ($fld.phase -eq 'result' -and $fld.href) { $href = $fld.href; break } }
    switch ($c.LocalName) {
      't'             { if (-not $inInstr) { Add-Text $runs $c.InnerText $flags $href $size } }
      'tab'           { if (-not $inInstr) { Add-Text $runs "`t" $flags $href $size } }
      'br'            { $bt = $c.GetAttribute('type', $NsW); if (-not $inInstr -and $bt -ne 'page' -and $bt -ne 'column') { Add-Text $runs "`n" $flags $href $size } }
      'cr'            { if (-not $inInstr) { Add-Text $runs "`n" $flags $href $size } }
      'noBreakHyphen' { if (-not $inInstr) { Add-Text $runs '-' $flags $href $size } }
      'sym'           {
        $code = $c.GetAttribute('char', $NsW)
        $cv = 0
        if ($code -and [int]::TryParse($code, [System.Globalization.NumberStyles]::HexNumber, $null, [ref]$cv)) {
          if ($cv -ge 0xF000) { $cv -= 0xF000 }
          if ($cv -ge 32) { Add-Text $runs ([string][char]$cv) $flags $href $size }
        }
      }
      'drawing'       { Add-Drawing $c $runs $extra }
      'pict'          { Add-Vml $c $runs $extra }
      'object'        { Add-Vml $c $runs $extra }
      'AlternateContent' {
        $choice = $c.SelectSingleNode('mc:Choice', $NS)
        if (-not $choice) { $choice = $c.SelectSingleNode('mc:Fallback', $NS) }
        if ($choice) {
          foreach ($cc in $choice.ChildNodes) {
            if ($cc.LocalName -eq 'drawing') { Add-Drawing $cc $runs $extra }
            elseif ($cc.LocalName -eq 'pict') { Add-Vml $cc $runs $extra }
          }
        }
      }
      'fldChar' {
        $ft = $c.GetAttribute('fldCharType', $NsW)
        if ($ft -eq 'begin') { $state.fields.Insert(0, @{ phase = 'instr'; instr = ''; href = $null }) }
        elseif ($ft -eq 'separate' -and $state.fields.Count) {
          $top = $state.fields[0]; $top.phase = 'result'
          if ($top.instr -match '^\s*HYPERLINK\s+"([^"]+)"') { $top.href = $Matches[1] }
          elseif ($top.instr -match '^\s*HYPERLINK\s+(\S+)') { $top.href = $Matches[1] }
        }
        elseif ($ft -eq 'end' -and $state.fields.Count) { $state.fields.RemoveAt(0) }
      }
      'instrText' { if ($state.fields.Count) { $state.fields[0].instr += $c.InnerText } }
    }
  }
}

function Walk-Inline($node, $runs, $state, $extra) {
  foreach ($c in $node.ChildNodes) {
    if ($c.NodeType -ne $ElementNode) { continue }
    switch ($c.LocalName) {
      'r' { Add-Run $c $runs $state $extra }
      'hyperlink' {
        $old = $state.href
        $rid = $c.GetAttribute('id', $NsR)
        if ($rid -and $script:Rels.ContainsKey($rid)) { $state.href = $script:Rels[$rid].Target }
        Walk-Inline $c $runs $state $extra
        $state.href = $old
      }
      'fldSimple' {
        $old = $state.href
        $instr = $c.GetAttribute('instr', $NsW)
        if ($instr -match 'HYPERLINK\s+"([^"]+)"') { $state.href = $Matches[1] }
        Walk-Inline $c $runs $state $extra
        $state.href = $old
      }
      'sdt' { $sc = $c.SelectSingleNode('w:sdtContent', $NS); if ($sc) { Walk-Inline $sc $runs $state $extra } }
      'AlternateContent' {
        $choice = $c.SelectSingleNode('mc:Choice', $NS)
        if (-not $choice) { $choice = $c.SelectSingleNode('mc:Fallback', $NS) }
        if ($choice) { Walk-Inline $choice $runs $state $extra }
      }
      default { if ($PassThrough.ContainsKey($_)) { Walk-Inline $c $runs $state $extra } }   # deleted text, bookmarks, proofing marks, comments: not shown
    }
  }
}

function Get-ParagraphJson($p) {
  $runs = New-Object System.Collections.Generic.List[hashtable]
  $extra = New-Object System.Collections.Generic.List[string]
  $state = @{ href = $null; fields = (New-Object System.Collections.ArrayList) }
  Walk-Inline $p $runs $state $extra

  $sb = New-Object System.Text.StringBuilder
  [void]$sb.Append('{"r":[')
  $first = $true
  foreach ($run in $runs) {
    if (-not $first) { [void]$sb.Append(',') }
    $first = $false
    if ($run.ContainsKey('img')) {
      [void]$sb.Append('{"img":').Append((JStr $run.img)).Append(',"w":').Append($run.w).Append(',"h":').Append($run.h)
      if ($run.alt) { [void]$sb.Append(',"alt":').Append((JStr $run.alt)) }
      [void]$sb.Append('}')
    } else {
      [void]$sb.Append('{"t":').Append((JStr $run.t))
      if ($run.f) { [void]$sb.Append(',"f":').Append($run.f) }
      if ($run.h) { [void]$sb.Append(',"h":').Append((JStr $run.h)) }
      if ($run.z) { [void]$sb.Append(',"z":').Append($run.z) }
      [void]$sb.Append('}')
    }
  }
  [void]$sb.Append(']')

  $pPr = $p.SelectSingleNode('w:pPr', $NS)
  if ($pPr) {
    $jc = $pPr.SelectSingleNode('w:jc', $NS)
    if ($jc) {
      $v = $jc.GetAttribute('val', $NsW)
      if ($v -eq 'center') { [void]$sb.Append(',"a":"c"') } elseif ($v -eq 'right' -or $v -eq 'end') { [void]$sb.Append(',"a":"r"') }
    }
    $ind = $pPr.SelectSingleNode('w:ind', $NS)
    if ($ind) {
      $left = Get-IntAttr $ind 'left' $NsW
      if (-not $left) { $left = Get-IntAttr $ind 'start' $NsW }
      $fl = Get-IntAttr $ind 'firstLine' $NsW
      $hang = Get-IntAttr $ind 'hanging' $NsW
      if ($hang) { $fl = -$hang }
      if ($left -or $fl) { [void]$sb.Append(',"ind":[').Append([int]($left / 15)).Append(',').Append([int]($fl / 15)).Append(']') }
    }
    $num = $pPr.SelectSingleNode('w:numPr', $NS)
    if ($num) {
      $nid = Get-IntAttr ($num.SelectSingleNode('w:numId', $NS)) 'val' $NsW
      $lvl = Get-IntAttr ($num.SelectSingleNode('w:ilvl', $NS)) 'val' $NsW
      if ($nid -gt 0) {
        $fmt = 'bullet'; $txt = ''; $start = 1
        if ($script:Numbering.ContainsKey("$nid|$lvl")) { $d = $script:Numbering["$nid|$lvl"]; $fmt = $d.fmt; $txt = $d.text; $start = $d.start }
        [void]$sb.Append(',"li":{"n":').Append($nid).Append(',"l":').Append($lvl).Append(',"f":').Append((JStr $fmt)).Append(',"x":').Append((JStr $txt)).Append(',"s":').Append($start).Append('}')
      }
    }
    $st = $pPr.SelectSingleNode('w:pStyle', $NS)
    if ($st) { [void]$sb.Append(',"s":').Append((JStr ($st.GetAttribute('val', $NsW)))) }
  }
  [void]$sb.Append('}')
  $out = New-Object System.Collections.Generic.List[string]
  $out.Add($sb.ToString())
  foreach ($e in $extra) { $out.Add($e) }
  return , $out
}

function Get-TableJson($tbl) {
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.Append('{"tbl":[')
  $firstRow = $true
  foreach ($tr in $tbl.ChildNodes) {
    if ($tr.LocalName -ne 'tr') { continue }
    if (-not $firstRow) { [void]$sb.Append(',') }
    $firstRow = $false
    [void]$sb.Append('[')
    $firstCell = $true
    foreach ($tc in $tr.ChildNodes) {
      if ($tc.LocalName -ne 'tc') { continue }
      if (-not $firstCell) { [void]$sb.Append(',') }
      $firstCell = $false
      $span = 1; $vm = ''
      $tcPr = $tc.SelectSingleNode('w:tcPr', $NS)
      if ($tcPr) {
        $gs = $tcPr.SelectSingleNode('w:gridSpan', $NS); if ($gs) { $span = [Math]::Max(1, (Get-IntAttr $gs 'val' $NsW)) }
        $vmn = $tcPr.SelectSingleNode('w:vMerge', $NS); if ($vmn) { $vm = $vmn.GetAttribute('val', $NsW); if (-not $vm) { $vm = 'continue' } }
      }
      [void]$sb.Append('{"b":[').Append(((Get-Blocks $tc) -join ',')).Append(']')
      if ($span -gt 1) { [void]$sb.Append(',"cs":').Append($span) }
      if ($vm) { [void]$sb.Append(',"vm":').Append((JStr $vm)) }
      [void]$sb.Append('}')
    }
    [void]$sb.Append(']')
  }
  [void]$sb.Append(']}')
  return $sb.ToString()
}

function Get-Blocks($container) {
  $list = New-Object System.Collections.Generic.List[string]
  foreach ($c in $container.ChildNodes) {
    if ($c.NodeType -ne $ElementNode) { continue }
    switch ($c.LocalName) {
      'p'   { foreach ($b in (Get-ParagraphJson $c)) { $list.Add($b) } }
      'tbl' { $list.Add((Get-TableJson $c)) }
      'sdt' { $sc = $c.SelectSingleNode('w:sdtContent', $NS); if ($sc) { foreach ($b in (Get-Blocks $sc)) { $list.Add($b) } } }
      'customXml' { foreach ($b in (Get-Blocks $c)) { $list.Add($b) } }
      'AlternateContent' {
        $choice = $c.SelectSingleNode('mc:Choice', $NS)
        if (-not $choice) { $choice = $c.SelectSingleNode('mc:Fallback', $NS) }
        if ($choice) { foreach ($b in (Get-Blocks $choice)) { $list.Add($b) } }
      }
    }
  }
  return , $list
}

function Convert-Docx([string]$fullPath, [string]$relPath, [string]$id, $fileInfo) {
  $script:DocId = $id
  # pictures are written to data\media\<id>.new and only swapped in once the whole document was read
  $finalMediaDir = Join-Path $MediaDir $id
  $script:DocMediaDir = Join-Path $MediaDir "$id.new"
  $script:MediaMap = @{}
  $script:MediaN = 0
  $script:Warn = New-Object System.Collections.Generic.List[string]
  $script:Rels = @{}
  $script:RelTypes = @{}
  $script:Numbering = @{}
  $script:Ver =$fileInfo.LastWriteTimeUtc.Ticks     # added to picture addresses so a changed picture is never shown from the browser's memory
  Remove-MediaFolder $script:DocMediaDir

  $fs = [System.IO.File]::Open($fullPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
  try {
    $script:Zip = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Read)
    # the main text part is named in _rels/.rels (almost always word/document.xml)
    $mainPart = 'word/document.xml'
    $pkg = Read-ZipXml $script:Zip '_rels/.rels'
    if ($pkg) {
      foreach ($rel in $pkg.DocumentElement.ChildNodes) {
        if ($rel.NodeType -eq $ElementNode -and $rel.GetAttribute('Type') -match '/officeDocument$') { $mainPart = $rel.GetAttribute('Target').TrimStart('/'); break }
      }
    }
    $script:MainDir = ''
    if ($mainPart.Contains('/')) { $script:MainDir = $mainPart.Substring(0, $mainPart.LastIndexOf('/') + 1) }
    $doc = Read-ZipXml $script:Zip $mainPart
    if (-not $doc -and $mainPart -ne 'word/document.xml') { $mainPart = 'word/document.xml'; $script:MainDir = 'word/'; $doc = Read-ZipXml $script:Zip $mainPart }
    if (-not $doc) { throw 'not a Word document (no main text part inside)' }

    $rels = Read-ZipXml $script:Zip ($script:MainDir + '_rels/' + $mainPart.Substring($script:MainDir.Length) + '.rels')
    if ($rels) {
      foreach ($rel in $rels.DocumentElement.ChildNodes) {
        if ($rel.NodeType -ne $ElementNode) { continue }
        $script:Rels[$rel.GetAttribute('Id')] = @{ Target = $rel.GetAttribute('Target'); External = ($rel.GetAttribute('TargetMode') -eq 'External') }
        $script:RelTypes[$rel.GetAttribute('Id')] = $rel.GetAttribute('Type')
      }
    }
    $numx = $null
    foreach ($k in $script:RelTypes.Keys) { if ($script:RelTypes[$k] -match '/numbering$') { $numx = Read-ZipXml $script:Zip (Resolve-PartPath $script:Rels[$k].Target) } }
    if (-not $numx) { $numx = Read-ZipXml $script:Zip ($script:MainDir + 'numbering.xml') }
    if ($numx) {
      $abs = @{}
      foreach ($an in $numx.SelectNodes('//w:abstractNum', $NS)) {
        $aid = $an.GetAttribute('abstractNumId', $NsW)
        foreach ($lv in $an.SelectNodes('w:lvl', $NS)) {
          $il = $lv.GetAttribute('ilvl', $NsW)
          $fmtN = $lv.SelectSingleNode('w:numFmt', $NS); $txtN = $lv.SelectSingleNode('w:lvlText', $NS); $stN = $lv.SelectSingleNode('w:start', $NS)
          $fmt = 'bullet'; if ($fmtN) { $fmt = $fmtN.GetAttribute('val', $NsW) }
          $txt = ''; if ($txtN) { $txt = $txtN.GetAttribute('val', $NsW) }
          $start = 1; if ($stN) { $start = [int](Get-IntAttr $stN 'val' $NsW) }
          $abs["$aid|$il"] = @{ fmt = $fmt; text = $txt; start = $start }
        }
      }
      foreach ($nm in $numx.SelectNodes('//w:num', $NS)) {
        $nid = $nm.GetAttribute('numId', $NsW)
        $aidN = $nm.SelectSingleNode('w:abstractNumId', $NS)
        if (-not $aidN) { continue }
        $aid = $aidN.GetAttribute('val', $NsW)
        for ($i = 0; $i -le 8; $i++) { if ($abs.ContainsKey("$aid|$i")) { $script:Numbering["$nid|$i"] = $abs["$aid|$i"] } }
      }
    }

    $body = $doc.SelectSingleNode('/w:document/w:body', $NS)
    if (-not $body) { throw 'no text could be found in this document (it may be saved in an unusual format; saving it again as a normal Word document should fix it)' }
    $blocks = Get-Blocks $body
  } catch {
    Remove-MediaFolder $script:DocMediaDir
    throw
  } finally {
    if ($script:Zip) { $script:Zip.Dispose(); $script:Zip = $null }
    $fs.Dispose()
  }
  # swap in the new pictures; if anything goes wrong the old ones are put back
  $oldMediaDir = Join-Path $MediaDir "$id.old"
  Remove-MediaFolder $oldMediaDir
  if ([System.IO.Directory]::Exists($finalMediaDir)) { Move-MediaFolder $finalMediaDir $oldMediaDir }
  if ([System.IO.Directory]::Exists($script:DocMediaDir)) {
    try { Move-MediaFolder $script:DocMediaDir $finalMediaDir }
    catch {
      if ([System.IO.Directory]::Exists($oldMediaDir) -and -not [System.IO.Directory]::Exists($finalMediaDir)) { Move-MediaFolder $oldMediaDir $finalMediaDir }
      throw "the picture copies in the Family Tree Viewer data folder could not be updated ($($_.Exception.Message))"
    }
  }
  Remove-MediaFolder $oldMediaDir

  $dir = ''
  $slash = $relPath.LastIndexOf('\')
  if ($slash -gt 0) { $dir = $relPath.Substring(0, $slash) }
  $mtime = $fileInfo.LastWriteTimeUtc.ToString('yyyy-MM-ddTHH:mm:ssZ')
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.Append('{"id":').Append((JStr $id)).Append(',"path":').Append((JStr $relPath)).Append(',"dir":').Append((JStr $dir))
  [void]$sb.Append(',"name":').Append((JStr ([System.IO.Path]::GetFileNameWithoutExtension($relPath))))
  [void]$sb.Append(',"mtime":').Append((JStr $mtime)).Append(',"size":').Append($fileInfo.Length).Append(',"nimg":').Append($script:MediaN)
  if ($script:Warn.Count) { [void]$sb.Append(',"warn":[').Append((($script:Warn | ForEach-Object { JStr $_ }) -join ',')).Append(']') }
  [void]$sb.Append(',"b":[').Append(($blocks -join ",`n")).Append(']}')
  return $sb.ToString()
}

function Get-DocId([string]$relPath) {
  $sha = [System.Security.Cryptography.SHA1]::Create()
  $h = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($relPath.ToLowerInvariant()))
  $sha.Dispose()
  return 'd' + (($h[0..5] | ForEach-Object { $_.ToString('x2') }) -join '')
}

# =====================================================================================
# main
# =====================================================================================
$mutex = New-Object System.Threading.Mutex($false, 'Local\FamilyTreeViewerUpdate')
$haveLock = $false
try {
  # open the page first: it shows what is there now and refreshes itself when this update is done
  if ($Open) {
    try {
      $index = Join-Path $Viewer 'index.html'
      if ([System.IO.File]::Exists($index)) { Start-Process -FilePath $index }
    } catch { Write-Log "could not open the web browser: $($_.Exception.Message)" }
  }
  # one update at a time. Opened from the icon while another update is busy: that one refreshes the page.
  $wait = [TimeSpan]::FromMinutes(5)
  if ($Open) { $wait = [TimeSpan]::FromSeconds(2) }
  try { $haveLock = $mutex.WaitOne($wait) } catch [System.Threading.AbandonedMutexException] { $haveLock = $true }
  if (-not $haveLock) { Say 'Another update is still running; it will refresh the family tree when it is done.'; exit 0 }

  foreach ($d in @($DataDir, $CacheDir, $MediaDir)) {
    if (-not [System.IO.Directory]::Exists($d)) { [void][System.IO.Directory]::CreateDirectory($d) }
    if ([System.IO.File]::GetAttributes($d) -band [System.IO.FileAttributes]::ReparsePoint) { throw "SAFETY STOP: $d is a link to somewhere else; nothing was changed" }
  }
  $Source = Resolve-Source $Source

  $started = Get-Date
  Say "Family Tree: checking documents in $Source"
  $viewerFull = [System.IO.Path]::GetFullPath($Viewer).TrimEnd('\') + '\'
  $all = Get-SourceFiles $Source $viewerFull
  $hidden = [System.IO.FileAttributes]::Hidden
  $docs = @($all | Where-Object { $_.Extension -eq '.docx' -and -not $_.Name.StartsWith('~$') -and -not ($_.Attributes -band $hidden) } | Sort-Object FullName)
  $others = @($all | Where-Object {
    $_.Extension -ne '.docx' -and -not $_.Name.StartsWith('~') -and $_.Extension -ne '.tmp' -and
    -not ($_.Attributes -band $hidden) -and $_.Name -ne 'desktop.ini' -and $_.Name -ne 'Thumbs.db' -and
    $_.DirectoryName -notmatch '_files(\\|$)'
  } | Sort-Object FullName)

  $total = $docs.Count
  Write-Status 'running' 0 $total ''
  $docJson = New-Object System.Collections.Generic.List[string]
  $errors = New-Object System.Collections.Generic.List[string]
  $signature = New-Object System.Text.StringBuilder
  $keep = @{}
  $changed = 0; $added = 0; $failed = 0; $i = 0
  foreach ($f in $docs) {
    $i++
    $rel = (Get-PlainPath $f.FullName).Substring($Source.Length + 1)
    $id = Get-DocId $rel
    $keep[$id] = $true
    $cacheJson = Join-Path $CacheDir "$id.json"
    $cacheKey = Join-Path $CacheDir "$id.key"
    $key = "$BuilderVersion|$($f.Length)|$($f.LastWriteTimeUtc.Ticks)|$rel"
    [void]$signature.Append($key).Append("`n")
    $fresh = $false
    if (-not $Full -and [System.IO.File]::Exists($cacheKey) -and [System.IO.File]::Exists($cacheJson)) {
      $fresh = ([System.IO.File]::ReadAllText($cacheKey) -ceq $key)     # -ceq: a change of capital letters in a name counts too
    }
    if (-not $fresh) {
      $isNew = -not [System.IO.File]::Exists($cacheJson)
      Say ("  reading {0} of {1}: {2}" -f $i, $total, $rel)
      try {
        if ($f.Length -eq 0) { throw (New-Object System.IO.InvalidDataException('EMPTY')) }
        $json = Convert-Docx $f.FullName $rel $id $f
        Write-DataFile $cacheJson $json
        Write-DataFile $cacheKey $key
        $changed++
        if ($isNew) { $added++ }
      } catch {
        $failed++
        $ex = $_.Exception
        while ($ex.InnerException) { $ex = $ex.InnerException }
        $msg = $ex.Message.Trim()
        if ($msg -eq 'EMPTY') {
          $msg = 'this document is empty (nothing has been written in it yet)'
        } elseif ($ex -is [System.IO.InvalidDataException] -or $msg -match 'Central Directory|not a valid|corrupt|file pointer') {
          $msg = 'the file seems to be damaged or is not a Word .docx file (if Word was saving it just then, it will be read next time)'
        } elseif ($msg -match 'being used by another process') {
          $msg = 'the file was in use by another program; it will be read next time'
        } elseif ($ex -is [System.IO.PathTooLongException]) {
          $msg = 'the folder and file names together are too long for Windows; a shorter name will fix it'
        }
        $hasCache = [System.IO.File]::Exists($cacheJson)
        $errors.Add('{"path":' + (JStr $rel) + ',"msg":' + (JStr $msg) + ',"cached":' + $hasCache.ToString().ToLower() + '}')
        [void]$signature.Append("ERR|$msg`n")
        Write-Log "could not read $rel : $msg"
        if (-not $hasCache) {
          # placeholder so the document still appears (with a note) until it can be read
          $mt = $f.LastWriteTimeUtc.ToString('yyyy-MM-ddTHH:mm:ssZ')
          $dir = ''; $slash = $rel.LastIndexOf('\'); if ($slash -gt 0) { $dir = $rel.Substring(0, $slash) }
          $ph = '{"id":' + (JStr $id) + ',"path":' + (JStr $rel) + ',"dir":' + (JStr $dir) + ',"name":' + (JStr ([System.IO.Path]::GetFileNameWithoutExtension($rel))) + ',"mtime":' + (JStr $mt) + ',"size":' + $f.Length + ',"nimg":0,"err":' + (JStr $msg) + ',"b":[]}'
          $docJson.Add($ph)
          continue
        }
      }
      if (($i % 5) -eq 0) { Write-Status 'running' $i $total '' }
    }
    $docJson.Add([System.IO.File]::ReadAllText($cacheJson, [System.Text.Encoding]::UTF8))
  }

  # documents inside a folder that could not be opened this time are kept as they were
  $problemRel = @($script:FolderProblems | ForEach-Object { if ($_.Length -gt $Source.Length) { $_.Substring($Source.Length + 1) + '\' } else { '' } })
  if ($problemRel.Count) {
    foreach ($kf in [System.IO.Directory]::GetFiles($CacheDir, '*.key')) {
      $kid = [System.IO.Path]::GetFileNameWithoutExtension($kf)
      if ($keep.ContainsKey($kid) -or [System.IO.Path]::GetFileName($kf) -notmatch $GenCacheName) { continue }
      $krel = ([System.IO.File]::ReadAllText($kf) -split '\|', 4)[3]
      $inProblem = $false
      foreach ($pr in $problemRel) { if ($pr -eq '' -or ($krel -and $krel.StartsWith($pr, [System.StringComparison]::OrdinalIgnoreCase))) { $inProblem = $true } }
      $kjson = Join-Path $CacheDir "$kid.json"
      if ($inProblem -and [System.IO.File]::Exists($kjson)) { $keep[$kid] = $true; $docJson.Add([System.IO.File]::ReadAllText($kjson, [System.Text.Encoding]::UTF8)); [void]$signature.Append("KEPT|$krel`n") }
    }
    foreach ($pr in $script:FolderProblems) {
      $errors.Add('{"path":' + (JStr ((Get-PlainPath $pr).Substring([Math]::Min($Source.Length + 1, (Get-PlainPath $pr).Length)))) + ',"msg":' + (JStr 'this folder could not be opened; its documents are shown as they were at the last update') + ',"cached":true}')
    }
  }

  # forget documents that were renamed or removed (only this program's own cache files are ever touched)
  $removed = 0
  foreach ($cf in [System.IO.Directory]::GetFiles($CacheDir)) {
    $cname = [System.IO.Path]::GetFileName($cf)
    if ($cname -notmatch $GenCacheName) { continue }
    $cid = $cname.Substring(0, 13)
    if (-not $keep.ContainsKey($cid) -or $cname.EndsWith('.tmp')) {
      Remove-GeneratedFile $cf
      if ($cname.EndsWith('.json') -and -not $keep.ContainsKey($cid)) { $removed++ }
    }
  }
  foreach ($md in [System.IO.Directory]::GetDirectories($MediaDir)) {
    $mname = [System.IO.Path]::GetFileName($md)
    if ($mname -notmatch $GenMediaDir) { continue }
    if (-not $keep.ContainsKey($mname.Substring(0, 13)) -or $mname.Length -gt 13) { Remove-MediaFolder $md }
  }

  $otherJson = New-Object System.Collections.Generic.List[string]
  foreach ($o in $others) {
    $rel = (Get-PlainPath $o.FullName).Substring($Source.Length + 1)
    $otherJson.Add('{"path":' + (JStr $rel) + ',"size":' + $o.Length + ',"mtime":' + (JStr ($o.LastWriteTimeUtc.ToString('yyyy-MM-ddTHH:mm:ssZ'))) + '}')
    [void]$signature.Append("O|$rel|$($o.Length)|$($o.LastWriteTimeUtc.Ticks)`n")
  }

  # nothing changed since last time: keep data.js as it is, so an open page is not reloaded for nothing
  $sha = [System.Security.Cryptography.SHA1]::Create()
  $sig = (($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes("$BuilderVersion|$Source`n" + $signature.ToString())) | ForEach-Object { $_.ToString('x2') }) -join '')
  $sha.Dispose()
  $stateFile = Join-Path $DataDir 'build-state.txt'
  $dataFile = Join-Path $DataDir 'data.js'
  $prev = @('', '')
  if ([System.IO.File]::Exists($stateFile)) { $prev = ([System.IO.File]::ReadAllText($stateFile) + '|') -split '\|' }
  if ($changed -eq 0 -and $removed -eq 0 -and $prev[0] -eq $sig -and $prev[1] -and [System.IO.File]::Exists($dataFile)) {
    $built = $prev[1]
  } else {
    $built = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("/* Generated by Update-FamilyTree.ps1 - do not edit; it is rebuilt from the Word documents. */`n")
    [void]$sb.Append('window.FAMILY_DATA = {"built":').Append((JStr $built)).Append(',"builder":').Append($BuilderVersion)
    [void]$sb.Append(',"source":').Append((JStr $Source))
    [void]$sb.Append(',"changed":').Append($changed).Append(',"added":').Append($added).Append(',"removed":').Append($removed)
    [void]$sb.Append(",`n`"docs`":[`n").Append(($docJson -join ",`n")).Append("`n]")
    [void]$sb.Append(",`n`"other`":[").Append(($otherJson -join ",`n")).Append(']')
    [void]$sb.Append(",`n`"errors`":[").Append(($errors -join ',')).Append("]};`n")
    Write-DataFile $dataFile $sb.ToString()
    Write-DataFile $stateFile "$sig|$built"
  }

  $secs = [int]((Get-Date) - $started).TotalSeconds
  Write-Status 'done' $total $total (",`"built`":" + (JStr $built) + ",`"changed`":$changed,`"added`":$added,`"removed`":$removed,`"failed`":$failed")
  $summary = "Checked $total documents in $secs s: $changed read ($added new), $removed removed, $failed could not be read."
  Write-Log $summary
  Say $summary
}
catch {
  $msg = $_.Exception.Message
  Write-Log "UPDATE FAILED: $msg"
  Write-Status 'error' 0 0 (",`"msg`":" + (JStr $msg))
  if (-not $Quiet) { Write-Host "Update failed: $msg" -ForegroundColor Red }
  Save-Log
  exit 1
}
finally {
  Save-Log
  if ($haveLock) { $mutex.ReleaseMutex() }
  $mutex.Dispose()
}