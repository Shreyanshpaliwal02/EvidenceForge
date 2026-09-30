@echo off
rem EvidenceForge task runner wrapper: ef.cmd <command>   (see ef.ps1 help)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0ef.ps1" %*
exit /b %ERRORLEVEL%
