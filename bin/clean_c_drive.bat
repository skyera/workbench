@echo off
where luajit >nul 2>nul
if %errorlevel% equ 0 if exist "%~dp0clean_c_drive.lua" (
    luajit "%~dp0clean_c_drive.lua" %*
    exit /b %errorlevel%
)
echo [ERROR] luajit is required to run clean_c_drive. 1>&2
exit /b 1
