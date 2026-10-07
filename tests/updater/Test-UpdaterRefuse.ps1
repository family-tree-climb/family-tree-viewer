<#
  Test-UpdaterRefuse.ps1
  The program updater (tools\Update-Program.ps1) refuses what it must refuse and stays quiet when it cannot
  reach anything:
    a zip whose SHA-256 does not match; zips holding '../x', 'C:/x', 'data/x' (also listed in the zip's own
    tools/program-files.txt) or 'family-settings.js'; HTTP 500; nothing listening;
    automatic reports: the Google Form POST reaches a local test server with its 4 fields, at most once per
    kind per day (also for a failed document update);
    the document-update lock: no install while a document update holds it, and the lock is held during the swap.
  After every step, the program, family-settings.js, tools\settings.txt, data\ and the other files are unchanged.
  Usage: powershell -NoProfile -ExecutionPolicy Bypass -File tests\updater\Test-UpdaterRefuse.ps1 [-WorkDir <folder>]
  Exit code 0 = passed, 1 = failed. No network: the web server runs inside this test on 127.0.0.1.
#>
param([string]$WorkDir = '')
. (Join-Path $PSScriptRoot 'UpdaterTestLib.ps1')
$exitCode = 1
$server = $null
$heldLock = $null
try {
  $root = New-TestRoot 'refuse' $WorkDir
  Write-Host "Test-UpdaterRefuse in $root"
  Step 'setup: made-up documents, an installation of 1.0.0 with automatic reports to a test server, release 1.0.4'
  $docs = Join-Path $root 'life history'
  New-SyntheticDocs $docs
  $server = Start-FakeServer (Join-Path $root 'releases')
  $r100 = New-TestRelease '1.0.0' $null ''
  $r104 = New-TestRelease '1.0.4' $null "$($server.Base)/1.0.4"
  $v = New-TestViewer 'pc' $r100.Program $docs
  Set-ReportForm $v "$($server.Base)/forms/formResponse"
  $snap = Get-Snapshot $v
  function Test-Unchanged([string]$when) {
    Test-ProgramIs $v $r100.Program "$when : the program is still 1.0.0"
    Test-ProtectedSame $snap $v $when
    Check (-not [IO.Directory]::Exists((Join-Path $v 'program-previous'))) "$when : nothing was saved as a previous version"
  }
  function Get-Posts { return @($server.Log | Where-Object { $_ -like 'POST *' }) }

  Step 'wrong SHA-256 (over HTTP): refused, and an automatic report is sent'
  Write-TestFile (Join-Path $root 'releases\wrong\family-tree-viewer-1.0.4.zip.sha256') (('0' * 64) + "  family-tree-viewer-1.0.4.zip`n")
  Write-ReleaseJson (Join-Path $root 'releases\wrong\latest.json') '1.0.4' "$($server.Base)/1.0.4/family-tree-viewer-1.0.4.zip" "$($server.Base)/wrong/family-tree-viewer-1.0.4.zip.sha256"
  $r = Invoke-Updater $v @('-CheckNow', '-NoDocumentUpdate', '-ReleaseUrl', "$($server.Base)/wrong/latest.json")
  Check ($r.Code -eq 1 -and $r.Result -eq 'refused') 'result refused, exit 1'
  Check ((Get-UpdaterLog $v) -match 'SHA-256 .* does not match') 'the log says the hash does not match'
  Check (@($server.Log | Where-Object { $_ -like 'GET /1.0.4/family-tree-viewer-1.0.4.zip*' }).Count -eq 1) 'the zip was downloaded over HTTP'
  Test-Unchanged 'wrong SHA-256'
  $posts = @(Get-Posts)
  Check ($posts.Count -eq 1 -and $posts[0] -like 'POST /forms/formResponse*') 'one report was POSTed to the form address'
  if ($posts.Count -ge 1) {
    $fields = @{}
    foreach ($kv in ($posts[0].Split("`t")[1]).Split('&')) { $p = $kv.Split('='); $fields[[Uri]::UnescapeDataString($p[0])] = [Uri]::UnescapeDataString($p[1]) }
    Check ($fields['entry.1'] -eq '1.0.0') 'field version (entry.1) = 1.0.0'
    Check ($fields['entry.2'] -match '^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d[+-]\d\d:\d\d$') "field when (entry.2) is an ISO time ($($fields['entry.2']))"
    Check ($fields['entry.3'] -eq 'program-update-refused') 'field what (entry.3) = program-update-refused'
    Check ($fields['entry.4'] -match 'SHA-256' -and $fields['entry.4'].Length -le 1503) 'field details (entry.4) says why, at most 1500 characters'
  }

  Step 'zips with forbidden paths: refused, nothing changed'
  $good = Read-ZipEntries $r104.Zip
  $n = 4
  foreach ($bad in @('../x', 'C:/x', 'data/x', 'family-settings.js')) {
    $n++
    $ver = "1.0.$n"
    $entries = [ordered]@{}
    foreach ($k in $good.Keys) { $entries[$k] = $good[$k] }
    $entries['app/version.js'] = "window.FAMILY_VERSION = '$ver';`n"
    $entries[$bad] = 'x'
    if ($bad -eq 'data/x') { $entries['tools/program-files.txt'] = [Text.Encoding]::UTF8.GetString($good['tools/program-files.txt']) + "data/x`n" }
    $dir = Join-Path $root "releases\bad$n"
    $zip = New-CustomZip $dir $ver $entries
    Write-ReleaseJson (Join-Path $dir 'latest.json') $ver $zip "$zip.sha256"
    $r = Invoke-Updater $v @('-CheckNow', '-NoDocumentUpdate', '-ReleaseUrl', (Join-Path $dir 'latest.json'))
    $log = Get-UpdaterLog $v
    Check ($r.Code -eq 1 -and $r.Result -eq 'refused') "'$bad': result refused, exit 1"
    Check ($log.Contains("version $ver was refused") -and $log.Contains("'$bad'")) "'$bad': the log names it"
    Check (-not [IO.Directory]::Exists((Join-Path $v "updates\$ver"))) "'$bad': the download was removed"
    Check (-not [IO.File]::Exists((Join-Path $root 'pc\x')) -and -not [IO.File]::Exists((Join-Path $root 'x')) -and -not [IO.File]::Exists('C:\x')) "'$bad': no file x was written anywhere"
    Test-Unchanged "'$bad'"
  }
  Check (@(Get-Posts).Count -eq 1) 'no second report of the same kind on the same day'
  Check ((Get-UpdaterLog $v) -match "automatic report 'program-update-refused' was already sent today") 'the log says the report was already sent today'

  Step 'HTTP 500 and nothing listening: quiet (exit 0, one log line)'
  $r = Invoke-Updater $v @('-CheckNow', '-NoDocumentUpdate', '-ReleaseUrl', "$($server.Base)/fail500/latest.json")
  Check ($r.Code -eq 0 -and $r.Result -eq 'offline') 'HTTP 500: result offline, exit 0'
  Check ((Get-UpdaterLog $v) -match 'could not check for a new program version \(HTTP 500\)') 'HTTP 500: logged'
  $dead = Get-DeadPort
  $r = Invoke-Updater $v @('-CheckNow', '-NoDocumentUpdate', '-ReleaseUrl', "http://127.0.0.1:$dead/latest.json")
  Check ($r.Code -eq 0 -and $r.Result -eq 'offline') 'nothing listening: result offline, exit 0'
  Test-Unchanged 'HTTP 500 / unreachable'
  Check (@(Get-Posts).Count -eq 1) 'being offline sends no report'

  Step 'a failed document update: one automatic report per day'
  Set-CheckedToday $v
  [IO.Directory]::Move($docs, "$docs-away")
  try {
    $r1 = Invoke-Updater $v @()
    $r2 = Invoke-Updater $v @()
  } finally { [IO.Directory]::Move("$docs-away", $docs) }
  Check ($r1.Code -eq 1 -and $r2.Code -eq 1) 'the updater reports the failure in its exit code'
  $posts = @(@(Get-Posts) | Where-Object { $_ -match 'entry\.3=document-update-failed' })
  Check ($posts.Count -eq 1) 'exactly one document-update-failed report'
  Check ($posts.Count -eq 1 -and [Uri]::UnescapeDataString($posts[0]) -match 'Cannot find the life-history folder') 'the report holds the error line'
  $r = Invoke-Updater $v @()
  Check ($r.Code -eq 0 -and (Get-StatusText $v) -match '"state":"done"') 'with the documents back, the document update works again'
  Test-Unchanged 'failed document update'

  Step 'the documents are not there while a good release is checked: taken back, but NOT remembered as bad'
  [IO.Directory]::Move($docs, "$docs-away")
  try {
    $r1 = Invoke-Updater $v @('-CheckNow', '-ReleaseUrl', $r104.Json)
    $r2 = Invoke-Updater $v @('-CheckNow', '-NoDocumentUpdate', '-Chrome', 'none', '-ReleaseUrl', $r104.Json)
  } finally { [IO.Directory]::Move("$docs-away", $docs) }
  Check ($r1.Code -eq 1 -and $r1.Result -eq 'documents-failed' -and -not [IO.Directory]::Exists((Join-Path $v 'updates\1.0.4'))) 'with the icon: the documents could not be read, so no new version is tried'
  $log = Get-UpdaterLog $v
  Check ($r2.Code -eq 1 -and $r2.Result -eq 'rolled-back') 'checked without reading the documents first: the new version fails its check and is taken back'
  Check ($log -match 'the previous version has problems on this computer too' -and $log -match 'tried again on another day') 'the log says the previous version fails too, so it is tried again another day'
  $st = Get-UpdaterState $v
  Check ($st['badVersions'] -notmatch '1\.0\.4' -and $st['failedDays.1.0.4'] -eq (Get-Date).ToString('yyyy-MM-dd')) "1.0.4 is not remembered as bad (failedDays.1.0.4=$($st['failedDays.1.0.4']))"
  Test-Unchanged 'documents away during the check'

  Step 'the document-update lock: no install while a document update holds it'
  $heldLock = New-Object System.Threading.Mutex($false, 'Local\FamilyTreeViewerUpdate')
  $got = $false
  try { $got = $heldLock.WaitOne(120000) } catch [System.Threading.AbandonedMutexException] { $got = $true }
  Check $got 'the test holds the document-update lock'
  $r = Invoke-Updater $v @('-CheckNow', '-NoDocumentUpdate', '-Chrome', 'none', '-MutexWaitSec', '3', '-ReleaseUrl', $r104.Json)
  $heldLock.ReleaseMutex(); $heldLock.Dispose(); $heldLock = $null
  Check ($r.Result -eq 'busy') 'result busy'
  Check ((Get-UpdaterState $v)['lastCheckDay'] -ne (Get-Date).ToString('yyyy-MM-dd')) 'it will look again at the next start'
  Check (-not [IO.Directory]::Exists((Join-Path $v 'updates\1.0.4'))) 'the download was removed'
  Test-Unchanged 'lock held by a document update'

  Step 'an install that is interrupted (the computer switched off): the next start puts the previous version back'
  $copy0 = Join-Path $root 'killed-updater.ps1'
  [IO.File]::Copy((Join-Path $v 'tools\Update-Program.ps1'), $copy0)
  $psi = New-Object Diagnostics.ProcessStartInfo
  $psi.FileName = $script:PowerShellExe
  $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$copy0`" -Viewer `"$v`" -CheckNow -NoDocumentUpdate -Chrome none -PauseInSwapSec 60 -ReleaseUrl `"$($r104.Json)`""
  $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
  $proc = [Diagnostics.Process]::Start($psi)
  $marker = Join-Path $v 'updates\install-in-progress.txt'
  $t0 = Get-Date
  while (-not [IO.File]::Exists($marker) -and -not $proc.HasExited -and ((Get-Date) - $t0).TotalSeconds -lt 120) { Start-Sleep -Milliseconds 200 }
  Check ([IO.File]::Exists($marker)) 'the install got as far as the swap'
  $proc.Kill(); [void]$proc.WaitForExit(10000)
  Set-CheckedToday $v
  $r = Invoke-Updater $v @('-NoDocumentUpdate')
  $log = Get-UpdaterLog $v
  Check ($log -match 'the installation of version 1\.0\.4 was interrupted' -and $log -match 'the previous version \(1\.0\.0\) was put back \(interrupted installation\)') 'the next start noticed it and put 1.0.0 back'
  Check (-not [IO.File]::Exists($marker) -and -not [IO.Directory]::Exists((Join-Path $v 'updates\1.0.4'))) 'the marker and the half-done install were cleaned up'
  Check ((Get-UpdaterState $v)['interrupted.1.0.4'] -eq '1') 'the interruption is counted (3 times = not tried again)'
  Test-Unchanged 'interrupted install'

  Step 'the lock is held while the files are swapped'
  $copy = Join-Path $root 'swap-updater.ps1'
  [IO.File]::Copy((Join-Path $v 'tools\Update-Program.ps1'), $copy)
  $psi = New-Object Diagnostics.ProcessStartInfo
  $psi.FileName = $script:PowerShellExe
  $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$copy`" -Viewer `"$v`" -CheckNow -NoDocumentUpdate -Chrome none -PauseInSwapSec 8 -ReleaseUrl `"$($r104.Json)`""
  $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
  $proc = [Diagnostics.Process]::Start($psi)
  $marker = Join-Path $v 'updates\install-in-progress.txt'
  $t0 = Get-Date
  while (-not [IO.File]::Exists($marker) -and -not $proc.HasExited -and ((Get-Date) - $t0).TotalSeconds -lt 120) { Start-Sleep -Milliseconds 200 }
  $probe = New-Object System.Threading.Mutex($false, 'Local\FamilyTreeViewerUpdate')
  $free = $false
  try { $free = $probe.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $free = $true }
  if ($free) { $probe.ReleaseMutex() }
  Check ([IO.File]::Exists($marker) -and -not $free) 'during the swap the document-update lock is taken (a document update would wait)'
  [void]$proc.WaitForExit(300000)
  $freeAfter = $false
  for ($k = 0; $k -lt 50 -and -not $freeAfter; $k++) {
    try { $freeAfter = $probe.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $freeAfter = $true }
    if (-not $freeAfter) { Start-Sleep -Milliseconds 200 }
  }
  if ($freeAfter) { $probe.ReleaseMutex() }
  $probe.Dispose()
  Check $freeAfter 'after the install the lock is free again'
  Check ($proc.ExitCode -eq 0 -and (Get-InstalledVersion $v) -eq '1.0.4') 'and 1.0.4 was installed'
  Test-ProtectedSame $snap $v 'install with a pause in the swap'

  $exitCode = Complete-Test 'Test-UpdaterRefuse'
} catch {
  Write-Host "TEST ERROR: $($_.Exception.Message) $($_.InvocationInfo.PositionMessage)" -ForegroundColor Red
  $exitCode = 1
} finally {
  if ($heldLock) { try { $heldLock.ReleaseMutex() } catch { }; $heldLock.Dispose() }
  Stop-FakeServer $server
  Remove-TestRoot
}
exit $exitCode
