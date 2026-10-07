<#
  Test-UpdaterBootstrap.ps1
  The first install of 1.0 over an installation from before 1.0 (no tools\program-files.txt, no
  family-settings.js, no app\version.js; its settings were inside app\config.js), with
  tools\Update-Program.ps1 -InstallZip from the new release:
    without -SettingsFrom it refuses (it cannot invent the family's settings) and changes nothing;
    with -SettingsFrom it installs, using the built-in list of the old program files, and leaves CLAUDE.md,
    HANDOFF.md and every other unknown file alone; going back restores the old program exactly;
    an existing family-settings.js is never replaced.
  Usage: powershell -NoProfile -ExecutionPolicy Bypass -File tests\updater\Test-UpdaterBootstrap.ps1 [-WorkDir <folder>]
  Exit code 0 = passed, 1 = failed.
#>
param([string]$WorkDir = '')
. (Join-Path $PSScriptRoot 'UpdaterTestLib.ps1')
$exitCode = 1
try {
  $root = New-TestRoot 'bootstrap' $WorkDir
  Write-Host "Test-UpdaterBootstrap in $root"
  Step 'setup: an installation from before 1.0 and the release 1.0.0'
  $docs = Join-Path $root 'life history'
  New-SyntheticDocs $docs
  $r100 = New-TestRelease '1.0.0' $null ''
  # the old program: the 11 files of the versions before 1.0, with the family's settings inside app\config.js
  $pre = Join-Path $root 'programs\pre-1.0'
  foreach ($rel in @('index.html', 'README.txt', 'app/app.js', 'app/genealogy.js', 'app/render.js', 'app/style.css',
      'tools/Update-FamilyTree.ps1', 'tools/Install-FamilyTree.ps1', 'tools/family-tree.ico')) {
    $d = Assert-InTest (Join-Path $pre ($rel.Replace('/', '\')))
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($d))
    [IO.File]::Copy((Join-Path $script:RepoRoot ($rel.Replace('/', '\'))), $d, $true)
  }
  Write-TestFile (Join-Path $pre 'app\config.js') ([IO.File]::ReadAllText((Join-Path $script:RepoRoot 'family-settings.example.js')) + "`n" + [IO.File]::ReadAllText((Join-Path $script:RepoRoot 'app\config.js')))
  [IO.File]::WriteAllText((Join-Path $pre 'Open Family Tree.cmd'), "@echo off`r`nrem Opens the family tree.`r`nstart `"`" /min powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"%~dp0tools\Update-FamilyTree.ps1`" -Open -Quiet`r`n", (New-Object Text.ASCIIEncoding))
  Check (@(Get-ProgramFiles $pre).Count -eq 11) 'the old program has the 11 files of the built-in list'
  $v = New-TestViewer 'pc' $pre $docs -NoSettings
  Write-TestFile (Join-Path $v 'HANDOFF.md') "notes of the people who made this installation`r`n"
  $snap = Get-Snapshot $v
  $newUpdater = Join-Path $r100.Program 'tools\Update-Program.ps1'
  $settingsA = Join-Path $root 'settings-a\family-settings.js'
  Write-TestFile $settingsA ([IO.File]::ReadAllText((Join-Path $script:RepoRoot 'family-settings.example.js')))
  $settingsB = Join-Path $root 'settings-b\family-settings.js'
  Write-TestFile $settingsB "window.FAMILY_SETTINGS = { title: 'Another family' };`n"

  Step 'without -SettingsFrom: refused, nothing changed'
  $r = Invoke-Updater $v @('-InstallZip', $r100.Zip) $newUpdater
  Check ($r.Code -eq 2 -and $r.Result -eq 'settings-missing') 'result settings-missing, exit 2'
  Check ((Get-UpdaterLog $v) -match 'family-settings\.js is missing') 'the log says why'
  $after = Get-Snapshot $v
  $changed = @($snap.Keys | Where-Object { $_ -ne 'data/status.js' -and $_ -ne 'data/update-log.txt' -and $after[$_] -ne $snap[$_] }) + @($after.Keys | Where-Object { -not $snap.ContainsKey($_) })
  Check ($changed.Count -eq 0) "every file is unchanged$(if ($changed.Count) { ' (changed: ' + ($changed -join ', ') + ')' })"
  Check (-not [IO.Directory]::Exists((Join-Path $v 'program-previous'))) 'no program-previous folder'

  Step 'with -SettingsFrom: installed'
  $r = Invoke-Updater $v @('-InstallZip', $r100.Zip, '-SettingsFrom', $settingsA) $newUpdater
  Check ($r.Code -eq 0 -and $r.Result -eq 'installed') 'result installed, exit 0'
  Test-ProgramIs $v $r100.Program 'the program files are exactly those of 1.0.0'
  Check ((Get-FileHashHex (Join-Path $v 'family-settings.js')) -eq (Get-FileHashHex $settingsA)) 'family-settings.js was created from -SettingsFrom'
  Test-ProgramIs (Join-Path $v 'program-previous') $pre 'program-previous holds the 11 old program files'
  $man = [IO.File]::ReadAllText((Join-Path $v 'program-previous\manifest.txt'))
  Check ($man -match '(?m)^list=the built-in list' -and $man -match "(?m)^N`t`ttools/program-files.txt" -and $man -match "(?m)^F`t[0-9a-f]{64}`tapp/config.js") 'the manifest: built-in list, old files saved, new files marked new'
  Check ((Get-StatusText $v) -match '"version":"1\.0\.0"') 'status.js carries 1.0.0'
  $log = Get-UpdaterLog $v
  Check ($log -match 'from the built-in list of the program files from before 1\.0') 'the log names the built-in list'
  if ($log -match 'health before: version from before 1\.0, 7 documents, 6 attached') {
    Check ($log -match 'health after: +version 1\.0\.0, 7 documents, 6 attached') 'the health check measured the old and the new program the same way'
  } else { Check ($log -match 'health before: not measured') 'the health check was skipped (no Chrome)' }
  foreach ($k in @('CLAUDE.md', 'HANDOFF.md', 'my own notes.txt', 'dev/private/secret.txt', 'tools/settings.txt', 'data/keep-me.txt')) {
    Check ((Get-FileHashHex (Join-Path $v ($k.Replace('/', '\')))) -eq $snap[$k]) "$k is unchanged"
  }
  Test-ProtectedSame $snap $v 'first install'

  Step 'going back restores the old program exactly; family-settings.js stays'
  $r = Invoke-Updater $v @('-Rollback')
  Check ($r.Code -eq 0 -and $r.Result -eq 'rolled-back-on-request') 'result rolled-back-on-request, exit 0'
  $after = Get-Snapshot $v
  $changed = @($snap.Keys | Where-Object { $_ -ne 'data/status.js' -and $_ -ne 'data/update-log.txt' -and $after[$_] -ne $snap[$_] })
  $extra = @($after.Keys | Where-Object { -not $snap.ContainsKey($_) })
  Check ($changed.Count -eq 0) "every old file is back, byte for byte$(if ($changed.Count) { ' (different: ' + ($changed -join ', ') + ')' })"
  Check ($extra.Count -eq 1 -and $extra[0] -eq 'family-settings.js') "the only new file is family-settings.js (new: $($extra -join ', '))"
  Check (-not [IO.File]::Exists((Join-Path $v 'app\version.js')) -and -not [IO.File]::Exists((Join-Path $v 'tools\program-files.txt'))) 'the files new in 1.0 are gone'

  Step 'an existing family-settings.js is never replaced'
  $r = Invoke-Updater $v @('-InstallZip', $r100.Zip, '-SettingsFrom', $settingsB, '-Chrome', 'none') $newUpdater
  Check ($r.Code -eq 0 -and $r.Result -eq 'installed') 'installed again (an explicit -InstallZip may install a version that was taken back)'
  Check ((Get-FileHashHex (Join-Path $v 'family-settings.js')) -eq (Get-FileHashHex $settingsA)) 'family-settings.js is still the first one'
  Check ((Get-UpdaterLog $v) -match 'family-settings\.js already exists; it is kept') 'the log says it was kept'
  Test-ProtectedSame $snap $v 'second install'

  $exitCode = Complete-Test 'Test-UpdaterBootstrap'
} catch {
  Write-Host "TEST ERROR: $($_.Exception.Message) $($_.InvocationInfo.PositionMessage)" -ForegroundColor Red
  $exitCode = 1
} finally {
  Remove-TestRoot
}
exit $exitCode
