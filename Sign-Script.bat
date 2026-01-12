@echo off
REM Quick launcher for Sign-Script.ps1
REM Right-click this file and select "Run as Administrator"

powershell.exe -ExecutionPolicy Bypass -Command "Start-Process powershell.exe -ArgumentList '-ExecutionPolicy Bypass -File ""%~dp0Sign-Script.ps1""' -Verb RunAs"
