@echo off
rem fbr.bat - Launch fbr.lua via LuaJIT on Windows
setlocal
set "SCRIPT_DIR=%~dp0"
luajit "%SCRIPT_DIR%fbr.lua" %*
