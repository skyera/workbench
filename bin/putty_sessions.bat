@echo off
rem putty_sessions.bat - Launch putty.lua sessions via LuaJIT on Windows
setlocal
where luajit >nul 2>nul
if %ERRORLEVEL% equ 0 (
    luajit "%~dp0putty.lua" sessions %*
    exit /b %ERRORLEVEL%
)
echo [ERROR] luajit is required to run putty.lua. 1>&2
exit /b 1
