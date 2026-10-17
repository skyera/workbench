@echo off
rem fhist.bat - Launch fhist.lua via LuaJIT on Windows
setlocal
set "SCRIPT_DIR=%~dp0"
luajit "%SCRIPT_DIR%fhist.lua" %*
