@echo off
title Doctor PC
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0DoctorPC.ps1" %*
if errorlevel 1 pause
