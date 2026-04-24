@echo off
setlocal

REM aiDAPTIVClaw launcher (WSL2 sandbox edition).
REM
REM 0. Verify the install actually completed (.install-complete marker).
REM    Defense in depth: shortcuts are created only on Phase 2 success,
REM    but if a stale .lnk somehow survives a failed install (or a user
REM    copied one over) we still want a friendly error instead of a
REM    cryptic "wsl distro not found" later.
REM 1. Wake the `aidaptivclaw` WSL distro. systemd starts the gateway
REM    automatically (openclaw-gateway.service is enabled in the rootfs).
REM 2. Wait until the gateway responds on localhost:18789. WSL2 default
REM    localhost forwarding bridges Linux loopback to Windows loopback.
REM 3. Ask the gateway for the dashboard URL with auth token.
REM 4. Open it in the user's default browser.
REM
REM Invoked from openclaw-launcher.vbs (so no console window flashes).

set DISTRO=aidaptivclaw
set GATEWAY_URL=http://localhost:18789/
set FALLBACK_URL=http://localhost:18789/
set MARKER=%~dp0.install-complete

REM 0. Install-complete marker check.
if not exist "%MARKER%" (
    powershell -NoProfile -Command "Add-Type -AssemblyName PresentationFramework; [System.Windows.MessageBox]::Show('aiDAPTIVClaw is not fully installed.`n`nThe install-complete marker is missing, which usually means Phase 2 (the OpenClaw build inside WSL) did not finish.`n`nPlease re-run the installer, or open Programs and Features and uninstall + reinstall.`n`nLog: %~dp0install.log', 'aiDAPTIVClaw not ready', 'OK', 'Warning')" >nul 2>&1
    exit /b 1
)

REM 1. Boot the distro (silent no-op command). Triggers systemd if cold.
wsl.exe -d %DISTRO% -u root -e /bin/true >nul 2>&1
if errorlevel 1 (
    echo [aiDAPTIVClaw] WSL distro "%DISTRO%" not found. Reinstall aiDAPTIVClaw.
    timeout /t 10 /nobreak >nul
    exit /b 1
)

REM 2. Wait up to 30 s for gateway port. PowerShell one-liner is faster
REM    than spawning 30 separate curl/Test-NetConnection invocations.
powershell -NoProfile -Command "for ($i=0;$i -lt 30;$i++) { try { $r = Invoke-WebRequest -Uri '%GATEWAY_URL%' -UseBasicParsing -TimeoutSec 2 -ErrorAction Stop; if ($r.StatusCode -lt 500) { exit 0 } } catch { } ; Start-Sleep 1 } ; exit 1"
if errorlevel 1 (
    echo [aiDAPTIVClaw] Gateway failed to start within 30 seconds.
    echo [aiDAPTIVClaw] Diagnose: wsl -d %DISTRO% -u root -e systemctl status openclaw-gateway.service
    timeout /t 10 /nobreak >nul
    exit /b 1
)

REM 3. Get the dashboard URL with embedded auth token. The CLI runs as
REM    the non-root `openclaw` user inside the distro. If --print-url
REM    isn't available (older build), fall back to the bare URL — the
REM    user will be prompted for the token in the browser UI.
for /f "usebackq delims=" %%U in (`wsl.exe -d %DISTRO% -u openclaw -e /opt/node/bin/node /opt/openclaw/openclaw.mjs dashboard --print-url 2^>nul`) do set DASH_URL=%%U
if not defined DASH_URL set DASH_URL=%FALLBACK_URL%

REM 4. Open in the default browser (start "" lets the URL contain "&").
start "" "%DASH_URL%"

endlocal
exit /b 0
