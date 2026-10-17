@echo off
rem fvim.bat - Backward-compatibility wrapper for fe.bat (Fuzzy Edit)
setlocal
set "SCRIPT_DIR=%~dp0"
call "%SCRIPT_DIR%fe.bat" %*
