@echo off
setlocal
where luajit >nul 2>nul
if errorlevel 1 goto missing_luajit

luajit "%~dp0fputty.lua" %*
exit /b %errorlevel%

:missing_luajit
echo [ERROR] luajit is not installed or not in PATH to run fputty.lua. 1>&2
exit /b 1
