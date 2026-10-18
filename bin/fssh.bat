@echo off
where luajit >nul 2>nul
if %errorlevel% equ 0 if exist "%~dp0fssh.lua" (
    luajit "%~dp0fssh.lua" %*
    exit /b %errorlevel%
)
echo [ERROR] luajit is required to run fssh. 1>&2
exit /b 1
