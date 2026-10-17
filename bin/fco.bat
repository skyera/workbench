@echo off
rem fco.bat - Launch fco.lua via LuaJIT on Windows
setlocal
set "SCRIPT_DIR=%~dp0"
luajit "%SCRIPT_DIR%fco.lua" %*
