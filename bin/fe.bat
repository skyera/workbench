@echo off
rem fe.bat - Launch fe.lua via LuaJIT on Windows
setlocal
set "SCRIPT_DIR=%~dp0"
luajit "%SCRIPT_DIR%fe.lua" %*
