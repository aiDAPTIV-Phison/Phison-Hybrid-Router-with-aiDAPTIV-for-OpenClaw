@echo off
setlocal enableextensions

REM aiDAPTIVClaw launcher (WSL2 sandbox edition, foreground launch model).
REM
REM Launch model (chosen 2026-04-26, see docs/plans/2026-04-23-wsl-sandbox-design.md):
REM   * Gateway is NOT a systemd-enabled service. It is a foreground
REM     process that the user explicitly launches by clicking the
REM     desktop icon and stops with Ctrl-C in the gateway window.
REM   * That matches the native dev experience -- node openclaw.mjs
REM     gateway run -- and gives the user a visible, controllable
REM     terminal session instead of a silent daemon.
REM
REM Steps performed by this script:
REM   0. Verify the install actually completed -- .install-complete marker.
REM   1. Wake the aidaptivclaw WSL distro to fail-fast on a missing
REM      distro -- e.g. user uninstalled but a stale shortcut survived.
REM   2. Probe http://127.0.0.1:18789/ -- if the gateway is already
REM      running -- user clicked the icon a second time -- skip launch
REM      and just open the browser.
REM   3. Otherwise spawn a Windows Terminal tab -- or a conhost window
REM      as fallback -- running wsl -d aidaptivclaw -u openclaw --
REM      /opt/openclaw/run-gateway.sh. That window IS the gateway
REM      session: stdout/stderr stream to it, Ctrl-C stops the gateway,
REM      closing the window stops the gateway.
REM   4. Wait up to 60 s for the gateway to bind 127.0.0.1:18789, then
REM      open the dashboard URL -- with auth token -- in the user's
REM      default browser.
REM
REM IMPORTANT: do NOT inline PowerShell commands that contain literal
REM "(" / ")" inside an "if (...)" parenthesized block. cmd's parser
REM does NOT understand the PowerShell `\"` escape, so each `\"` flips
REM cmd's quote-tracking state -- and once cmd thinks it's outside
REM quotes, embedded "(...)" in our message text gets interpreted as
REM real cmd parens, which prematurely close the surrounding if-block
REM and leave the rest of the message as garbage commands. This bites
REM with errors like "X was unexpected at this time" / "這個時候不應有 X".
REM
REM Workaround: keep the body of conditional branches simple -- ideally
REM just `goto :LABEL_NAME` -- and put the PowerShell dialog calls in
REM top-level labels below, where cmd doesn't have to balance parens.
REM
REM Invoked from openclaw-launcher.vbs.

set "DISTRO=aidaptivclaw"
set "GATEWAY_HOST=127.0.0.1"
set "GATEWAY_PORT=18789"
set "FALLBACK_URL=http://localhost:18789/"
set "APPDIR=%~dp0"
set "MARKER=%APPDIR%.install-complete"
set "INSTALL_LOG=%APPDIR%install.log"
set "LAUNCH_LOG=%APPDIR%launcher.log"

REM ----- 0. Install-complete marker check -------------------------------
if not exist "%MARKER%" goto :MARKER_FAILED

REM ----- 1. Wake the distro (silent no-op) ------------------------------
REM     /bin/true returns immediately so this is a few-hundred-ms cost
REM     on a cold start and a few-ms cost on a warm one.
wsl.exe -d %DISTRO% -u root -e /bin/true >nul 2>&1
if errorlevel 1 goto :DISTRO_MISSING

REM ----- 2. Already running? --------------------------------------------
REM     If the TCP probe succeeds, the gateway is already up (user
REM     clicked icon twice), so skip the launch step and only open
REM     the browser.
call :PROBE_GATEWAY
if not errorlevel 1 goto :ALREADY_RUNNING

REM ----- 3. Spawn a visible terminal running the gateway ----------------
REM     Prefer Windows Terminal (wt.exe) for tabs and proper Ctrl-C
REM     forwarding. Fall back to a plain conhost window on systems
REM     without wt installed.
where wt.exe >nul 2>&1
if errorlevel 1 goto :SPAWN_FALLBACK
start "" wt.exe new-tab --title "aiDAPTIVClaw Gateway" -- wsl.exe -d %DISTRO% -u openclaw --cd /home/openclaw -- /opt/openclaw/run-gateway.sh
goto :WAIT_INIT

:SPAWN_FALLBACK
start "aiDAPTIVClaw Gateway" cmd.exe /c wsl.exe -d %DISTRO% -u openclaw --cd /home/openclaw -- /opt/openclaw/run-gateway.sh
goto :WAIT_INIT

REM ----- 4. Wait for gateway, then open the browser ---------------------
:WAIT_INIT
set /a "__i=0"

:WAIT_LOOP
set /a "__i+=1"
call :PROBE_GATEWAY
if not errorlevel 1 goto :READY
if %__i% GEQ 60 goto :TIMEOUT
timeout /t 1 /nobreak >nul
goto :WAIT_LOOP

:READY
call :OPEN_DASHBOARD
endlocal
exit /b 0

:ALREADY_RUNNING
call :OPEN_DASHBOARD
endlocal
exit /b 0

REM ===== Helper labels =================================================
REM All PowerShell calls live below this point. Because they execute at
REM the top level (not inside any "if (...)" block), embedded parens in
REM the dialog message text do not confuse cmd's parser.

:PROBE_GATEWAY
REM Returns errorlevel 0 if 127.0.0.1:18789 is bound, 1 otherwise.
powershell -NoProfile -Command "try { $c = New-Object System.Net.Sockets.TcpClient; $c.Connect('%GATEWAY_HOST%', %GATEWAY_PORT%); $c.Close(); exit 0 } catch { exit 1 }"
exit /b %errorlevel%

:OPEN_DASHBOARD
set "DASH_URL="
for /f "usebackq delims=" %%U in (`wsl.exe -d %DISTRO% -u openclaw -e /opt/node/bin/node /opt/openclaw/openclaw.mjs dashboard --print-url 2^>nul`) do call :PICK_URL_LINE "%%U"
if not defined DASH_URL set "DASH_URL=%FALLBACK_URL%"
start "" "%DASH_URL%"
goto :EOF

:PICK_URL_LINE
REM Argument %1 is one line of dashboard --print-url output. Keep the
REM last line that looks like an http(s):// URL.
echo %~1 | findstr /r /c:"^https*://" >nul
if not errorlevel 1 set "DASH_URL=%~1"
goto :EOF

:MARKER_FAILED
>"%LAUNCH_LOG%" echo [%DATE% %TIME%] launcher: marker check FAILED
>>"%LAUNCH_LOG%" echo APPDIR  = %APPDIR%
>>"%LAUNCH_LOG%" echo MARKER  = %MARKER%
>>"%LAUNCH_LOG%" echo --- dir of APPDIR ---
dir /b "%APPDIR%" >>"%LAUNCH_LOG%" 2>&1
REM Build the dialog message with a single-quoted PowerShell string. We
REM avoid the `\"` escape entirely: cmd doesn't understand it and
REM mis-tracks quote state. Newlines come from `n inside a PowerShell
REM double-quoted string, which we wrap in single quotes from cmd.
powershell -NoProfile -Command "Add-Type -AssemblyName PresentationFramework; $msg = 'aiDAPTIVClaw is not fully installed.' + [Environment]::NewLine + [Environment]::NewLine + 'The install-complete marker is missing:' + [Environment]::NewLine + '  %MARKER%' + [Environment]::NewLine + [Environment]::NewLine + 'Most likely you double-clicked a leftover shortcut from a previous failed install. Open Apps and Settings, uninstall aiDAPTIVClaw cleanly, then reinstall.' + [Environment]::NewLine + [Environment]::NewLine + 'Diagnostic log: %LAUNCH_LOG%' + [Environment]::NewLine + 'Install log:    %INSTALL_LOG%'; [System.Windows.MessageBox]::Show($msg, 'aiDAPTIVClaw not ready', 'OK', 'Warning') | Out-Null" >nul 2>&1
endlocal
exit /b 1

:DISTRO_MISSING
powershell -NoProfile -Command "Add-Type -AssemblyName PresentationFramework; $msg = 'WSL distro %DISTRO% was not found.' + [Environment]::NewLine + [Environment]::NewLine + 'This usually means aiDAPTIVClaw was uninstalled but a desktop shortcut survived. Please reinstall, or delete this shortcut.'; [System.Windows.MessageBox]::Show($msg, 'aiDAPTIVClaw not ready', 'OK', 'Error') | Out-Null" >nul 2>&1
endlocal
exit /b 1

:TIMEOUT
REM Don't bring down the gateway window if it's still loading; just
REM tell the user where to look. The window itself keeps showing live
REM logs so the user can see what went wrong.
powershell -NoProfile -Command "Add-Type -AssemblyName PresentationFramework; $msg = 'The aiDAPTIVClaw gateway did not respond on port %GATEWAY_PORT% within 60 seconds.' + [Environment]::NewLine + [Environment]::NewLine + 'Check the aiDAPTIVClaw Gateway terminal window for errors. You can close it and click the desktop icon again to retry.'; [System.Windows.MessageBox]::Show($msg, 'aiDAPTIVClaw not ready', 'OK', 'Warning') | Out-Null" >nul 2>&1
endlocal
exit /b 1
