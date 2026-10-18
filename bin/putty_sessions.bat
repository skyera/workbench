@echo off
rem putty_sessions.bat - Launch fputty.lua sessions via LuaJIT on Windows
setlocal
where luajit >nul 2>nul
if errorlevel 1 goto missing_luajit

luajit "%~dp0fputty.lua" sessions %*
exit /b %errorlevel%

:missing_luajit
echo [ERROR] luajit is required to run fputty.lua. 1>&2
exit /b 1
