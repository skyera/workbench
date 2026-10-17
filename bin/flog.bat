@echo off
rem flog.bat - Launch flog.lua via LuaJIT on Windows
setlocal
where luajit >nul 2>nul
if %ERRORLEVEL% equ 0 (
    luajit "%~dp0flog.lua" %*
    exit /b %ERRORLEVEL%
)
echo [ERROR] luajit is required to run flog.lua. 1>&2
exit /b 1
