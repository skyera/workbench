@echo off
rem fkill.bat - Launch fkill.lua via LuaJIT on Windows
setlocal
where luajit >nul 2>nul
if %ERRORLEVEL% equ 0 (
    luajit "%~dp0fkill.lua" %*
    exit /b %ERRORLEVEL%
)
echo [ERROR] luajit is required to run fkill.lua. 1>&2
exit /b 1
