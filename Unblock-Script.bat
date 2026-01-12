@echo off
REM Quick launcher for Unblock-Script.ps1
REM Double-click this file to unblock the PowerShell script

powershell.exe -ExecutionPolicy Bypass -File "%~dp0Unblock-Script.ps1"
pause
