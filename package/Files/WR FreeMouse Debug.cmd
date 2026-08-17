@echo off
setlocal
title WR FreeMouse - Observation-only Debugger
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0WR FreeMouse Observer.ps1" -MaxMinutes 30
endlocal
