@echo off
rem putty_colors.bat - Launch fputty.lua colors via LuaJIT on Windows
setlocal
where luajit >nul 2>nul
if errorlevel 1 goto missing_luajit

luajit "%~dp0fputty.lua" colors %*
exit /b %errorlevel%

:missing_luajit
echo [ERROR] luajit is required to run fputty.lua. 1>&2
exit /b 1
