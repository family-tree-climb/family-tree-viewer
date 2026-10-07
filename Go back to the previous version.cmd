@echo off
rem Puts back the previous version of the family tree PROGRAM (the copy saved in the "program-previous" folder
rem when the last program update was installed). The life-history documents, the family settings
rem (family-settings.js) and the tree's data are not touched. The version that is taken away is not
rem installed again automatically.
rem It runs a copy of tools\Update-Program.ps1 -Rollback from the TEMP folder; if that does not work, the
rem copy of the previous version's updater (program-previous\tools\Update-Program.ps1) is tried.
rem Going back replaces (or removes) this very file, and cmd.exe reads a batch file line by line while it
rem runs it. So this file first copies itself to the TEMP folder and runs that copy: the original is only
rem read up to the line that starts the copy; that line then ends this file's run with "(goto)" before it
rem deletes the copy, so cmd.exe never looks at the original again.
setlocal
set "FT_VIEWER=%~dp0."
if /i "%~1"=="--from-temp" set "FT_VIEWER=%~2"
if /i "%~1"=="--from-temp" goto run
set "FT_SELF=%TEMP%\FamilyTree-GoBack-%RANDOM%%RANDOM%.cmd"
copy /y "%~f0" "%FT_SELF%" >nul 2>nul
if not exist "%FT_SELF%" goto run
call "%FT_SELF%" --from-temp "%~dp0." & (goto) 2>nul & del "%FT_SELF%" >nul 2>nul
:run
title Family Tree - go back to the previous version
set "FT_COPY=%TEMP%\FamilyTree-Rollback-%RANDOM%%RANDOM%.ps1"
echo Going back to the previous version of the family tree program...
echo.
if not exist "%FT_VIEWER%\tools\Update-Program.ps1" goto older
copy /y "%FT_VIEWER%\tools\Update-Program.ps1" "%FT_COPY%" >nul 2>nul
if not exist "%FT_COPY%" goto older
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%FT_COPY%" -Viewer "%FT_VIEWER%" -Rollback
set "FT_EXIT=%ERRORLEVEL%"
del "%FT_COPY%" >nul 2>nul
if "%FT_EXIT%"=="0" goto done
if "%FT_EXIT%"=="2" goto done
:older
if not exist "%FT_VIEWER%\program-previous\tools\Update-Program.ps1" goto done
echo Trying again with the previous version's own updater...
copy /y "%FT_VIEWER%\program-previous\tools\Update-Program.ps1" "%FT_COPY%" >nul 2>nul
if not exist "%FT_COPY%" goto done
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%FT_COPY%" -Viewer "%FT_VIEWER%" -Rollback
del "%FT_COPY%" >nul 2>nul
:done
echo.
if not defined FAMILY_TREE_NO_PAUSE pause
