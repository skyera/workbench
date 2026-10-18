@echo off
rem rfe.bat - Launch rfe.lua via LuaJIT on Windows
setlocal
set "SCRIPT_DIR=%~dp0"
luajit "%SCRIPT_DIR%rfe.lua" %*
