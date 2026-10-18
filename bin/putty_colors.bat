@echo off
rem putty_colors.bat - Launch putty.lua colors via LuaJIT on Windows
setlocal
where luajit >nul 2>nul
if errorlevel 1 goto missing_luajit

luajit "%~dp0putty.lua" colors %*
exit /b %errorlevel%

:missing_luajit
echo [ERROR] luajit is required to run putty.lua. 1>&2
exit /b 1
