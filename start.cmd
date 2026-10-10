@echo off
rem Start Image Gen MCP (the first time it runs the setup). Double-click it or run it from cmd.
rem Works without changing the PowerShell execution policy. The steps are in scripts\lib.ps1.
rem Kept on one line: cmd reads this file while it runs, and an update can replace it. Pauses when double-clicked or on errors.
rem Delayed expansion is turned on only after PowerShell has run, so a folder name with ! still works.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\imagegen.ps1" start %* & (if errorlevel 1 (pause & exit /b 1)) & setlocal EnableDelayedExpansion & set "cl=!cmdcmdline!" & (if /i not "!cl:%~nx0=!"=="!cl!" pause) & exit /b 0
