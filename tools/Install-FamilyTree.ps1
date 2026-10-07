<#
  Install-FamilyTree.ps1
  Creates the "Family Tree" icon on the desktop (and its picture). Safe to run again at any time.
  It does not change any document and does not create any background/scheduled task.
#>
$ErrorActionPreference = 'Stop'
$Tools = $PSScriptRoot
$Viewer = Split-Path -Parent $Tools
$Icon = Join-Path $Tools 'family-tree.ico'

# --- the icon picture: a green tree, stored as a PNG inside an .ico file
if (-not (Test-Path -LiteralPath $Icon)) {
  Add-Type -AssemblyName System.Drawing
  $size = 256
  $bmp = New-Object System.Drawing.Bitmap($size, $size)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = 'AntiAlias'
  $g.Clear([System.Drawing.Color]::Transparent)
  $trunk = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 122, 88, 48))
  $g.FillRectangle($trunk, 112, 150, 32, 88)
  $leaf1 = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 47, 93, 80))
  $leaf2 = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 74, 128, 104))
  $g.FillEllipse($leaf1, 22, 40, 120, 120)
  $g.FillEllipse($leaf1, 114, 40, 120, 120)
  $g.FillEllipse($leaf2, 58, 8, 140, 140)
  $g.FillEllipse($leaf1, 70, 84, 116, 96)
  $g.Dispose()
  $ms = New-Object System.IO.MemoryStream
  $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
  $bmp.Dispose()
  $png = $ms.ToArray()
  $out = New-Object System.IO.MemoryStream
  $w = New-Object System.IO.BinaryWriter($out)
  $w.Write([UInt16]0); $w.Write([UInt16]1); $w.Write([UInt16]1)          # ICONDIR: reserved, type=icon, count=1
  $w.Write([byte]0); $w.Write([byte]0); $w.Write([byte]0); $w.Write([byte]0) # 256x256, no palette
  $w.Write([UInt16]1); $w.Write([UInt16]32)                                  # planes, bits per pixel
  $w.Write([UInt32]$png.Length); $w.Write([UInt32]22)                        # size, offset
  $w.Write($png)
  $w.Flush()
  [System.IO.File]::WriteAllBytes($Icon, $out.ToArray())
}

# --- the desktop shortcut: updates from the documents, then opens the tree in the web browser
$desktop = [Environment]::GetFolderPath('Desktop')
$lnk = Join-Path $desktop 'Family Tree.lnk'
$shell = New-Object -ComObject WScript.Shell
$sc = $shell.CreateShortcut($lnk)
# The icon starts "Open Family Tree.cmd", which finds everything relative to itself, so Windows can
# still follow the shortcut if the folder is ever moved or renamed.
$sc.TargetPath = Join-Path $Viewer 'Open Family Tree.cmd'
$sc.Arguments = ''
$sc.WorkingDirectory = $Viewer
$sc.IconLocation = "$Icon,0"
$sc.WindowStyle = 7
$sc.Description = 'Open the family tree (reads new and changed life histories first)'
$sc.Save()
"Desktop icon created: $lnk"
