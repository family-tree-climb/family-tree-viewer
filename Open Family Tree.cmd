@echo off
rem Opens the family tree. New and changed life-history documents are read first (only read, never changed).
rem The web page refreshes by itself when the reading is finished.
rem
rem A copy of tools\Update-Program.ps1 is run from the TEMP folder (a program update may replace the original
rem while it runs). It opens the tree, reads the documents exactly as before (tools\Update-FamilyTree.ps1) and,
rem at most once a day, installs a new version of the program if there is one.
rem If that copy cannot be made, or PowerShell cannot run it, the documents are read directly instead, so the
rem tree always opens. (FAMILY_TREE_START_OPTION is only set by the tests; normally the window is /min.)
setlocal
set "FT_VIEWER=%~dp0."
set "FT_READER=%~dp0tools\Update-FamilyTree.ps1"
set "FT_COPY=%TEMP%\FamilyTree-Update-Program-%RANDOM%%RANDOM%.ps1"
set "FT_START=/min"
if defined FAMILY_TREE_START_OPTION set "FT_START=%FAMILY_TREE_START_OPTION%"
if not exist "%~dp0tools\Update-Program.ps1" goto direct
copy /y "%~dp0tools\Update-Program.ps1" "%FT_COPY%" >nul 2>nul
if not exist "%FT_COPY%" goto direct
start "" %FT_START% powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command "$global:FamilyTreeUpdaterStarted = $false; try { & $env:FT_COPY -Viewer $env:FT_VIEWER -Open } catch { }; try { [System.IO.File]::Delete($env:FT_COPY) } catch { }; if (-not $global:FamilyTreeUpdaterStarted) { & $env:FT_READER -Open -Quiet }"
if errorlevel 1 goto direct
goto :eof
:direct
start "" %FT_START% powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%FT_READER%" -Open -Quiet
