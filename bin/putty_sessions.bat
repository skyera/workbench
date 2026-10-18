@echo off
rem putty_sessions.bat - Launch putty.lua sessions via LuaJIT on Windows
setlocal
where luajit >nul 2>nul
if errorlevel 1 goto missing_luajit

luajit "%~dp0putty.lua" sessions %*
exit /b %errorlevel%

:missing_luajit
echo [ERROR] luajit is required to run putty.lua. 1>&2
exit /b 1
