@echo off
cd /d "%~dp0"

:: Start the gateway in a minimized window
start /min "aiDAPTIVClaw Gateway" "%~dp0node.exe" "%~dp0openclaw.mjs" gateway run --port 18789 --bind loopback

:: Wait for the gateway to be ready (up to 30 seconds)
:: Uses a single Node.js process instead of repeated PowerShell invocations for speed
"%~dp0node.exe" -e "const net=require('net');let t=0;const i=setInterval(()=>{const s=new net.Socket();s.setTimeout(500);s.on('connect',()=>{s.destroy();clearInterval(i);process.exit(0)});s.on('error',()=>s.destroy());s.on('timeout',()=>s.destroy());s.connect(18789,'127.0.0.1');t++;if(t>=30){clearInterval(i);process.exit(1)}},1000)"
if errorlevel 1 (
    echo [aiDAPTIVClaw] Gateway failed to start within 30 seconds.
    echo [aiDAPTIVClaw] Port 18789 may already be in use.
    echo [aiDAPTIVClaw] Please check and try again.
    timeout /t 10 /nobreak >nul
    exit /b 1
)

:: Gateway is ready, open the browser with auth token
"%~dp0node.exe" "%~dp0openclaw.mjs" dashboard
