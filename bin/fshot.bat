@echo off
rem fshot.bat - Launch fshot.lua via LuaJIT on Windows
setlocal
where luajit >nul 2>nul
if %ERRORLEVEL% equ 0 (
    luajit "%~dp0fshot.lua" %*
    exit /b %ERRORLEVEL%
)
echo [ERROR] luajit is required to run fshot.lua. 1>&2
exit /b 1
