@echo off
rem putty_colors.bat - Launch putty.lua colors via LuaJIT on Windows
setlocal
where luajit >nul 2>nul
if %ERRORLEVEL% equ 0 (
    luajit "%~dp0putty.lua" colors %*
    exit /b %ERRORLEVEL%
)
echo [ERROR] luajit is required to run putty.lua. 1>&2
exit /b 1
