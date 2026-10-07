<#
  Serve-Viewer.ps1
  ----------------
  A tiny READ-ONLY web server for looking at a copy of the viewer in a browser that cannot open file://
  pages with their scripts (for example a browser pane inside an editor). Only for testing; the family
  itself always opens index.html straight from the folder.

  Usage (Windows PowerShell 5.1; stop it with Ctrl+C):
    powershell -NoProfile -ExecutionPolicy Bypass -File tests\Serve-Viewer.ps1 [-Root <viewer folder>] [-Port 8765]
    then open http://localhost:8765/

  -Root  the folder that holds index.html (default: the program folder above this script; give a test
         copy with a data\ folder, e.g. the one tests\Run-Tests.ps1 makes, to see a whole tree)
  It answers only on this computer (127.0.0.1), only GET requests, only files inside -Root, and never
  writes anything.
#>
param(
  [string]$Root = '',
  [int]$Port = 8765
)
$ErrorActionPreference = 'Stop'
if (-not $Root) { $Root = Split-Path -Parent $PSScriptRoot }
$rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
if (-not [System.IO.File]::Exists($rootFull + 'index.html')) { throw "There is no index.html in $rootFull" }
$types = @{ '.html' = 'text/html; charset=utf-8'; '.js' = 'application/javascript; charset=utf-8'; '.css' = 'text/css; charset=utf-8'
  '.png' = 'image/png'; '.jpg' = 'image/jpeg'; '.jpeg' = 'image/jpeg'; '.gif' = 'image/gif'; '.svg' = 'image/svg+xml'
  '.json' = 'application/json'; '.bmp' = 'image/bmp'; '.webp' = 'image/webp'; '.ico' = 'image/x-icon'; '.txt' = 'text/plain; charset=utf-8' }
$listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $Port)
$listener.Start()
Write-Host "Serving $rootFull on http://localhost:$Port/  (Ctrl+C stops it)"
try {
  while ($true) {
    $client = $listener.AcceptTcpClient()
    $client.ReceiveTimeout = 1500        # drop idle pre-connected sockets instead of waiting for ever
    $client.SendTimeout = 5000
    try {
      $stream = $client.GetStream()
      $reader = New-Object System.IO.StreamReader($stream)
      $line = $reader.ReadLine()
      while ($true) { $h = $reader.ReadLine(); if ($null -eq $h -or $h -eq '') { break } }
      $status = '404 Not Found'; $bytes = [System.Text.Encoding]::UTF8.GetBytes('not found'); $ct = 'text/plain'
      if ($line -match '^GET\s+(\S+)') {
        $path = [System.Uri]::UnescapeDataString(($Matches[1] -split '\?')[0])
        if ($path -eq '/') { $path = '/index.html' }
        $full = [System.IO.Path]::GetFullPath((Join-Path $rootFull ($path.TrimStart('/') -replace '/', '\')))
        if ($full.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase) -and [System.IO.File]::Exists($full)) {
          $fs = [System.IO.File]::Open($full, 'Open', 'Read', 'ReadWrite')
          try { $bytes = New-Object byte[] $fs.Length; [void]$fs.Read($bytes, 0, $bytes.Length) } finally { $fs.Dispose() }
          $ct = $types[[System.IO.Path]::GetExtension($full).ToLower()]; if (-not $ct) { $ct = 'application/octet-stream' }
          $status = '200 OK'
        }
      } else { $status = '405 Method Not Allowed'; $bytes = [System.Text.Encoding]::UTF8.GetBytes('only GET') }
      $hdr = "HTTP/1.1 $status`r`nContent-Type: $ct`r`nContent-Length: $($bytes.Length)`r`nCache-Control: no-store`r`nConnection: close`r`n`r`n"
      $hb = [System.Text.Encoding]::ASCII.GetBytes($hdr)
      $stream.Write($hb, 0, $hb.Length); $stream.Write($bytes, 0, $bytes.Length); $stream.Flush()
    } catch { } finally { $client.Close() }
  }
} finally { $listener.Stop() }
