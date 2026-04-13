@echo off
title aiDAPTIVClaw - Building...
setlocal enabledelayedexpansion

:: ============================================
:: aiDAPTIVClaw Post-Install Build Script
:: ============================================

set "APP_DIR=%~1"
set "FROM_INSTALLER="
if "%~2"=="--from-installer" set "FROM_INSTALLER=1"

if "%APP_DIR%"=="" (
    echo [ERROR] Installation directory not provided.
    if not "%FROM_INSTALLER%"=="1" pause
    exit /b 1
)

set "NODE=%APP_DIR%\node.exe"
set "LOG=%APP_DIR%\install.log"

:: Verify install directory exists
if not exist "%APP_DIR%\" (
    echo [ERROR] Installation directory not found: %APP_DIR%
    exit /b 1
)

cd /d "%APP_DIR%"
if errorlevel 1 (
    echo [ERROR] Cannot access directory: %APP_DIR%
    exit /b 1
)

:: Write log header (append if called from installer to preserve diagnostic info)
if "%FROM_INSTALLER%"=="1" (
    echo. >> "%LOG%" 2>&1
    echo ========================================== >> "%LOG%" 2>&1
) else (
    echo ========================================== > "%LOG%" 2>&1
)
echo aiDAPTIVClaw install log >> "%LOG%" 2>&1
echo Started: %DATE% %TIME% >> "%LOG%" 2>&1
echo Install dir: %APP_DIR% >> "%LOG%" 2>&1
echo ========================================== >> "%LOG%" 2>&1

echo.
echo ==========================================
echo   aiDAPTIVClaw - Setting up environment
echo ==========================================
echo.
echo   Install dir: %APP_DIR%
echo   Log file: %LOG%
echo.

:: Skip A2UI canvas bundle - not needed for Gateway + WebUI
set "OPENCLAW_A2UI_SKIP_MISSING=1"

:: Add Git Bash to PATH if available (some build scripts may need it)
where bash >nul 2>&1 || (
    if exist "C:\Program Files\Git\bin\bash.exe" (
        set "PATH=%PATH%;C:\Program Files\Git\bin"
    ) else if exist "C:\Program Files (x86)\Git\bin\bash.exe" (
        set "PATH=%PATH%;C:\Program Files (x86)\Git\bin"
    )
)

:: --- Step 1: Install pnpm ---
echo [1/7] Installing pnpm...
echo [1/7] Installing pnpm... >> "%LOG%" 2>&1

"%NODE%" -e "process.exit(0)" >nul 2>&1
if errorlevel 1 (
    echo [ERROR] Node.js binary is not working. >> "%LOG%" 2>&1
    echo [ERROR] Node.js binary is not working.
    goto :error
)
echo   Node.js: OK >> "%LOG%" 2>&1

:: Try to find pnpm.cmd at known locations (prefer .cmd over bare name for cmd.exe compatibility)
set "PNPM="
if exist "%LOCALAPPDATA%\pnpm\pnpm.cmd" (
    set "PNPM=%LOCALAPPDATA%\pnpm\pnpm.cmd"
)
if "%PNPM%"=="" (
    if exist "%APPDATA%\npm\pnpm.cmd" set "PNPM=%APPDATA%\npm\pnpm.cmd"
)
if "%PNPM%"=="" (
    if exist "%APPDATA%\pnpm\pnpm.cmd" set "PNPM=%APPDATA%\pnpm\pnpm.cmd"
)
:: Search PATH for pnpm.cmd specifically (avoids matching .ps1 only)
if "%PNPM%"=="" (
    for /f "delims=" %%P in ('where pnpm.cmd 2^>nul') do (
        if "!PNPM!"=="" set "PNPM=%%P"
    )
)

:: If not found at known paths, try installing
if "%PNPM%"=="" (
    echo   pnpm not found, installing via PowerShell...
    echo   pnpm not found, installing via PowerShell... >> "%LOG%" 2>&1
    powershell -NoProfile -Command "Invoke-WebRequest https://get.pnpm.io/install.ps1 -UseBasicParsing | Invoke-Expression" >> "%LOG%" 2>&1
    if exist "%LOCALAPPDATA%\pnpm\pnpm.cmd" (
        set "PNPM=%LOCALAPPDATA%\pnpm\pnpm.cmd"
    )
)

if "%PNPM%"=="" (
    echo [ERROR] Failed to find or install pnpm. >> "%LOG%" 2>&1
    echo [ERROR] Failed to find or install pnpm.
    echo   Searched: >> "%LOG%" 2>&1
    echo     %LOCALAPPDATA%\pnpm\pnpm.cmd >> "%LOG%" 2>&1
    echo     %APPDATA%\npm\pnpm.cmd >> "%LOG%" 2>&1
    echo     %APPDATA%\pnpm\pnpm.cmd >> "%LOG%" 2>&1
    goto :error
)

:: Verify pnpm actually works
echo   Found pnpm at: %PNPM% >> "%LOG%" 2>&1
call "%PNPM%" --version >> "%LOG%" 2>&1
if errorlevel 1 (
    echo [ERROR] pnpm found but not working: %PNPM% >> "%LOG%" 2>&1
    echo [ERROR] pnpm found at %PNPM% but cannot execute.
    goto :error
)
echo   pnpm: OK (%PNPM%)
echo   pnpm: OK (%PNPM%) >> "%LOG%" 2>&1
echo.

:: --- Step 2: pnpm install ---
echo [2/7] Installing dependencies (this may take a few minutes)...
echo [2/7] Installing dependencies... >> "%LOG%" 2>&1

:: Clean node_modules from previous installs to avoid corruption
if exist "%APP_DIR%\node_modules" (
    echo   Cleaning previous node_modules...
    echo   Cleaning previous node_modules... >> "%LOG%" 2>&1
    rmdir /s /q "%APP_DIR%\node_modules" 2>nul
)

:: Delete lockfile so pnpm resolves all deps from scratch for this platform.
:: The shipped lockfile was generated on a different OS and does not include
:: Windows-specific optional deps like @esbuild/win32-x64.
if exist "%APP_DIR%\pnpm-lock.yaml" (
    echo   Removing lockfile for fresh platform resolution... >> "%LOG%" 2>&1
    del "%APP_DIR%\pnpm-lock.yaml" 2>nul
)

:: Use hoisted node_modules layout (flat, like npm) instead of pnpm's
:: default symlink-based isolated layout. This avoids Windows symlink/junction
:: issues that cause EUNKNOWN errors and broken cross-package resolution.
findstr /C:"node-linker=hoisted" "%APP_DIR%\.npmrc" >nul 2>&1 || echo node-linker=hoisted>> "%APP_DIR%\.npmrc"
echo   Set node-linker=hoisted in .npmrc >> "%LOG%" 2>&1

:: Use --ignore-scripts so lifecycle failures in non-critical packages
:: (node-llama-cpp, matrix-sdk-crypto) don't abort the entire install.
call "%PNPM%" install --ignore-scripts >> "%LOG%" 2>&1
if errorlevel 1 (
    echo [ERROR] pnpm install failed. See log: %LOG% >> "%LOG%" 2>&1
    echo [ERROR] pnpm install failed. See log: %LOG%
    goto :error
)
echo   Packages installed. >> "%LOG%" 2>&1

:: Rebuild only the native modules that the gateway actually needs.
echo   Building native modules...
echo   Building native modules... >> "%LOG%" 2>&1
call "%PNPM%" rebuild esbuild sharp koffi protobufjs >> "%LOG%" 2>&1
echo   rebuild exit code: %errorlevel% >> "%LOG%" 2>&1

echo   Dependencies installed.
echo   Dependencies installed. >> "%LOG%" 2>&1
echo.

:: --- Step 3: Build core ---
echo [3/7] Building core...
echo [3/7] Building core... >> "%LOG%" 2>&1
echo   Using build:docker - skipping A2UI canvas bundle >> "%LOG%" 2>&1
call "%PNPM%" build:docker >> "%LOG%" 2>&1
if errorlevel 1 (
    echo [ERROR] Build failed. See log: %LOG% >> "%LOG%" 2>&1
    echo [ERROR] Build failed. See log: %LOG%
    goto :error
)
echo   Core build complete.
echo   Core build complete. >> "%LOG%" 2>&1
echo.

:: --- Step 4: Build WebUI ---
echo [4/7] Building WebUI...
echo [4/7] Building WebUI... >> "%LOG%" 2>&1

call "%PNPM%" ui:build >> "%LOG%" 2>&1
if errorlevel 1 (
    echo [ERROR] WebUI build failed. See log: %LOG% >> "%LOG%" 2>&1
    echo [ERROR] WebUI build failed. See log: %LOG%
    goto :error
)
echo   WebUI build complete.
echo   WebUI build complete. >> "%LOG%" 2>&1
echo.

:: --- Step 5: Install hybrid-gateway plugin ---
echo [5/7] Installing hybrid-gateway plugin...
echo [5/7] Installing hybrid-gateway plugin... >> "%LOG%" 2>&1

"%NODE%" "%APP_DIR%\openclaw.mjs" plugins install "%APP_DIR%\extensions\hybrid-gateway" >> "%LOG%" 2>&1
echo   Plugin installed.
echo   Plugin installed. >> "%LOG%" 2>&1
echo.

:: --- Step 6: Link openclaw CLI ---
echo [6/7] Setting up CLI...
echo [6/7] Setting up CLI... >> "%LOG%" 2>&1

call "%PNPM%" link --global >> "%LOG%" 2>&1
echo   CLI ready.
echo   CLI ready. >> "%LOG%" 2>&1
echo.

:: --- Step 7: Configure cloud model provider (interactive, optional) ---
:: When called from Inno Setup, this step is handled by the installer's
:: [Code] section which can reliably create a new console window.
if "%FROM_INSTALLER%"=="1" goto :skip_cloud
echo [7/7] Cloud model provider configuration...
echo [7/7] Cloud model provider configuration... >> "%LOG%" 2>&1
if not exist "%APP_DIR%\configure-cloud.cjs" (
    echo   [WARN] configure-cloud.cjs not found, skipping cloud config.
    echo   [WARN] configure-cloud.cjs not found >> "%LOG%" 2>&1
    goto :skip_cloud
)
echo.
"%NODE%" "%APP_DIR%\configure-cloud.cjs"
echo.
echo   Cloud provider configuration step complete. >> "%LOG%" 2>&1
:skip_cloud

echo ==========================================
echo   Setup complete!
echo ==========================================
echo Setup complete at %DATE% %TIME% >> "%LOG%" 2>&1
echo.
exit /b 0

:error
echo.
echo ==========================================
echo   [ERROR] Setup failed!
echo   Check the log file for details:
echo   %LOG%
echo.
echo   You can retry by running:
echo   "%~f0" "%APP_DIR%"
echo ==========================================
echo FAILED at %DATE% %TIME% >> "%LOG%" 2>&1
echo.
if not "%FROM_INSTALLER%"=="1" (
    pause
)
exit /b 1
