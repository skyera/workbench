@echo off
setlocal
where luajit >nul 2>nul
if errorlevel 1 (
    echo [ERROR] LuaJIT is required to run fremote. Install it and add it to PATH. 1>&2
    exit /b 1
)
luajit "%~dp0fremote.lua" %*
exit /b %ERRORLEVEL%
