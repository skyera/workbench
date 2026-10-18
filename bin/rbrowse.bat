@echo off
rem rbrowse.bat - Backward-compatible shim for rfe.lua
setlocal
set "SCRIPT_DIR=%~dp0"
luajit "%SCRIPT_DIR%rfe.lua" %*
