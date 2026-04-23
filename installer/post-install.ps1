<#
.SYNOPSIS
    aiDAPTIVClaw target-machine post-install / WSL provisioning.

.DESCRIPTION
    Dual-phase script invoked by Inno Setup [Code] (Phase 1) and by
    Windows RunOnce on the next user login (Phase 2).

      Phase 1 (called from Inno Setup):
        * Verify Windows version, virtualization, WSL.
        * If WSL missing: install it, register HKCU RunOnce for Phase 2,
          ask user to reboot. Exits with code 2.
        * If WSL OK: short-circuit straight into Phase 2 in the same
          process (no reboot needed).

      Phase 2 (called after reboot via RunOnce, OR rerun by the user):
        * wsl --import the bundled rootfs as the `aidaptivclaw` distro.
        * Configure %USERPROFILE%\.wslconfig (vmIdleTimeout=-1).
        * Boot the distro (systemd auto-starts the gateway).
        * Wait for the gateway HTTP endpoint, open the browser.
        * Cleanup the RunOnce entry.

    Exit codes (consumed by openclaw.iss [Code]):
        0  success — Phase 1 went through to Phase 2 inline, all good
        2  reboot required — Phase 1 installed WSL, RunOnce registered
        3  prerequisites unmet — VT-x off, unsupported Windows, etc.
        1  any other failure — see install.log

.PARAMETER AppDir
    Directory where the installer placed files (Inno Setup {app}).
.PARAMETER Phase
    1 (default, called from installer) or 2 (called via RunOnce).
.PARAMETER FromInstaller
    Set when invoked from Inno Setup [Code]; suppresses interactive
    "press Enter to exit" prompts.
#>
param(
    [Parameter(Mandatory=$true)] [string]$AppDir,
    [ValidateSet('1','2')] [string]$Phase = '1',
    [switch]$FromInstaller
)

$ErrorActionPreference = "Stop"

$LogFile     = Join-Path $AppDir "install.log"
$Tarball     = Join-Path $AppDir "rootfs\aidaptivclaw.tar.gz"
$DistroName  = "aidaptivclaw"
$DistroDir   = Join-Path $env:ProgramData "aiDAPTIVClaw\wsl"
$RunOnceKey  = "HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce"
$RunOnceName = "aiDAPTIVClawPostInstall"
# Update this URL when the docs are published. Phase 1/2 dialogs link here
# for self-service troubleshooting.
$DocsUrl     = "https://github.com/openclaw/openclaw/blob/main/docs/install/windows.md"

function Write-Log {
    param([string]$Message)
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts] [Phase$Phase] $Message"
    Write-Host $line
    try { Add-Content -Path $LogFile -Value $line } catch { }
}

function Show-FatalDialog {
    param([string]$Title, [string]$Body)
    try {
        Add-Type -AssemblyName PresentationFramework -ErrorAction Stop
        [System.Windows.MessageBox]::Show($Body, $Title, 'OK', 'Error') | Out-Null
    } catch {
        # WPF unavailable; fall back to console output (still in install.log).
        Write-Log "DIALOG: $Title -- $Body"
    }
}

function Show-InfoDialog {
    param([string]$Title, [string]$Body)
    try {
        Add-Type -AssemblyName PresentationFramework -ErrorAction Stop
        [System.Windows.MessageBox]::Show($Body, $Title, 'OK', 'Information') | Out-Null
    } catch {
        Write-Log "INFO: $Title -- $Body"
    }
}

function Test-VirtualizationEnabled {
    # Returns $true if CPU virtualization (VT-x / AMD-V) is enabled at
    # firmware level. WSL2 cannot run without this.
    try {
        $cpu = Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1
        return [bool]$cpu.VirtualizationFirmwareEnabled
    } catch {
        return $false
    }
}

function Test-WindowsVersionOk {
    # Require Win10 22H2 (build 19045) or newer. Earlier builds either
    # lack WSL2 or have known gateway-blocking issues.
    $ver = [Environment]::OSVersion.Version
    if ($ver.Major -lt 10) { return $false }
    if ($ver.Build -lt 19045) { return $false }
    return $true
}

function Test-Wsl2Ready {
    & wsl.exe --status 2>&1 | Out-Null
    return ($LASTEXITCODE -eq 0)
}

function Register-Phase2RunOnce {
    # HKCU RunOnce: fires once on the next interactive logon for THIS
    # user, then auto-deletes. Same mechanism Visual Studio Installer,
    # Office, and Docker Desktop use.
    $cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$AppDir\post-install.ps1`" -AppDir `"$AppDir`" -Phase 2"
    if (-not (Test-Path $RunOnceKey)) {
        New-Item -Path $RunOnceKey -Force | Out-Null
    }
    Set-ItemProperty -Path $RunOnceKey -Name $RunOnceName -Value $cmd
    Write-Log "Registered HKCU RunOnce: $RunOnceName"
}

function Unregister-Phase2RunOnce {
    if (Test-Path $RunOnceKey) {
        Remove-ItemProperty -Path $RunOnceKey -Name $RunOnceName -ErrorAction SilentlyContinue
    }
}

function Show-Win11MirroredHint {
    # Win11 22H2+ supports networkingMode=mirrored which gives better
    # bidirectional localhost behavior. Optional; default localhost
    # forwarding works fine for our use case.
    $winBuild = 0
    try {
        $winBuild = [int](Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" CurrentBuildNumber).CurrentBuildNumber
    } catch { return }
    if ($winBuild -lt 22621) { return }

    Write-Log ""
    Write-Log "TIP: You are on Windows 11 22H2 or later. For better networking performance,"
    Write-Log "     consider enabling WSL mirrored networking by adding this to %USERPROFILE%\.wslconfig:"
    Write-Log ""
    Write-Log "       [wsl2]"
    Write-Log "       networkingMode=mirrored"
    Write-Log ""
    Write-Log "     Then run 'wsl --shutdown' to apply. (Optional; localhost forwarding works either way.)"
}

# ============================================================
#  Phase 1: prerequisites + maybe-install-WSL + maybe-reboot
# ============================================================
function Invoke-Phase1 {
    Write-Log "Starting Phase 1 (prerequisite checks + WSL install if needed)"

    # 1. Windows version gate
    if (-not (Test-WindowsVersionOk)) {
        Show-FatalDialog "Unsupported Windows" `
            ("aiDAPTIVClaw requires Windows 10 22H2 (build 19045) or Windows 11.`n`n" +
             "Detected: $([Environment]::OSVersion.Version)`n`n" +
             "Please update Windows and run the installer again.")
        Write-Log "ERROR: Unsupported Windows version: $([Environment]::OSVersion.Version)"
        exit 3
    }

    # 2. CPU virtualization gate (no API can fix this — must be done in BIOS)
    if (-not (Test-VirtualizationEnabled)) {
        Show-FatalDialog "Virtualization not enabled" `
            ("aiDAPTIVClaw requires CPU virtualization (Intel VT-x or AMD-V) to be enabled in BIOS.`n`n" +
             "Please reboot, enter BIOS/UEFI setup, and enable:`n" +
             "  - Intel CPU: 'Intel Virtualization Technology' or 'VT-x'`n" +
             "  - AMD CPU:  'SVM Mode' or 'AMD-V'`n`n" +
             "Then run the installer again.`n`n" +
             "Step-by-step instructions: $DocsUrl#bios")
        Write-Log "ERROR: CPU virtualization is disabled at firmware level"
        exit 3
    }
    Write-Log "Virtualization OK"

    # 3. WSL2 check
    if (Test-Wsl2Ready) {
        Write-Log "WSL2 already installed -> falling through to Phase 2 (no reboot)"
        Invoke-Phase2
        return
    }

    Write-Log "WSL2 not installed; attempting 'wsl --install --no-distribution'"
    & wsl.exe --install --no-distribution 2>&1 | Tee-Object -FilePath $LogFile -Append | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Show-FatalDialog "WSL install failed" `
            ("Automatic WSL installation failed (exit $LASTEXITCODE).`n`n" +
             "Common causes:`n" +
             "  - No internet connection`n" +
             "  - Group Policy blocks Windows Optional Features`n" +
             "  - Antivirus blocks the WSL kernel installer`n`n" +
             "Manual fix: open Administrator PowerShell and run:`n`n" +
             "  wsl --install --no-distribution`n`n" +
             "Then reboot Windows and run this installer again.`n`n" +
             "Detailed troubleshooting: $DocsUrl#wsl-install-failed")
        Write-Log "ERROR: 'wsl --install' failed (exit $LASTEXITCODE)"
        exit 1
    }

    # WSL kernel installed. We MUST reboot before `wsl --import` can run.
    Register-Phase2RunOnce

    Show-InfoDialog "Reboot required" `
        ("WSL2 has been installed.`n`n" +
         "Windows must reboot to activate it. Setup will resume " +
         "automatically after you log back in.`n`n" +
         "Click OK, then save your work and reboot.")

    Write-Log "WSL installed; reboot required. RunOnce registered."
    exit 2
}

# ============================================================
#  Phase 2: import distro, boot it, open browser
# ============================================================
function Invoke-Phase2 {
    Write-Log "Starting Phase 2 (WSL import + first boot)"

    # Defensive re-check: handles user disabling VT-x between phases.
    if (-not (Test-VirtualizationEnabled)) {
        Show-FatalDialog "Virtualization disabled" `
            ("CPU virtualization is no longer enabled.`n`n" +
             "Please re-enable it in BIOS and re-run the installer.`n`n" +
             "Instructions: $DocsUrl#bios")
        Unregister-Phase2RunOnce
        exit 3
    }
    if (-not (Test-Wsl2Ready)) {
        Show-FatalDialog "WSL not ready" `
            ("WSL2 is still not available.`n`n" +
             "Open Administrator PowerShell, run 'wsl --install --no-distribution', then reboot.")
        Unregister-Phase2RunOnce
        exit 3
    }

    # Set WSL default version (no-op if already 2).
    & wsl.exe --set-default-version 2 2>&1 | Out-Null

    # Tarball check
    if (-not (Test-Path $Tarball)) {
        Show-FatalDialog "Missing rootfs" "Rootfs file not found: $Tarball"
        Unregister-Phase2RunOnce
        exit 1
    }
    $tarballMb = [math]::Round((Get-Item $Tarball).Length / 1MB, 1)
    Write-Log "Tarball OK ($tarballMb MB)"

    # Idempotent import: drop a previously imported distro first so retries
    # don't fail with "distro already exists".
    $existing = (& wsl.exe --list --quiet 2>&1) -split "`r?`n" | ForEach-Object { $_.Trim() }
    if ($existing -contains $DistroName) {
        Write-Log "Removing previous '$DistroName' distro..."
        & wsl.exe --unregister $DistroName 2>&1 | Out-Null
    }
    if (-not (Test-Path $DistroDir)) {
        New-Item -ItemType Directory -Path $DistroDir -Force | Out-Null
    }
    & wsl.exe --import $DistroName $DistroDir $Tarball --version 2 2>&1 | Tee-Object -FilePath $LogFile -Append
    if ($LASTEXITCODE -ne 0) {
        Show-FatalDialog "WSL import failed" "wsl --import failed. See $LogFile for details."
        Unregister-Phase2RunOnce
        exit 1
    }
    Write-Log "Distro imported"

    # Patch %USERPROFILE%\.wslconfig idempotently. vmIdleTimeout=-1 keeps
    # the sandbox VM alive across user idle so the gateway stays up.
    $wslConfigPath = Join-Path $env:USERPROFILE ".wslconfig"
    $wslConfigContent = if (Test-Path $wslConfigPath) {
        Get-Content $wslConfigPath -Raw
    } else { "" }
    if ($wslConfigContent -notmatch "(?ms)^\[wsl2\][^\[]*vmIdleTimeout") {
        if ($wslConfigContent.Length -gt 0 -and -not $wslConfigContent.EndsWith("`n")) {
            $wslConfigContent += "`r`n"
        }
        $wslConfigContent += "`r`n# Added by aiDAPTIVClaw installer: keep sandbox VM alive.`r`n[wsl2]`r`nvmIdleTimeout=-1`r`n"
        Set-Content -Path $wslConfigPath -Value $wslConfigContent -Encoding UTF8
        Write-Log ".wslconfig updated"
        # Apply the new config so the next wsl invocation picks it up.
        & wsl.exe --shutdown 2>&1 | Out-Null
    }

    # First boot: systemd auto-starts openclaw-gateway.service because the
    # rootfs was systemctl-enabled at provision time.
    & wsl.exe -d $DistroName -u root -e /bin/true 2>&1 | Out-Null
    Start-Sleep -Seconds 3

    # Wait for the gateway HTTP endpoint to respond on Windows-side
    # localhost (WSL2 default localhost forwarding bridges 127.0.0.1).
    $ready = $false
    for ($i = 0; $i -lt 30; $i++) {
        try {
            $resp = Invoke-WebRequest -Uri "http://localhost:18789/" -UseBasicParsing -TimeoutSec 2 -ErrorAction Stop
            if ($resp.StatusCode -lt 500) { $ready = $true; break }
        } catch { }
        Start-Sleep -Seconds 1
    }
    if (-not $ready) {
        Write-Log "WARN: gateway did not respond within 30s"
        Show-FatalDialog "Gateway didn't start" `
            ("The OpenClaw gateway did not respond on http://localhost:18789 within 30 seconds.`n`n" +
             "Diagnose with:`n" +
             "  wsl -d $DistroName -u root -e systemctl status openclaw-gateway.service`n" +
             "  wsl -d $DistroName -u root -e journalctl -u openclaw-gateway.service -n 100`n`n" +
             "See $LogFile for installer logs.")
        Unregister-Phase2RunOnce
        exit 1
    }
    Write-Log "Gateway responding on http://localhost:18789"

    # Ask the gateway for the dashboard URL (with auth token). Falls back
    # to the bare URL if the CLI doesn't support --print-url for any reason.
    $dashUrl = ""
    try {
        $dashUrl = (& wsl.exe -d $DistroName -u openclaw -e /opt/node/bin/node /opt/openclaw/openclaw.mjs dashboard --print-url 2>$null)
    } catch { }
    if ([string]::IsNullOrWhiteSpace($dashUrl)) {
        $dashUrl = "http://localhost:18789/"
    }
    Start-Process $dashUrl.Trim()

    Show-Win11MirroredHint
    Unregister-Phase2RunOnce
    Write-Log "Phase 2 complete"
    exit 0
}

# ============================================================
#  Entry
# ============================================================
try {
    if (-not (Test-Path $AppDir)) { throw "AppDir does not exist: $AppDir" }
    # Ensure log file exists; appended to throughout the run.
    if (-not (Test-Path $LogFile)) {
        New-Item -ItemType File -Path $LogFile -Force | Out-Null
    }

    if ($Phase -eq '1') {
        Invoke-Phase1
    } else {
        Invoke-Phase2
    }
} catch {
    Write-Log "FATAL: $_"
    Show-FatalDialog "aiDAPTIVClaw setup error" "$_`n`nSee $LogFile for details."
    exit 1
}
