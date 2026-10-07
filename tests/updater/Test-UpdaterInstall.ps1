<#
  Test-UpdaterInstall.ps1
  The program updater (tools\Update-Program.ps1) on a made-up installation, with fake releases built by
  tools\Build-Release.ps1 from copies of this repository:
    up to date -> nothing; the once-a-day rule; -CheckNow; a good release is installed (files, status.js
    version, program-previous); a release whose document update fails is taken back and never tried again;
    a release whose genealogy.js loses people is taken back by the health check; going back on request
    with "Go back to the previous version.cmd".
  After every step, family-settings.js, tools\settings.txt, data\ and files that are not the program's
  must be byte-identical.
  Usage: powershell -NoProfile -ExecutionPolicy Bypass -File tests\updater\Test-UpdaterInstall.ps1 [-WorkDir <folder>]
  Exit code 0 = passed, 1 = failed. Needs Google Chrome for the health-check steps (they are skipped without it).
#>
param([string]$WorkDir = '')
. (Join-Path $PSScriptRoot 'UpdaterTestLib.ps1')
$exitCode = 1
try {
  $root = New-TestRoot 'install' $WorkDir
  Write-Host "Test-UpdaterInstall in $root"
  Step 'setup: made-up documents, an installation of 1.0.0, releases 1.0.1 (good), 1.0.2 (document update fails), 1.0.3 (loses people)'
  $docs = Join-Path $root 'life history'
  New-SyntheticDocs $docs
  $r100 = New-TestRelease '1.0.0' $null ''
  # 1.0.1 drops one program file and brings a new one in a new folder
  $r101 = New-TestRelease '1.0.1' {
    param($p)
    Edit-TestFile (Join-Path $p 'tools\program-files.txt') "tools/Install-FamilyTree.ps1" "extras/notes.txt"
    Write-TestFile (Join-Path $p 'extras\notes.txt') "a file new in 1.0.1`r`n"
  } ''
  $r102 = New-TestRelease '1.0.2' { param($p) Edit-TestFile (Join-Path $p 'tools\Update-FamilyTree.ps1') "`$ErrorActionPreference = 'Stop'" "`$ErrorActionPreference = 'Stop'; exit 7" } ''
  $r103 = New-TestRelease '1.0.3' { param($p) Edit-TestFile (Join-Path $p 'app\genealogy.js') 'var docList = (data && data.docs) || [];' 'var docList = ((data && data.docs) || []).slice(0, 1);' } ''
  $v = New-TestViewer 'pc' $r100.Program $docs
  $snap = Get-Snapshot $v
  $hasChrome = $false
  foreach ($c in @((Join-Path ([string]$env:ProgramFiles) 'Google\Chrome\Application\chrome.exe'), (Join-Path ([string]${env:ProgramFiles(x86)}) 'Google\Chrome\Application\chrome.exe'), (Join-Path ([string]$env:LOCALAPPDATA) 'Google\Chrome\Application\chrome.exe'))) { if ([IO.File]::Exists($c)) { $hasChrome = $true } }
  if (-not $hasChrome) { Write-Host '  (Google Chrome not found: the health-check page is skipped)' }

  Step 'the latest release is the installed version: nothing happens'
  $r = Invoke-Updater $v @('-ReleaseUrl', $r100.Json)
  Check ($r.Code -eq 0 -and $r.Result -eq 'up-to-date') 'result up-to-date, exit 0'
  Test-ProgramIs $v $r100.Program 'the program is still 1.0.0'
  Check (-not [IO.Directory]::Exists((Join-Path $v 'program-previous'))) 'no program-previous folder'
  Check ((Get-UpdaterState $v)['lastCheckDay'] -eq (Get-Date).ToString('yyyy-MM-dd')) 'the check of today is remembered'
  Test-ProtectedSame $snap $v 'up to date'

  Step 'once a day: a newer release is not even looked at again today'
  $r = Invoke-Updater $v @('-ReleaseUrl', $r101.Json)
  Check ($r.Code -eq 0 -and $r.Result -eq 'checked-today') 'result checked-today'
  Check ((Get-InstalledVersion $v) -eq '1.0.0') 'still 1.0.0'
  Check ((Get-UpdaterLog $v) -notmatch 'downloading') 'nothing was downloaded'

  Step '-CheckNow: the good release 1.0.1 is installed'
  $r = Invoke-Updater $v @('-CheckNow', '-ReleaseUrl', $r101.Json)
  $log = Get-UpdaterLog $v
  Check ($r.Code -eq 0 -and $r.Result -eq 'installed') 'result installed, exit 0'
  Test-ProgramIs $v $r101.Program 'the program files are exactly those of 1.0.1'
  Check (-not [IO.File]::Exists((Join-Path $v 'tools\Install-FamilyTree.ps1'))) 'a file no longer in the list was removed'
  Check ([IO.File]::Exists((Join-Path $v 'extras\notes.txt'))) 'a new file in a new folder was added'
  $status = Get-StatusText $v
  Check ($status -match '"version":"1\.0\.1"') 'status.js carries the new version (the open page reloads itself)'
  Check ($status -match '"programMessage":"The family tree program was updated to version 1\.0\.1\."') 'status.js has the message for the open page'
  Check ([IO.File]::Exists((Join-Path $v 'program-previous\manifest.txt'))) 'program-previous\manifest.txt exists'
  Test-ProgramIs (Join-Path $v 'program-previous') $r100.Program 'program-previous holds the 1.0.0 program files'
  $man = [IO.File]::ReadAllText((Join-Path $v 'program-previous\manifest.txt'))
  Check ($man -match "(?m)^N`t`textras/notes.txt" -and $man -match "(?m)^version=1\.0\.0" -and $man -match '(?m)^end=\d+') 'the manifest names the old version and the new file'
  Check (-not [IO.Directory]::Exists((Join-Path $v 'updates\1.0.1')) -and -not [IO.File]::Exists((Join-Path $v 'updates\install-in-progress.txt'))) 'the download and the install marker were cleaned up'
  if ($hasChrome) {
    Check ($log -match 'health before: version 1\.0\.0, 7 documents, 6 attached to people, \d+ known people, roots: tom ruth') 'the health check measured the tree before'
    Check ($log -match 'health after: +version 1\.0\.1, 7 documents, 6 attached to people') 'the health check measured the tree after'
  }
  Test-ProtectedSame $snap $v '1.0.1 installed'

  Step 'release 1.0.2, whose document update fails: taken back'
  $r = Invoke-Updater $v @('-CheckNow', '-Chrome', 'none', '-ReleaseUrl', $r102.Json)
  Check ($r.Code -eq 1 -and $r.Result -eq 'rolled-back') 'result rolled-back, exit 1'
  Test-ProgramIs $v $r101.Program 'the program is 1.0.1 again'
  Check ((Get-UpdaterState $v)['badVersions'] -match '(^|,)1\.0\.2(,|$)') '1.0.2 is remembered as bad'
  $status = Get-StatusText $v
  Check ($status -match '"version":"1\.0\.1"' -and $status -match '"state":"done"') 'status.js: version 1.0.1, the document update with 1.0.1 ran again'
  Check ($status -match 'programMessage":"A new version of the family tree program \(1\.0\.2\) did not work') 'status.js has the message for the open page'
  Check ((Get-UpdaterLog $v) -match 'document update with the new version failed \(exit code 7') 'the log says why'
  Test-ProgramIs (Join-Path $v 'program-previous') $r100.Program 'program-previous still holds 1.0.0 (the version before the current one)'
  Check (-not [IO.Directory]::Exists((Join-Path $v 'updates\1.0.2'))) 'the download and the saved copy were cleaned up'
  Test-ProtectedSame $snap $v '1.0.2 taken back'

  Step 'release 1.0.2 again: never tried again'
  $r = Invoke-Updater $v @('-CheckNow', '-NoDocumentUpdate', '-ReleaseUrl', $r102.Json)
  Check ($r.Code -eq 0 -and $r.Result -eq 'bad-version') 'result bad-version'
  Check (-not [IO.Directory]::Exists((Join-Path $v 'updates\1.0.2'))) 'nothing was downloaded'
  Test-ProgramIs $v $r101.Program 'still 1.0.1'

  if ($hasChrome) {
    Step 'release 1.0.3, whose genealogy.js loses people: the health check takes it back'
    $r = Invoke-Updater $v @('-CheckNow', '-ReleaseUrl', $r103.Json)
    Check ($r.Code -eq 1 -and $r.Result -eq 'rolled-back') 'result rolled-back, exit 1'
    $log = Get-UpdaterLog $v
    Check ($log -match 'documents attached to people dropped from 6 to 1') 'the log names the drop in attached documents'
    Check ($log -match 'known people dropped') 'the log names the drop in known people'
    Test-ProgramIs $v $r101.Program 'the program is 1.0.1 again'
    Check ((Get-UpdaterState $v)['badVersions'] -match '(^|,)1\.0\.3(,|$)') '1.0.3 is remembered as bad'
    Test-ProtectedSame $snap $v '1.0.3 taken back'
  }

  Step '"Go back to the previous version.cmd": back to 1.0.0 on request'
  $tmp = Join-Path $root 'tmp'
  [void][IO.Directory]::CreateDirectory($tmp)
  $psi = New-Object Diagnostics.ProcessStartInfo
  $psi.FileName = Join-Path $env:SystemRoot 'System32\cmd.exe'
  $psi.Arguments = '/d /c ""' + (Join-Path $v 'Go back to the previous version.cmd') + '""'
  $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true; $psi.RedirectStandardOutput = $true
  $psi.EnvironmentVariables['TEMP'] = $tmp; $psi.EnvironmentVariables['TMP'] = $tmp; $psi.EnvironmentVariables['FAMILY_TREE_NO_PAUSE'] = '1'
  $p = [Diagnostics.Process]::Start($psi)
  $cmdOut = $p.StandardOutput.ReadToEnd()
  $done = $p.WaitForExit(300000)
  Check ($done -and $cmdOut -match 'Done: the previous version \(1\.0\.0\)') 'the .cmd says it is done'
  if ($cmdOut -notmatch 'Done: the previous version') { Write-Host "  (the .cmd said: $cmdOut)" }
  Test-ProgramIs $v $r100.Program 'the program is 1.0.0 again (including the file 1.0.1 had removed)'
  Check (-not [IO.File]::Exists((Join-Path $v 'extras\notes.txt'))) 'the file 1.0.1 had added is gone'
  Check ((Get-StatusText $v) -match '"version":"1\.0\.0"') 'status.js carries 1.0.0'
  Check ((Get-UpdaterState $v)['badVersions'] -match '(^|,)1\.0\.1(,|$)') '1.0.1 (taken away on request) is not installed again automatically'
  Check (@([IO.Directory]::GetFiles($tmp)).Count -eq 0) 'the .cmd removed its temporary copy'
  Test-ProtectedSame $snap $v 'gone back on request'
  $r = Invoke-Updater $v @('-CheckNow', '-NoDocumentUpdate', '-ReleaseUrl', $r101.Json)
  Check ($r.Result -eq 'bad-version' -and (Get-InstalledVersion $v) -eq '1.0.0') '1.0.1 is not installed again'

  $exitCode = Complete-Test 'Test-UpdaterInstall'
} catch {
  Write-Host "TEST ERROR: $($_.Exception.Message) $($_.InvocationInfo.PositionMessage)" -ForegroundColor Red
  $exitCode = 1
} finally {
  Remove-TestRoot
}
exit $exitCode
