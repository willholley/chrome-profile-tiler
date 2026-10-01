@echo off
title Stagehand
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\windows.ps1"
if errorlevel 1 pause
