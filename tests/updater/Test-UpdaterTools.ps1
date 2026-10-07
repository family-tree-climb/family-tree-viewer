<#
  Test-UpdaterTools.ps1
  The pieces around the program updater:
    "Open Family Tree.cmd": runs the updater from a TEMP copy, and still reads the documents (the tree always
      opens) when tools\Update-Program.ps1 is missing, cannot be parsed, or cannot be copied to TEMP;
    tools\Build-Release.ps1: zips exactly the allow-list, writes the .sha256, and refuses bad lists;
    tools\Update-Program.ps1 -ValidateZip: the allow-list rules, one bad zip at a time;
    tools\Check-Tree.ps1: its JSON, without Chrome and with it, also for a newer version that loads one more file.
  The installation used here has no index.html, so no web browser is ever opened, and its once-a-day check
  is marked as done, so nothing asks GitHub. The .cmd runs in a hidden console (FAMILY_TREE_START_OPTION=/b).
  Usage: powershell -NoProfile -ExecutionPolicy Bypass -File tests\updater\Test-UpdaterTools.ps1 [-WorkDir <folder>]
  Exit code 0 = passed, 1 = failed.
#>
param([string]$WorkDir = '')
. (Join-Path $PSScriptRoot 'UpdaterTestLib.ps1')
$exitCode = 1
try {
  $root = New-TestRoot 'tools' $WorkDir
  Write-Host "Test-UpdaterTools in $root"
  Step 'setup'
  $docs = Join-Path $root 'life history'
  New-SyntheticDocs $docs
  $r100 = New-TestRelease '1.0.0' $null ''
  $v = New-TestViewer 'pc' $r100.Program $docs
  [IO.File]::Delete((Join-Path $v 'index.html'))     # so the document update's -Open never starts a web browser

  # ---------------------------------------------------------------- the desktop icon
  function Invoke-Icon([string]$tempDir) {
    $statusFile = Join-Path $v 'data\status.js'
    $t0 = [IO.File]::GetLastWriteTimeUtc($statusFile)
    $state0 = (Get-UpdaterState $v)['lastResult']
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = Join-Path $env:SystemRoot 'System32\cmd.exe'
    $psi.Arguments = '/d /c ""' + (Join-Path $v 'Open Family Tree.cmd') + '""'
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.EnvironmentVariables['TEMP'] = $tempDir; $psi.EnvironmentVariables['TMP'] = $tempDir
    $psi.EnvironmentVariables['FAMILY_TREE_START_OPTION'] = '/b'
    $p = [Diagnostics.Process]::Start($psi)
    [void]$p.WaitForExit(60000)
    # the .cmd returns at once; wait for what it started: the document update, and (if it ran) the updater
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $read = $false
    while ($sw.Elapsed.TotalSeconds -lt 120) {
      try { $read = ([IO.File]::GetLastWriteTimeUtc($statusFile) -gt $t0) -and ((Get-StatusText $v) -match '"state":"done"') } catch { $read = $false }
      $copies = @()
      if ([IO.Directory]::Exists($tempDir)) { $copies = @([IO.Directory]::GetFiles($tempDir, 'FamilyTree-Update-Program-*.ps1')) }
      if ($read -and $copies.Count -eq 0) { break }
      Start-Sleep -Milliseconds 300
    }
    Start-Sleep -Milliseconds 1500    # let the updater finish writing its state after the document update
    $state1 = (Get-UpdaterState $v)['lastResult']
    return @{ DocumentsRead = $read; UpdaterRan = ($state1 -ne $state0 -and $state1 -match '^checked-today'); Seconds = [int]$sw.Elapsed.TotalSeconds }
  }
  $tmp = Join-Path $root 'tmp'
  [void][IO.Directory]::CreateDirectory($tmp)
  Set-CheckedToday $v

  Step 'the icon: the updater runs from a TEMP copy and reads the documents'
  $i = Invoke-Icon $tmp
  Check $i.DocumentsRead 'the documents were read (status.js written anew)'
  Check $i.UpdaterRan 'the updater ran (its state was saved)'
  Check (@([IO.Directory]::GetFiles($tmp)).Count -eq 0) 'the TEMP copy was removed afterwards'
  Check ((Get-StatusText $v) -match '"version":"1\.0\.0"') 'status.js carries the version'

  Step 'the icon when tools\Update-Program.ps1 cannot be parsed: the documents are still read'
  $upd = Join-Path $v 'tools\Update-Program.ps1'
  $good = [IO.File]::ReadAllBytes($upd)
  [IO.File]::WriteAllText($upd, "param([string]`$Viewer)`r`nif ( {`r`n")
  $i = Invoke-Icon $tmp
  Check $i.DocumentsRead 'the documents were read'
  Check (-not $i.UpdaterRan) 'the broken updater did not run'
  Check (@([IO.Directory]::GetFiles($tmp)).Count -eq 0) 'the TEMP copy was removed'

  Step 'the icon when tools\Update-Program.ps1 is missing: the documents are still read'
  [IO.File]::Delete($upd)
  $i = Invoke-Icon $tmp
  Check $i.DocumentsRead 'the documents were read'
  Check (-not $i.UpdaterRan) 'no updater ran'
  [IO.File]::WriteAllBytes($upd, $good)

  Step 'the icon when the TEMP folder cannot be used: the documents are still read'
  $noTemp = Join-Path $root 'no-such-folder'
  $i = Invoke-Icon $noTemp
  Check $i.DocumentsRead 'the documents were read'
  Check (-not $i.UpdaterRan) 'no updater ran'
  Check (-not [IO.Directory]::Exists($noTemp) -or @([IO.Directory]::GetFiles($noTemp, 'FamilyTree-*')).Count -eq 0) 'no copy of the updater is left in TEMP'

  # ---------------------------------------------------------------- Build-Release
  Step 'Build-Release: exactly the allow-list, and a correct .sha256'
  $listed = @(Get-ProgramFiles $script:RepoRoot)
  $inZip = @((Read-ZipEntries $r100.Zip).Keys)
  Check (($listed -join '|') -ceq ($inZip -join '|')) "the zip holds exactly the $($listed.Count) listed files, in order"
  Check ($inZip -notcontains 'family-settings.js') 'family-settings.js is not in the zip'
  $shaText = [IO.File]::ReadAllText("$($r100.Zip).sha256")
  Check ($shaText -ceq ((Get-FileHashHex $r100.Zip) + "  family-tree-viewer-1.0.0.zip`n")) '.sha256 = "<lowercase hex>  <zip name>"'
  function Invoke-Build([string]$prog, [string[]]$more) {
    $o = & $script:PowerShellExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $prog 'tools\Build-Release.ps1') -Root $prog -OutDir (Join-Path $root 'build-out') -Quiet @more
    return @{ Code = $LASTEXITCODE; Out = ($o -join "`n") }
  }
  $b = Invoke-Build $r100.Program @('-Version', 'v9.9.9')
  Check ($b.Code -eq 1 -and $b.Out -match 'not the version in app') 'a -Version that differs from app\version.js is refused'
  $bad = Join-Path $root 'programs\bad-list'
  Copy-Program $r100.Program $bad
  [IO.File]::AppendAllText((Join-Path $bad 'tools\program-files.txt'), "data/x`n")
  Write-TestFile (Join-Path $bad 'data\x') 'x'
  $b = Invoke-Build $bad @()
  Check ($b.Code -eq 1 -and $b.Out -match "'data/x'") 'a list naming data/x is refused'
  $bad2 = Join-Path $root 'programs\bad-cmd'
  Copy-Program $r100.Program $bad2
  [IO.File]::WriteAllText((Join-Path $bad2 'Open Family Tree.cmd'), "@echo off`nrem LF only`n")
  $b = Invoke-Build $bad2 @()
  Check ($b.Code -eq 1 -and $b.Out -match 'CR LF') 'a .cmd without Windows line endings is refused'
  $bad3 = Join-Path $root 'programs\bad-missing'
  Copy-Program $r100.Program $bad3
  [IO.File]::AppendAllText((Join-Path $bad3 'tools\program-files.txt'), "app/not-there.js`n")
  $b = Invoke-Build $bad3 @()
  Check ($b.Code -eq 1 -and $b.Out -match 'not-there\.js') 'a listed file that does not exist is refused'
  Check (-not [IO.File]::Exists((Join-Path $root 'build-out\family-tree-viewer-1.0.0.zip'))) 'no zip was left behind by the refused builds'

  # ---------------------------------------------------------------- the zip rules
  Step 'Update-Program.ps1 -ValidateZip: the allow-list rules'
  $updater = Join-Path $r100.Program 'tools\Update-Program.ps1'
  function Test-Zip([string]$zip) {
    $o = & $script:PowerShellExe -NoProfile -ExecutionPolicy Bypass -File $updater -ValidateZip $zip
    return @{ Code = $LASTEXITCODE; Out = ($o -join "`n") }
  }
  $z = Test-Zip $r100.Zip
  Check ($z.Code -eq 0 -and $z.Out -match 'ZIP OK: version 1\.0\.0') 'the good release passes'
  $goodEntries = Read-ZipEntries $r100.Zip
  $listText = [Text.Encoding]::UTF8.GetString($goodEntries['tools/program-files.txt'])
  $cases = [ordered]@{
    '../x' = @{ add = '../x' }; 'C:/x' = @{ add = 'C:/x' }; 'backslash' = @{ add = 'app\x.js' }; 'data/x' = @{ add = 'data/x'; list = $true }
    'upper case DATA/x' = @{ add = 'DATA/x'; list = $true }; 'dev/x' = @{ add = 'dev/private/x'; list = $true }; 'updates/x' = @{ add = 'updates/x'; list = $true }
    'program-previous/x' = @{ add = 'program-previous/x'; list = $true }; 'family-settings.js' = @{ add = 'family-settings.js'; list = $true }
    'tools/settings.txt' = @{ add = 'tools/settings.txt'; list = $true }; '/abs' = @{ add = '/abs.js' }; 'trailing dot' = @{ add = 'app./x.js'; list = $true }
    'device name' = @{ add = 'tools/CON'; list = $true }; 'not listed' = @{ add = 'extra.txt' }; 'listed, missing' = @{ listOnly = 'app/missing.js' }
    'no list' = @{ drop = 'tools/program-files.txt' }; 'wrong version' = @{ version = '2.0.0' }; 'no Update-Program.ps1' = @{ drop = 'tools/Update-Program.ps1'; unlist = 'tools/Update-Program.ps1' }
    'an 8.3 short name (FAMILY~1.JS)' = @{ add = 'FAMILY~1.JS'; list = $true }
    'no "Go back to the previous version.cmd"' = @{ drop = 'Go back to the previous version.cmd'; unlist = 'Go back to the previous version.cmd' }
    'no tools/check-tree.html' = @{ drop = 'tools/check-tree.html'; unlist = 'tools/check-tree.html' }
  }
  $n = 0
  foreach ($name in $cases.Keys) {
    $c = $cases[$name]; $n++
    $e = [ordered]@{}
    foreach ($k in $goodEntries.Keys) { if ($k -ne $c.drop) { $e[$k] = $goodEntries[$k] } }
    $lt = $listText
    if ($c.unlist) { $lt = $lt.Replace("$($c.unlist)`n", '').Replace("$($c.unlist)`r`n", '') }
    if ($c.list) { $lt += "$($c.add)`n" }
    if ($c.listOnly) { $lt += "$($c.listOnly)`n" }
    if ($c.drop -ne 'tools/program-files.txt') { $e['tools/program-files.txt'] = $lt }
    if ($c.add) { $e[$c.add] = 'x' }
    if ($c.version) { $e['app/version.js'] = "window.FAMILY_VERSION = '$($c.version)';" }
    $zip = New-CustomZip (Join-Path $root "zips\$n") '1.0.0' $e
    $z = Test-Zip $zip
    Check ($z.Code -eq 1 -and $z.Out -match 'ZIP REFUSED') "refused: $name$(if ($z.Code -ne 1) { ' (' + $z.Out + ')' })"
  }
  [IO.File]::WriteAllText("$($r100.Zip).sha256", ('f' * 64) + "  family-tree-viewer-1.0.0.zip`n")
  $z = Test-Zip $r100.Zip
  Check ($z.Code -eq 1 -and $z.Out -match 'does not match') 'refused: a .sha256 that does not match'

  # ---------------------------------------------------------------- Check-Tree
  Step 'Check-Tree.ps1'
  $ct = Join-Path $v 'tools\Check-Tree.ps1'
  $o = & $script:PowerShellExe -NoProfile -ExecutionPolicy Bypass -File $ct -Chrome none
  Check ($LASTEXITCODE -eq 3 -and ($o -join '') -match '^\{"skipped":true') 'without Chrome: {"skipped":true,...}, exit 3'
  $o = & $script:PowerShellExe -NoProfile -ExecutionPolicy Bypass -File $ct
  $code = $LASTEXITCODE
  $j = $null
  try { $j = ($o -join '') | ConvertFrom-Json } catch { }
  if ($j -and $j.skipped) { Write-Host '  (Google Chrome not found: the page checks are skipped)' }
  else {
    Check ($code -eq 0 -and $j -and $j.docs -eq 7 -and $j.personDocs -eq 6 -and $j.version -eq '1.0.0' -and $j.roots.tom -and $j.roots.ruth -and $null -eq $j.buildError) "a healthy tree: 7 documents, 6 attached, roots tom and ruth, no build error ($($o -join ''))"
    Check ($j.peopleKnown -ge 14 -and $j.peopleKnown -le $j.people) "known people counted ($($j.peopleKnown) of $($j.people))"
    $v2 = Copy-TestViewer $v 'pc-no-settings'
    [IO.File]::Delete((Join-Path $v2 'family-settings.js'))
    $o = & $script:PowerShellExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $v2 'tools\Check-Tree.ps1')
    Check ($LASTEXITCODE -eq 1 -and ($o -join '') -match '"buildError":"the family settings \(family-settings\.js\) are missing') 'family-settings.js missing: a build error, exit 1'
    # a newer version whose index.html loads one more model file (that genealogy.js needs): the check page of
    # the installed version reads the list of scripts from that index.html, so it measures the newer version too
    $v3 = Copy-TestViewer $v 'pc-new-file'
    Write-TestFile (Join-Path $v3 'app\helper.js') "window.FT_TEST_HELPER = true;`n"
    $gf = Assert-InTest (Join-Path $v3 'app\genealogy.js')
    [IO.File]::WriteAllText($gf, "if (!window.FT_TEST_HELPER) { throw new Error('app/helper.js is needed'); }`n" + [IO.File]::ReadAllText($gf), (New-Object Text.UTF8Encoding($false)))
    $html = [IO.File]::ReadAllText((Join-Path $r100.Program 'index.html'))
    Check ($html.Contains('<script src="app/genealogy.js">')) 'index.html loads app/genealogy.js'
    Write-TestFile (Join-Path $v3 'index.html') $html.Replace('<script src="app/genealogy.js">', "<script src=`"app/helper.js`"></script>`n<script src=`"app/genealogy.js`">")
    $o = & $script:PowerShellExe -NoProfile -ExecutionPolicy Bypass -File $ct -Viewer $v3
    $code = $LASTEXITCODE
    $j3 = $null
    try { $j3 = ($o -join '') | ConvertFrom-Json } catch { }
    Check ($code -eq 0 -and $j3 -and $j3.personDocs -eq 6 -and $null -eq $j3.buildError) "a newer version that loads one more file: measured with the installed check page, no build error ($($o -join ''))"
    $left = @()
    foreach ($d in @((Join-Path $v 'updates\chrome-check'), (Join-Path $v2 'updates\chrome-check'), (Join-Path $v3 'updates\chrome-check'))) { if ([IO.Directory]::Exists($d)) { $left += @([IO.Directory]::GetDirectories($d)) } }
    Check ($left.Count -eq 0) "Chrome's throwaway profiles were removed"
  }

  $exitCode = Complete-Test 'Test-UpdaterTools'
} catch {
  Write-Host "TEST ERROR: $($_.Exception.Message) $($_.InvocationInfo.PositionMessage)" -ForegroundColor Red
  $exitCode = 1
} finally {
  Remove-TestRoot
}
exit $exitCode
