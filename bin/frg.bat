@echo off
setlocal enabledelayedexpansion

:: 0. Prefer LuaJIT TUI if available
where luajit >nul 2>nul
if !errorlevel! equ 0 (
    luajit "%~dp0frg.lua" %*
    exit /b !errorlevel!
)

:: 1. Determine editor (prefer %EDITOR%, then %VISUAL%, then nvim, then vim)
set "TARGET_EDITOR=%EDITOR%"
if "%TARGET_EDITOR%"=="" set "TARGET_EDITOR=%VISUAL%"
if "%TARGET_EDITOR%"=="" (
    where nvim >nul 2>nul
    if !errorlevel! equ 0 (
        set "TARGET_EDITOR=nvim"
    ) else (
        set "TARGET_EDITOR=vim"
    )
)

:: 2. Get search pattern from argument or prompt if empty
set "PATTERN=%~1"
if "%PATTERN%"=="" (
    set /p "PATTERN=Search pattern: "
)
if "%PATTERN%"=="" goto :end

:: 3. Setup temporary file for fzf output
set "TMP_OUT=%TEMP%\frg_res_%RANDOM%.txt"

:: 4. Run ripgrep + fzf
rg --color=always --smart-case --line-number --no-heading "%PATTERN%" | fzf --ansi -m --delimiter : --preview "bat --color=always --highlight-line {2} {1} 2>nul || type {1}" --preview-window=right:60%% > "%TMP_OUT%"

if not exist "%TMP_OUT%" goto :end
for %%A in ("%TMP_OUT%") do if %%~zA equ 0 (
    del "%TMP_OUT%"
    goto :end
)

:: 5. Count selected lines
set /a COUNT=0
for /f "usebackq delims=" %%L in ("%TMP_OUT%") do (
    set /a COUNT+=1
)

:: 6. Handle single vs multi selection
if %COUNT% equ 1 (
    for /f "usebackq tokens=1,2 delims=:" %%A in ("%TMP_OUT%") do (
        set "SELECTED_FILE=%%A"
        set "SELECTED_LINE=%%B"
    )
    del "%TMP_OUT%"
    if not "!SELECTED_FILE!"=="" (
        "%TARGET_EDITOR%" "+!SELECTED_LINE!" "!SELECTED_FILE!"
    )
    goto :end
)

:: Multi-selection handling (deduplicate file paths)
set "TMP_LIST=%TEMP%\frg_files_%RANDOM%.txt"
if exist "%TMP_LIST%" del "%TMP_LIST%"

for /f "usebackq tokens=1 delims=:" %%A in ("%TMP_OUT%") do (
    findstr /x /c:"%%A" "%TMP_LIST%" >nul 2>&1
    if !errorlevel! neq 0 (
        echo %%A>>"%TMP_LIST%"
    )
)

set "FILE_ARGS="
for /f "usebackq delims=" %%F in ("%TMP_LIST%") do (
    set "FILE_ARGS=!FILE_ARGS! "%%F""
)

del "%TMP_OUT%" 2>nul
del "%TMP_LIST%" 2>nul

if not "!FILE_ARGS!"=="" (
    "%TARGET_EDITOR%" -p !FILE_ARGS!
)

:end
endlocal
