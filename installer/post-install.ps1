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
        * Update %USERPROFILE%\.wslconfig (vmIdleTimeout=-1) — applied
          BEFORE provisioning so the build is not killed by idle timeout.
        * wsl --import the bundled Ubuntu 24.04 base rootfs as `aidaptivclaw`.
        * Stage provision.sh / wsl.conf / openclaw-gateway.service /
          openclaw-source.tar.gz into /tmp inside the distro.
        * Run provision.sh as root: apt-installs packages, downloads
          Node.js + pnpm, builds OpenClaw under /opt/openclaw, enables
          the systemd unit. ~15-25 min, REQUIRES INTERNET.
        * wsl --terminate so the next boot picks up the new wsl.conf and
          starts systemd + the gateway.
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

$LogFile      = Join-Path $AppDir "install.log"
# Q2=C online build payload (shipped by openclaw.iss [Files]).
$BaseTarball   = Join-Path $AppDir "rootfs\ubuntu-base.tar.gz"
$SourceTarball = Join-Path $AppDir "rootfs\openclaw-source.tar.gz"
$WslConfFile   = Join-Path $AppDir "rootfs\wsl.conf"
$GatewaySvc    = Join-Path $AppDir "rootfs\openclaw-gateway.service"
$ProvisionSh   = Join-Path $AppDir "rootfs\provision.sh"
$DistroName   = "aidaptivclaw"
$DistroDir    = Join-Path $env:ProgramData "aiDAPTIVClaw\wsl"
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

function Invoke-NativeNoThrow {
    # Run a script block with $ErrorActionPreference temporarily set to
    # 'Continue'. Required for any native-command call that uses `2>&1 | ...`
    # because PowerShell 5.1 wraps native stderr lines as ErrorRecord on
    # the merged success stream, and the script-level $ErrorActionPreference
    # = 'Stop' then elevates them to terminating exceptions BEFORE we get
    # a chance to inspect $LASTEXITCODE. Callers must check $LASTEXITCODE.
    param([Parameter(Mandatory)] [scriptblock]$Block)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $Block
    } finally {
        $ErrorActionPreference = $prev
    }
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
    # WSL2 needs CPU virtualization (VT-x / AMD-V). Detection is brittle:
    # `Win32_Processor.VirtualizationFirmwareEnabled` returns False / $null
    # on many real configurations even when BIOS has it enabled — most
    # commonly when another hypervisor (Hyper-V, HVCI/Memory Integrity,
    # VMware) is already running and the firmware property becomes
    # informational rather than authoritative. We check three signals and
    # accept ANY positive answer; only fail when all three say "no".

    # Signal 1: WMI firmware property (the unreliable one).
    try {
        $cpu = Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1
        if ($cpu -and $cpu.VirtualizationFirmwareEnabled -eq $true) {
            Write-Log "VT detection: Win32_Processor.VirtualizationFirmwareEnabled=True"
            return $true
        }
    } catch { }

    # Signal 2: A hypervisor is already running. Authoritative — nothing
    # can be running atop the CPU without VT-x being enabled at firmware.
    try {
        $sys = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
        if ($sys -and $sys.HypervisorPresent -eq $true) {
            Write-Log "VT detection: HypervisorPresent=True (a hypervisor is already running)"
            return $true
        }
    } catch { }

    # Signal 3: `wsl --status` succeeds. WSL2 itself cannot start without
    # VT-x, so if WSL is operational we know VT-x is on.
    Invoke-NativeNoThrow { & wsl.exe --status 2>&1 | Out-Null }
    if ($LASTEXITCODE -eq 0) {
        Write-Log "VT detection: wsl --status returned 0"
        return $true
    }

    Write-Log "VT detection: all three signals negative (WMI firmware property=False/null, no hypervisor, wsl --status failed)"
    return $false
}

function Test-WindowsVersionOk {
    # Require Win10 22H2 (build 19045) or newer. Earlier builds either
    # lack WSL2 or have known gateway-blocking issues.
    $ver = [Environment]::OSVersion.Version
    if ($ver.Major -lt 10) { return $false }
    if ($ver.Build -lt 19045) { return $false }
    return $true
}

function Test-WslKernelPresent {
    # Lightweight check: `wsl --status` returns 0 once the kernel binaries
    # have been deployed by `wsl --install`. Does NOT prove the VM service
    # can start — that requires Test-VmComputeReady below.
    Invoke-NativeNoThrow { & wsl.exe --status 2>&1 | Out-Null }
    return ($LASTEXITCODE -eq 0)
}

function Test-VmComputeReady {
    # Authoritative check that WSL2 can actually create a VM. The Hyper-V
    # Host Compute Service (`vmcompute`) is the component that backs every
    # WSL2 distro, and `wsl --import` cannot run without it. After a fresh
    # `wsl --install`, the service binaries are on disk but the service
    # cannot start until Windows reboots — the Hyper-V hypervisor must be
    # injected into the boot loader at boot time. Without this check we
    # fall through to Phase 2 too early and `wsl --import` blows up with
    # HCS_E_SERVICE_NOT_AVAILABLE.
    $svc = Get-Service vmcompute -ErrorAction SilentlyContinue
    if (-not $svc) { return $false }
    if ($svc.Status -eq 'Running') { return $true }
    try {
        Start-Service vmcompute -ErrorAction Stop
        return $true
    } catch {
        Write-Log "vmcompute service cannot start (reboot likely required): $($_.Exception.Message)"
        return $false
    }
}

function Test-Wsl2Ready {
    # WSL2 is genuinely usable only when both signals hold.
    if (-not (Test-WslKernelPresent)) { return $false }
    if (-not (Test-VmComputeReady))  { return $false }
    return $true
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

    # 3. WSL2 readiness check — split into two signals so we can distinguish
    #    (a) genuinely ready -> inline-run Phase 2
    #    (b) kernel present but vmcompute not yet runnable (just installed,
    #        not rebooted) -> register RunOnce + ask for reboot
    #    (c) WSL not installed at all -> install + register RunOnce + reboot
    $kernelPresent  = Test-WslKernelPresent
    $vmComputeReady = if ($kernelPresent) { Test-VmComputeReady } else { $false }

    if ($kernelPresent -and $vmComputeReady) {
        Write-Log "WSL2 fully ready -> falling through to Phase 2 (no reboot)"
        Invoke-Phase2
        return
    }

    if ($kernelPresent -and -not $vmComputeReady) {
        # Common case after a manual `wsl --install` that hasn't been
        # followed by a reboot yet. Skip re-installing WSL — just queue
        # Phase 2 to run after the reboot completes.
        Write-Log "WSL kernel present but vmcompute not ready -> reboot required to activate Hyper-V"
        Register-Phase2RunOnce
        Show-InfoDialog "Reboot required" `
            ("WSL2 is installed but Windows must reboot before the " +
             "Hyper-V Host Compute Service (vmcompute) can start.`n`n" +
             "Until that happens, the sandbox VM cannot be created.`n`n" +
             "Click OK, then save your work and reboot. Setup will " +
             "resume automatically after you log back in.")
        Write-Log "RunOnce registered; awaiting reboot."
        exit 2
    }

    # Case (c): WSL not installed — install it, then ask for reboot.
    Write-Log "WSL2 not installed; attempting 'wsl --install --no-distribution'"
    Invoke-NativeNoThrow { & wsl.exe --install --no-distribution 2>&1 | Tee-Object -FilePath $LogFile -Append | Out-Null }
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

    # WSL kernel installed. We MUST reboot before vmcompute can start.
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
#  Phase 2: import base distro, provision online, boot, open browser
# ============================================================

function Update-WslConfig {
    # Patch %USERPROFILE%\.wslconfig idempotently. vmIdleTimeout=-1 keeps
    # the sandbox VM alive across user idle so the gateway stays up — and,
    # critically here, prevents the long-running provision.sh from being
    # killed mid-build if the user walks away from the keyboard.
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
        Invoke-NativeNoThrow { & wsl.exe --shutdown 2>&1 | Out-Null }
    } else {
        Write-Log ".wslconfig already has vmIdleTimeout — leaving it alone"
    }
}

function Invoke-Phase2 {
    Write-Log "Starting Phase 2 (online provision + first boot)"

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
    Invoke-NativeNoThrow { & wsl.exe --set-default-version 2 2>&1 | Out-Null }

    # Validate that every payload file the installer was supposed to ship
    # is actually present. Missing here = installer was tampered with or
    # disk wrote partial data.
    $required = @(
        @{ Name = "Ubuntu base rootfs"; Path = $BaseTarball   },
        @{ Name = "OpenClaw source";    Path = $SourceTarball },
        @{ Name = "wsl.conf";           Path = $WslConfFile   },
        @{ Name = "gateway service";    Path = $GatewaySvc    },
        @{ Name = "provision.sh";       Path = $ProvisionSh   }
    )
    foreach ($r in $required) {
        if (-not (Test-Path $r.Path)) {
            Show-FatalDialog "Missing installer file" `
                ("Required payload file is missing:`n`n" +
                 "  $($r.Name)`n  $($r.Path)`n`n" +
                 "Please reinstall aiDAPTIVClaw.")
            Unregister-Phase2RunOnce
            exit 1
        }
    }
    Write-Log "Payload OK (base $([math]::Round((Get-Item $BaseTarball).Length / 1MB,1)) MB, source $([math]::Round((Get-Item $SourceTarball).Length / 1MB,1)) MB)"

    # Apply .wslconfig BEFORE provisioning so vmIdleTimeout=-1 protects the
    # 15-25 minute build from being killed by idle timeout.
    Update-WslConfig

    # Idempotent import: drop a previously imported distro first so retries
    # don't fail with "distro already exists" or carry over a half-baked
    # state from a previous failed provision.
    $existing = (Invoke-NativeNoThrow { & wsl.exe --list --quiet 2>&1 }) -split "`r?`n" | ForEach-Object { $_.Trim() }
    if ($existing -contains $DistroName) {
        Write-Log "Removing previous '$DistroName' distro..."
        Invoke-NativeNoThrow { & wsl.exe --unregister $DistroName 2>&1 | Out-Null }
    }
    if (-not (Test-Path $DistroDir)) {
        New-Item -ItemType Directory -Path $DistroDir -Force | Out-Null
    }
    Write-Log "Importing Ubuntu 24.04 base rootfs as '$DistroName'..."
    # Capture wsl --import output so we can detect HCS_E_SERVICE_NOT_AVAILABLE
    # — the canonical "WSL was installed but Windows hasn't rebooted yet"
    # signal — and convert it into a graceful reboot prompt instead of a
    # generic "import failed" dead-end.
    $importOutput = Invoke-NativeNoThrow {
        & wsl.exe --import $DistroName $DistroDir $BaseTarball --version 2 2>&1 | Tee-Object -FilePath $LogFile -Append
    } | Out-String
    $importExit = $LASTEXITCODE
    if ($importExit -ne 0) {
        if ($importOutput -match 'HCS_E_SERVICE_NOT_AVAILABLE|vmcompute') {
            Write-Log "wsl --import returned HCS_E_SERVICE_NOT_AVAILABLE -> vmcompute not started, reboot required"
            Register-Phase2RunOnce
            Show-InfoDialog "Reboot required" `
                ("WSL2 cannot create the sandbox VM because the Hyper-V " +
                 "Host Compute Service (vmcompute) is not running.`n`n" +
                 "This usually means Windows installed WSL but has not " +
                 "rebooted yet to activate the hypervisor.`n`n" +
                 "Click OK, then save your work and reboot. Setup will " +
                 "resume automatically after you log back in.")
            exit 2
        }
        Show-FatalDialog "WSL import failed" "wsl --import failed (exit $importExit). See $LogFile for details."
        Unregister-Phase2RunOnce
        exit 1
    }
    Write-Log "Base distro imported"

    # Stage payload into /tmp inside the distro. The base rootfs has the
    # default automount (/mnt/c) enabled, so we can reach $AppDir from
    # inside the distro by translating with `wslpath -u`. Once provision.sh
    # installs our own wsl.conf with automount=enabled=false, /mnt access
    # is gone — but by then the staging is already done.
    Write-Log "Staging payload into distro /tmp/..."
    & wsl.exe -d $DistroName -u root -- mkdir -p /tmp/rootfs-config
    if ($LASTEXITCODE -ne 0) {
        Show-FatalDialog "Distro staging failed" "Failed to mkdir /tmp/rootfs-config inside $DistroName."
        Unregister-Phase2RunOnce
        exit 1
    }

    # Translate Windows paths to WSL paths once — wslpath handles spaces.
    $wslConfP = (& wsl.exe -d $DistroName -u root -- wslpath -u "$WslConfFile").Trim()
    $svcP     = (& wsl.exe -d $DistroName -u root -- wslpath -u "$GatewaySvc").Trim()
    $provP    = (& wsl.exe -d $DistroName -u root -- wslpath -u "$ProvisionSh").Trim()
    $srcP     = (& wsl.exe -d $DistroName -u root -- wslpath -u "$SourceTarball").Trim()

    & wsl.exe -d $DistroName -u root -- cp $wslConfP /tmp/rootfs-config/wsl.conf
    if ($LASTEXITCODE -ne 0) { Show-FatalDialog "Distro staging failed" "cp wsl.conf failed."; Unregister-Phase2RunOnce; exit 1 }
    & wsl.exe -d $DistroName -u root -- cp $svcP /tmp/rootfs-config/openclaw-gateway.service
    if ($LASTEXITCODE -ne 0) { Show-FatalDialog "Distro staging failed" "cp openclaw-gateway.service failed."; Unregister-Phase2RunOnce; exit 1 }
    & wsl.exe -d $DistroName -u root -- cp $provP /tmp/provision.sh
    if ($LASTEXITCODE -ne 0) { Show-FatalDialog "Distro staging failed" "cp provision.sh failed."; Unregister-Phase2RunOnce; exit 1 }
    & wsl.exe -d $DistroName -u root -- cp $srcP /tmp/openclaw-source.tar.gz
    if ($LASTEXITCODE -ne 0) { Show-FatalDialog "Distro staging failed" "cp openclaw-source.tar.gz failed."; Unregister-Phase2RunOnce; exit 1 }

    # If the build machine had core.autocrlf=true at git archive time,
    # text files arrive with CRLF and bash will fail on the shebang. Strip.
    & wsl.exe -d $DistroName -u root -- chmod +x /tmp/provision.sh | Out-Null
    & wsl.exe -d $DistroName -u root -- sed -i 's/\r$//' /tmp/provision.sh /tmp/rootfs-config/wsl.conf /tmp/rootfs-config/openclaw-gateway.service | Out-Null

    # Run provision.sh as root inside the distro. This is the long step:
    #   apt update + install (5-10 min, depends on mirror)
    #   download Node.js + pnpm tarballs (~1 min)
    #   pnpm install + rebuild + build:docker + ui:build (5-15 min)
    # All output is teed to the install log so the user has a trail.
    Write-Log "Running provision.sh inside distro (15-25 min, downloads packages + builds OpenClaw)..."
    Invoke-NativeNoThrow { & wsl.exe -d $DistroName -u root -- /tmp/provision.sh 2>&1 | Tee-Object -FilePath $LogFile -Append }
    if ($LASTEXITCODE -ne 0) {
        Show-FatalDialog "Provisioning failed" `
            ("OpenClaw provisioning inside WSL failed (exit $LASTEXITCODE).`n`n" +
             "Common causes:`n" +
             "  - No / unstable internet connection (apt, nodejs.org, github.com)`n" +
             "  - Out of disk space on the system drive`n" +
             "  - Corporate proxy blocks apt or npm registry`n`n" +
             "Diagnose with:`n" +
             "  wsl -d $DistroName -u root`n`n" +
             "Then re-run from PowerShell after fixing the underlying issue:`n" +
             "  powershell -File `"$AppDir\post-install.ps1`" -AppDir `"$AppDir`" -Phase 2`n`n" +
             "See $LogFile for the full provisioning log.")
        Unregister-Phase2RunOnce
        exit 1
    }
    Write-Log "Provisioning complete"

    # provision.sh installed /etc/wsl.conf with [boot] systemd=true and
    # enabled the gateway unit, but the distro is currently running WITHOUT
    # systemd (wsl.conf is read at boot, not hot-reloaded). Terminate so
    # the next invocation cold-boots with systemd PID 1.
    Write-Log "Restarting distro to activate systemd + gateway service..."
    Invoke-NativeNoThrow { & wsl.exe --terminate $DistroName 2>&1 | Out-Null }

    # First "real" boot: systemd PID 1 starts openclaw-gateway.service via
    # its WantedBy=multi-user.target hook.
    Invoke-NativeNoThrow { & wsl.exe -d $DistroName -u root -e /bin/true 2>&1 | Out-Null }
    Start-Sleep -Seconds 5

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
