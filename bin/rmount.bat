@echo off
setlocal enabledelayedexpansion

set "SCRIPT_NAME=%~nx0"

if "%~1"=="" goto :show_help
if /i "%~1"=="-h" goto :show_help
if /i "%~1"=="--help" goto :show_help
if /i "%~1"=="/h" goto :show_help
if /i "%~1"=="/?" goto :show_help

:: Unmount mode
if /i "%~1"=="-u" goto :do_unmount
if /i "%~1"=="--unmount" goto :do_unmount
if /i "%~1"=="/u" goto :do_unmount

:: Parse authentication flags
set "AUTH_MODE=auto"
set "PERSISTENT=no"

:parse_flags
if /i "%~1"=="-p" (
    set "AUTH_MODE=password"
    shift
    goto :parse_flags
)
if /i "%~1"=="--password" (
    set "AUTH_MODE=password"
    shift
    goto :parse_flags
)
if /i "%~1"=="/p" (
    set "AUTH_MODE=password"
    shift
    goto :parse_flags
)
if /i "%~1"=="-k" (
    set "AUTH_MODE=key"
    shift
    goto :parse_flags
)
if /i "%~1"=="--key" (
    set "AUTH_MODE=key"
    shift
    goto :parse_flags
)
if /i "%~1"=="/k" (
    set "AUTH_MODE=key"
    shift
    goto :parse_flags
)
if /i "%~1"=="-s" (
    set "PERSISTENT=yes"
    shift
    goto :parse_flags
)
if /i "%~1"=="--persistent" (
    set "PERSISTENT=yes"
    shift
    goto :parse_flags
)
if /i "%~1"=="/s" (
    set "PERSISTENT=yes"
    shift
    goto :parse_flags
)

:: Mount mode
if "%~2"=="" (
    echo Error: Missing local drive letter. >&2
    echo Run '%SCRIPT_NAME% --help' for usage. >&2
    exit /b 1
)

set "REMOTE_HOST=%~1"
if "%~3"=="" (
    set "REMOTE_DIR="
    set "DRIVE=%~2"
) else (
    set "REMOTE_DIR=%~2"
    set "DRIVE=%~3"
)

:: Normalize drive letter (strip trailing backslash, slash, colon; keep first character followed by colon)
set "DRIVE=%DRIVE:\=%"
set "DRIVE=%DRIVE:/=%"
set "DRIVE=%DRIVE::=%"
set "DRIVE=%DRIVE:~0,1%:"

:: Check if drive is already in use
if exist "%DRIVE%\" (
    echo Notice: Drive '%DRIVE%' is already in use.
    exit /b 0
)

:: Ensure SSHFS-Win has an id_rsa key to load for key-based authentication
if not "%AUTH_MODE%"=="password" (
    if not exist "%USERPROFILE%\.ssh\id_rsa" (
        if exist "%USERPROFILE%\.ssh\id_ed25519" (
            cmd /c mklink /H "%USERPROFILE%\.ssh\id_rsa" "%USERPROFILE%\.ssh\id_ed25519" >nul 2>&1
            if exist "%USERPROFILE%\.ssh\id_ed25519.pub" (
                cmd /c mklink /H "%USERPROFILE%\.ssh\id_rsa.pub" "%USERPROFILE%\.ssh\id_ed25519.pub" >nul 2>&1
            )
        ) else if exist "%USERPROFILE%\.ssh\id_ecdsa" (
            cmd /c mklink /H "%USERPROFILE%\.ssh\id_rsa" "%USERPROFILE%\.ssh\id_ecdsa" >nul 2>&1
            if exist "%USERPROFILE%\.ssh\id_ecdsa.pub" (
                cmd /c mklink /H "%USERPROFILE%\.ssh\id_rsa.pub" "%USERPROFILE%\.ssh\id_ecdsa.pub" >nul 2>&1
            )
        )
    )
)

:: Construct UNC paths for SSHFS-Win
if not "%REMOTE_DIR%"=="" (
    set "NORM_DIR=%REMOTE_DIR:/=\%"
    if "!NORM_DIR:~0,1!"=="\" set "NORM_DIR=!NORM_DIR:~1!"
    set "DISPLAY_DIR=%REMOTE_DIR%"
    set "KEY_UNC=\\sshfs.kr\%REMOTE_HOST%\!NORM_DIR!"
    set "PWD_UNC=\\sshfs.r\%REMOTE_HOST%\!NORM_DIR!"
) else (
    set "DISPLAY_DIR=remote HOME"
    set "KEY_UNC=\\sshfs.k\%REMOTE_HOST%"
    set "PWD_UNC=\\sshfs\%REMOTE_HOST%"
)

set "TEMP_LOG=%TEMP%\rmount_%RANDOM%.log"

if "%AUTH_MODE%"=="password" goto :try_password

:try_key
echo Mounting %REMOTE_HOST% (!DISPLAY_DIR!) to %DRIVE%...
net use %DRIVE% "%KEY_UNC%" /persistent:!PERSISTENT! >"%TEMP_LOG%" 2>&1
if !errorlevel! equ 0 (
    if exist "%TEMP_LOG%" del "%TEMP_LOG%"
    echo Successfully mounted to %DRIVE%
    exit /b 0
)

if "%AUTH_MODE%"=="key" (
    echo Error: Failed to mount to %DRIVE% using SSH key authentication. >&2
    if exist "%TEMP_LOG%" (
        type "%TEMP_LOG%"
        del "%TEMP_LOG%"
    )
    goto :check_install
)

:: If auto mode, fall back to password auth
echo Key authentication failed. Attempting password authentication...
if exist "%TEMP_LOG%" del "%TEMP_LOG%"

:try_password
echo Mounting %REMOTE_HOST% (!DISPLAY_DIR!) to %DRIVE%...
net use %DRIVE% "%PWD_UNC%" /persistent:!PERSISTENT!
if !errorlevel! equ 0 (
    echo Successfully mounted to %DRIVE%
    exit /b 0
) else (
    echo Error: Failed to mount to %DRIVE%. >&2
    goto :check_install
)

:check_install
set "SSHFS_INSTALLED=0"
if exist "%ProgramFiles%\SSHFS-Win\bin\sshfs.exe" set "SSHFS_INSTALLED=1"
if exist "%ProgramFiles(x86)%\SSHFS-Win\bin\sshfs.exe" set "SSHFS_INSTALLED=1"
if "!SSHFS_INSTALLED!"=="0" (
    echo.
    echo Please verify WinFsp and SSHFS-Win are installed:
    echo   winget install WinFsp.WinFsp
    echo   winget install SSHFS-Win.SSHFS-Win
)
exit /b 1

:do_unmount
if "%~2"=="" (
    echo Error: Missing drive letter to unmount. >&2
    echo Run '%SCRIPT_NAME% --help' for usage. >&2
    exit /b 1
)
set "U_DRIVE=%~2"
set "U_DRIVE=%U_DRIVE:\=%"
set "U_DRIVE=%U_DRIVE:/=%"
set "U_DRIVE=%U_DRIVE::=%"
set "U_DRIVE=%U_DRIVE:~0,1%:"

if not exist "%U_DRIVE%\" (
    echo Notice: '%U_DRIVE%' is not currently mounted.
    exit /b 0
)

echo Unmounting %U_DRIVE%...
net use %U_DRIVE% /delete /y >nul 2>&1
if !errorlevel! equ 0 (
    echo Successfully unmounted %U_DRIVE%.
) else (
    echo Error: Failed to unmount %U_DRIVE%. >&2
    exit /b 1
)
exit /b 0

:show_help
echo Usage:
echo   %SCRIPT_NAME% [-p ^| -k] [-s] ^<user@host^> [^<remote_dir^>] ^<Drive:^>
echo   %SCRIPT_NAME% -u ^<Drive:^>
echo   %SCRIPT_NAME% -h ^| --help
echo.
echo Description:
echo   Mount a remote directory locally via SSHFS-Win, or unmount an existing mount.
echo   If ^<remote_dir^> is omitted, it defaults to the remote user's home directory.
echo   By default, attempts SSH key authentication and falls back to password if needed.
echo.
echo Arguments:
echo   ^<user@host^>     Remote SSH target (e.g., user@server.com or SSH config host)
echo   ^<remote_dir^>    Optional path on remote host to mount (defaults to remote home)
echo   ^<Drive:^>        Local drive letter to mount into (e.g., Z: or Z)
echo.
echo Options:
echo   -k, --key       Force SSH key authentication only
echo   -p, --password  Force password authentication
echo   -s, --persistent Persist mount across logons and reboots
echo   -u, --unmount   Unmount the specified local drive
echo   -h, --help      Display this help message and exit
echo.
echo Examples:
echo   # Mount remote home directory to Z: (uses SSH key by default):
echo   %SCRIPT_NAME% user@remote-box Z:
echo.
echo   # Mount persistently across reboots:
echo   %SCRIPT_NAME% -s user@remote-box Z:
echo.
echo   # Mount specific remote directory to Y:
echo   %SCRIPT_NAME% user@remote-box /var/www Y:
echo.
echo   # Force password authentication:
echo   %SCRIPT_NAME% -p user@remote-box /var/www Y:
echo.
echo   # Mount with custom port:
echo   %SCRIPT_NAME% user^^!2222@remote-box /var/www Y:
echo.
echo   # Unmount drive:
echo   %SCRIPT_NAME% -u Z:
exit /b 0
