@echo off
rem fnet.bat - Launch fnet.lua via LuaJIT on Windows
setlocal
where luajit >nul 2>nul
if %ERRORLEVEL% equ 0 (
    luajit "%~dp0fnet.lua" %*
    exit /b %ERRORLEVEL%
)
echo [ERROR] luajit is required to run fnet.lua. 1>&2
exit /b 1
