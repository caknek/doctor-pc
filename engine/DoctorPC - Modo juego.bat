@echo off
title Doctor PC - Modo juego
cd /d "%~dp0"
echo Abre tu juego cuando Doctor PC lo indique y juega con normalidad durante 2 minutos.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0DoctorPC.ps1" -ModoJuego 120 %*
if errorlevel 1 pause
