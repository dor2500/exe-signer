@echo off
rem Starts Exe Signer. You can also drag an EXE onto this file.
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0ExeSigner.ps1" "%~1"
