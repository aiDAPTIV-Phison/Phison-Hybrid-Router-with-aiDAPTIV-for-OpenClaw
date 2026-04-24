<#
.SYNOPSIS
    aiDAPTIVClaw target-machine post-install / WSL provisioning.

.DESCRIPTION
    Dual-phase script invoked by Inno Setup [Code] (Phase 1) and by a
    Scheduled Task at the next user logon (Phase 2).

      Phase 1 (called from Inno Setup):
        * Verify Windows version, virtualization, WSL.
        * If WSL missing OR vmcompute pending reboot: install/skip,
          register a Scheduled Task to resume Phase 2 with elevated
          privileges at next logon, ask user to reboot. Exits with code 2.
        * If WSL fully ready: short-circuit straight into Phase 2 in the
          same (already-elevated) process (no reboot needed).

      Phase 2 (called after reboot via Scheduled Task, OR rerun by the user):
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
        * Cleanup the Scheduled Task.

    Exit codes (consumed by openclaw.iss [Code]):
        0  success — Phase 1 went through to Phase 2 inline, all good
        2  reboot required — Phase 1 installed WSL, resume task registered
        3  prerequisites unmet — VT-x off, unsupported Windows, etc.
        1  any other failure — see install.log

.PARAMETER AppDir
    Directory where the installer placed files (Inno Setup {app}).
.PARAMETER Phase
    1 (default, called from installer) or 2 (called via the resume task).
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
$ResumeTaskName = "aiDAPTIVClawPhase2Resume"
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

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Register-Phase2RunOnce {
    # Schedule Phase 2 to auto-resume after the next interactive logon.
    #
    # We DELIBERATELY do NOT use HKCU\RunOnce here. RunOnce-launched
    # processes inherit the user's standard token even when the user is
    # in the Administrators group — there is no UAC consent prompt and
    # no automatic elevation. Phase 2 needs admin (Start-Service vmcompute,
    # wsl --import to ProgramData, etc.) so a RunOnce-launched Phase 2
    # immediately fails Test-VmComputeReady with ACCESS_DENIED on
    # OpenService and dead-ends with "WSL not ready".
    #
    # Scheduled Task with -RunLevel Highest, in contrast, gives admin
    # users the elevated token at logon WITHOUT a UAC prompt. This is
    # the documented mechanism for "silent" elevated auto-resume after
    # reboot (used by Windows Update, Visual Studio Installer, etc.).
    $action  = New-ScheduledTaskAction -Execute "powershell.exe" `
        -Argument ("-NoProfile -ExecutionPolicy Bypass -File `"$AppDir\post-install.ps1`" -AppDir `"$AppDir`" -Phase 2")
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME `
        -LogonType Interactive -RunLevel Highest
    # StartWhenAvailable: if the trigger fires while Task Scheduler is
    # busy (or the user logs on before TS is ready), run as soon as
    # possible afterwards. Battery flags: don't refuse to run on laptops.
    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
    Register-ScheduledTask -TaskName $ResumeTaskName `
        -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
    Write-Log "Registered scheduled task: $ResumeTaskName (RunLevel=Highest, AtLogOn user=$env:USERNAME)"
}

function Unregister-Phase2RunOnce {
    # Remove the scheduled task. Also clean up any HKCU RunOnce entry
    # left behind by older installer versions for forward compatibility.
    if (Get-ScheduledTask -TaskName $ResumeTaskName -ErrorAction SilentlyContinue) {
        try {
            Unregister-ScheduledTask -TaskName $ResumeTaskName -Confirm:$false -ErrorAction Stop
            Write-Log "Unregistered scheduled task: $ResumeTaskName"
        } catch {
            Write-Log "Failed to unregister scheduled task: $($_.Exception.Message)"
        }
    }
    if (Test-Path $RunOnceKey) {
        Remove-ItemProperty -Path $RunOnceKey -Name $RunOnceName -ErrorAction SilentlyContinue
    }
}

function Set-WslMirroredNetworking {
    # Force WSL2 networkingMode=mirrored when the host supports it
    # (Windows 11 22H2+, build >= 22621). Mirrored mode replaces the
    # default NAT'd vEthernet adapter with a "the WSL VM looks just like
    # the Windows host" model:
    #   - Linux can bind localhost and Windows clients see it without
    #     the WSL2 localhost forwarding hack (which has known races
    #     when the gateway starts before the WSL service finishes
    #     registering the port mapping).
    #   - IPv6 works.
    #   - Outbound traffic uses the host's interface directly, so VPN /
    #     corporate proxy / firewall rules apply consistently to Linux
    #     and Windows.
    #
    # We persist this in %USERPROFILE%\.wslconfig (the per-user config
    # WSL2 reads at VM start). The merge below preserves any existing
    # settings the user already had — we only inject networkingMode if
    # it is missing, and we never overwrite a user's explicit non-mirrored
    # choice (we just log it).
    #
    # Idempotent — safe to call on every Phase 2 run.
    $winBuild = 0
    try {
        $winBuild = [int](Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" CurrentBuildNumber).CurrentBuildNumber
    } catch {
        Write-Log "Cannot read Windows build number; skipping mirrored networking setup"
        return
    }
    if ($winBuild -lt 22621) {
        Write-Log "Windows build $winBuild < 22621; mirrored networking unsupported, falling back to default NAT"
        return
    }

    $wslconfigPath = Join-Path $env:USERPROFILE ".wslconfig"
    $lines = @()
    if (Test-Path $wslconfigPath) {
        # -Encoding Default lets PowerShell auto-detect (BOM-aware). The
        # file is a tiny INI; encoding mismatches would lose user data.
        $lines = @(Get-Content -LiteralPath $wslconfigPath -Encoding UTF8)
    }

    # Locate [wsl2] section, networkingMode key within it.
    $wsl2Start = -1   # index of '[wsl2]' line
    $wsl2End   = -1   # index of next '[...]' line (exclusive end of section)
    $netModeAt = -1   # index of 'networkingMode=...' line within [wsl2]
    $netModeVal = ""

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $t = $lines[$i].Trim()
        if ($t -match '^\[(.+?)\]\s*$') {
            $section = $matches[1].Trim().ToLower()
            if ($section -eq 'wsl2' -and $wsl2Start -lt 0) {
                $wsl2Start = $i
            } elseif ($wsl2Start -ge 0 -and $wsl2End -lt 0) {
                $wsl2End = $i
                break
            }
        } elseif ($wsl2Start -ge 0 -and $wsl2End -lt 0) {
            if ($t -match '^\s*networkingMode\s*=\s*(.*?)\s*$') {
                $netModeAt = $i
                $netModeVal = $matches[1].Trim().ToLower()
            }
        }
    }
    if ($wsl2Start -ge 0 -and $wsl2End -lt 0) { $wsl2End = $lines.Count }

    if ($netModeAt -ge 0) {
        if ($netModeVal -eq 'mirrored') {
            Write-Log "WSL .wslconfig already has networkingMode=mirrored — no change"
            return
        }
        # User has an explicit non-mirrored setting; respect it. Some users
        # need NAT for legacy bridge tooling — overwriting silently would
        # break them. Log loudly so the install log records the decision.
        Write-Log "WARN: $wslconfigPath has networkingMode=$netModeVal (not mirrored). Leaving it alone."
        Write-Log "WARN: aiDAPTIVClaw works either way, but mirrored mode is recommended on Win11 22H2+."
        Write-Log "WARN: To switch later: edit $wslconfigPath and set [wsl2] networkingMode=mirrored, then 'wsl --shutdown'."
        return
    }

    # Need to add the key. Three sub-cases:
    #   (a) no .wslconfig at all -> create it with full [wsl2] section
    #   (b) [wsl2] section exists but no networkingMode -> insert at end of section
    #   (c) no [wsl2] section -> append [wsl2] section at end of file
    if ($lines.Count -eq 0) {
        $newContent = @(
            '# Auto-generated by aiDAPTIVClaw installer.'
            '# Mirrored networking lets the WSL2 VM share the host''s network'
            '# stack so localhost / IPv6 / VPN routes "just work".'
            '[wsl2]'
            'networkingMode=mirrored'
            ''
        )
        Set-Content -LiteralPath $wslconfigPath -Value $newContent -Encoding UTF8
        Write-Log "Created $wslconfigPath with networkingMode=mirrored"
        Invoke-NativeNoThrow { & wsl.exe --shutdown 2>&1 | Out-Null }
        return
    }

    if ($wsl2Start -ge 0) {
        # Insert before $wsl2End (start of next section, or end of file).
        # Trim trailing blank lines inside the section so the new key sits
        # next to the existing keys rather than after empty space.
        $insertAt = $wsl2End
        while ($insertAt -gt $wsl2Start + 1 -and [string]::IsNullOrWhiteSpace($lines[$insertAt - 1])) {
            $insertAt--
        }
        $head = if ($insertAt -gt 0) { $lines[0..($insertAt - 1)] } else { @() }
        $tail = if ($insertAt -lt $lines.Count) { $lines[$insertAt..($lines.Count - 1)] } else { @() }
        $merged = @($head) + @('networkingMode=mirrored') + @($tail)
        Set-Content -LiteralPath $wslconfigPath -Value $merged -Encoding UTF8
        Write-Log "Added networkingMode=mirrored under existing [wsl2] section in $wslconfigPath"
        Invoke-NativeNoThrow { & wsl.exe --shutdown 2>&1 | Out-Null }
        return
    }

    # No [wsl2] at all — append a fresh section.
    $merged = @($lines) + @('', '[wsl2]', 'networkingMode=mirrored', '')
    Set-Content -LiteralPath $wslconfigPath -Value $merged -Encoding UTF8
    Write-Log "Appended [wsl2] networkingMode=mirrored section to $wslconfigPath"
    Invoke-NativeNoThrow { & wsl.exe --shutdown 2>&1 | Out-Null }
}

function Read-InstallOptions {
    # Read the install-options.ini that openclaw.iss [Code] writes before
    # invoking Phase 1. Provides the user's task selections (desktop /
    # Start Menu shortcut), resolved Windows paths so Phase 2 can build
    # the same shortcuts the wizard would have built, AND the user's
    # cloud-provider selection (id, baseUrl, api, model, apiKey) which
    # Phase 2 patches into openclaw.json. Falls back to safe defaults
    # if the file is missing (e.g. user ran post-install.ps1 by hand
    # for retry) — in that case the cloud section is empty and Phase 2
    # leaves the template's defaults untouched.
    #
    # Section format (mirror of openclaw.iss WriteInstallOptions):
    #   [install]    : appName / appDir / launcherPath / iconPath / startMenuGroup / userDesktop
    #   [shortcuts]  : desktop=0|1, startMenu=0|1
    #   [provider]   : id, baseUrl, api, model, apiKey
    $iniPath = Join-Path $AppDir "install-options.ini"
    $opts = @{
        AppName         = "aiDAPTIVClaw"
        AppDir          = $AppDir
        LauncherPath    = Join-Path $AppDir "openclaw-launcher.vbs"
        IconPath        = Join-Path $AppDir "Gemini_Generated_Image_aiDAPTIV.ico"
        StartMenuGroup  = Join-Path ([Environment]::GetFolderPath('Programs')) "aiDAPTIVClaw"
        UserDesktop     = [Environment]::GetFolderPath('Desktop')
        Desktop         = $true
        StartMenu       = $true
        ProviderId      = ''
        ProviderBaseUrl = ''
        ProviderApi     = ''
        ProviderModel   = ''
        ProviderApiKey  = ''
    }
    if (-not (Test-Path $iniPath)) {
        Write-Log "install-options.ini not found at $iniPath -- using defaults (both shortcuts, no cloud key)"
        return $opts
    }
    foreach ($line in Get-Content $iniPath -Encoding UTF8) {
        $line = $line.Trim()
        if (-not $line -or $line.StartsWith(';') -or $line.StartsWith('[')) { continue }
        $eq = $line.IndexOf('=')
        if ($eq -lt 1) { continue }
        $k = $line.Substring(0, $eq).Trim()
        $v = $line.Substring($eq + 1).Trim()
        switch ($k) {
            'appName'        { $opts.AppName         = $v }
            'appDir'         { $opts.AppDir          = $v }
            'launcherPath'   { $opts.LauncherPath    = $v }
            'iconPath'       { $opts.IconPath        = $v }
            'startMenuGroup' { $opts.StartMenuGroup  = $v }
            'userDesktop'    { $opts.UserDesktop     = $v }
            'desktop'        { $opts.Desktop         = ($v -eq '1') }
            'startMenu'      { $opts.StartMenu       = ($v -eq '1') }
            'id'             { $opts.ProviderId      = $v }
            'baseUrl'        { $opts.ProviderBaseUrl = $v }
            'api'            { $opts.ProviderApi     = $v }
            'model'          { $opts.ProviderModel   = $v }
            'apiKey'         { $opts.ProviderApiKey  = $v }
        }
    }
    $keyChars = $opts.ProviderApiKey.Length
    Write-Log ("Loaded install-options.ini (desktop=$($opts.Desktop), startMenu=$($opts.StartMenu), " +
               "provider='$($opts.ProviderId)', model='$($opts.ProviderModel)', apiKey=$keyChars chars)")
    return $opts
}

function New-Lnk {
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [string]$Target,
        [string]$IconPath,
        [string]$WorkingDir,
        [string]$Description = ""
    )
    $shell = New-Object -ComObject WScript.Shell
    $lnk   = $shell.CreateShortcut($Path)
    $lnk.TargetPath       = $Target
    if ($IconPath)   { $lnk.IconLocation     = $IconPath }
    if ($WorkingDir) { $lnk.WorkingDirectory = $WorkingDir }
    if ($Description){ $lnk.Description      = $Description }
    $lnk.Save()
}

function New-LauncherShortcuts {
    # Create user-facing launcher shortcuts. Called only after the
    # gateway has confirmed responding -- we treat shortcut creation
    # as the "install is truly usable" signal so users never see an
    # icon for a half-baked install they would just double-click and
    # get a cryptic error from.
    $opts = Read-InstallOptions
    if ($opts.Desktop) {
        $lnkPath = Join-Path $opts.UserDesktop "$($opts.AppName).lnk"
        try {
            New-Lnk -Path $lnkPath -Target $opts.LauncherPath `
                    -IconPath $opts.IconPath -WorkingDir $opts.AppDir `
                    -Description "Launch $($opts.AppName)"
            Write-Log "Created desktop shortcut: $lnkPath"
        } catch {
            Write-Log "WARN: failed to create desktop shortcut: $($_.Exception.Message)"
        }
    }
    if ($opts.StartMenu) {
        if (-not (Test-Path $opts.StartMenuGroup)) {
            New-Item -ItemType Directory -Path $opts.StartMenuGroup -Force | Out-Null
        }
        $lnkPath = Join-Path $opts.StartMenuGroup "$($opts.AppName).lnk"
        try {
            New-Lnk -Path $lnkPath -Target $opts.LauncherPath `
                    -IconPath $opts.IconPath -WorkingDir $opts.AppDir `
                    -Description "Launch $($opts.AppName)"
            Write-Log "Created Start Menu shortcut: $lnkPath"
        } catch {
            Write-Log "WARN: failed to create Start Menu shortcut: $($_.Exception.Message)"
        }
    }
}

function Write-InstallCompleteMarker {
    # Marker file consumed by openclaw-launcher.cmd as a defensive sanity
    # check — if the marker is missing, the launcher refuses to run and
    # tells the user the install is incomplete. Belt-and-suspenders on
    # top of the "no shortcut without success" invariant: catches the
    # case where a user manually copied a shortcut from somewhere else.
    $markerPath = Join-Path $AppDir ".install-complete"
    $payload    = "Installed at: $(Get-Date -Format 'yyyy/MM/dd HH:mm:ss')`r`n"
    Set-Content -Path $markerPath -Value $payload -Encoding UTF8
    Write-Log "Wrote install-complete marker: $markerPath"
}

# ============================================================
#  Cloud provider config (Phase 2): wizard CloudPage -> openclaw.json
#
#  The Inno Setup wizard collected (provider id, baseUrl, api, model,
#  apiKey) on its CloudPage and persisted them via WriteInstallOptions
#  into install-options.ini's [provider] section. Phase 2 reads them
#  here, patches openclaw-template.json into a final openclaw.json,
#  and writes it to:
#
#    1. %USERPROFILE%\.openclaw\openclaw.json   (Windows host backward-compat)
#    2. /home/openclaw/.openclaw/openclaw.json  (the WSL gateway's actual config)
#
#  The two files are written from the same in-memory object so they
#  cannot drift. Three patch sites mirror what the original
#  configure-cloud.cjs did, plus a third patch (agents.defaults) that
#  the legacy script forgot — without it, picking e.g. Anthropic
#  silently still routes the agent's primary model through OpenRouter.
# ============================================================

function Set-JsonProperty {
    # In-place add-or-replace a property on a PSCustomObject. Add-Member
    # -Force handles both new properties and overwriting existing ones,
    # which lets the patch logic stay symmetric for "provider already
    # in template" (openrouter) vs "new provider" (anthropic, etc.).
    param(
        [Parameter(Mandatory)] $Object,
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] $Value
    )
    $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
}

function Build-OpenClawConfig {
    # Read the template, apply 3 patches, return the in-memory object.
    # Caller is responsible for serialising and writing it to disk.
    param(
        [Parameter(Mandatory)] [string]$TemplatePath,
        [Parameter(Mandatory)] [hashtable]$Provider
    )
    if (-not (Test-Path $TemplatePath)) {
        throw "openclaw-template.json missing at $TemplatePath"
    }
    $tpl = Get-Content -LiteralPath $TemplatePath -Raw -Encoding UTF8 | ConvertFrom-Json

    $id      = $Provider.ProviderId
    $baseUrl = $Provider.ProviderBaseUrl
    $api     = $Provider.ProviderApi
    $model   = $Provider.ProviderModel
    $apiKey  = $Provider.ProviderApiKey

    # Patch 1: insert / update models.providers.<id>. Preserve any pre-
    # existing fields under the same provider key (e.g. an existing
    # `models: []` array), otherwise default to an empty array — matches
    # the original configure-cloud.cjs spread-then-overwrite semantics.
    $providers = $tpl.models.providers
    $merged = [ordered]@{}
    if ($providers.PSObject.Properties[$id]) {
        foreach ($p in $providers.$id.PSObject.Properties) {
            $merged[$p.Name] = $p.Value
        }
    }
    $merged['baseUrl'] = $baseUrl
    $merged['apiKey']  = $apiKey
    $merged['api']     = $api
    if (-not $merged.Contains('models')) { $merged['models'] = @() }
    Set-JsonProperty -Object $providers -Name $id -Value ([pscustomobject]$merged)

    # Patch 2: point hybrid-gateway's cloud tier at the chosen provider.
    # This is the path the legacy configure-cloud.cjs already touched.
    $cloudCfg = [pscustomobject][ordered]@{
        provider = $id
        model    = $model
    }
    Set-JsonProperty -Object $tpl.plugins.entries.'hybrid-gateway'.config.models `
                     -Name 'cloud' -Value $cloudCfg

    # Patch 3 (NEW vs. legacy script): also retarget the agents' primary
    # model. Without this, choosing e.g. Anthropic on the wizard would
    # leave agents.defaults.model.primary still pointing at
    # `openrouter/google/gemini-3.1-flash-lite-preview`, defeating the
    # whole point of letting the user pick a provider.
    Set-JsonProperty -Object $tpl.agents.defaults.model `
                     -Name 'primary' -Value "$id/$model"

    return $tpl
}

function Convert-ConfigToJson {
    # Centralise the depth setting — openclaw.json nests up to ~6 levels
    # under plugins.entries.hybrid-gateway.config.routing.skillRoutes[].
    # PowerShell's ConvertTo-Json defaults to depth 2 and silently
    # serialises deeper nodes as System.Object[] strings. Lock to 32.
    param([Parameter(Mandatory)] $Object)
    return ($Object | ConvertTo-Json -Depth 32)
}

function Write-WindowsHostConfig {
    # Windows-side copy under %USERPROFILE%\.openclaw\openclaw.json. Kept
    # purely for backward-compat with any future Windows-side CLI/GUI
    # tool — the gateway running inside WSL does NOT read this. Failure
    # to write is a warning, not a fatal: gateway operation does not
    # depend on this file.
    param(
        [Parameter(Mandatory)] [string]$Json,
        [Parameter(Mandatory)] [string]$UserProfile
    )
    try {
        $configDir  = Join-Path $UserProfile ".openclaw"
        $configPath = Join-Path $configDir "openclaw.json"
        if (-not (Test-Path $configDir)) {
            New-Item -ItemType Directory -Path $configDir -Force | Out-Null
        }
        # -NoNewline: ConvertTo-Json doesn't emit a trailing newline, and
        # Set-Content default would add CRLF — keep the file LF-clean.
        Set-Content -LiteralPath $configPath -Value $Json -Encoding UTF8 -NoNewline
        Write-Log "Wrote Windows host config: $configPath ($(($Json).Length) bytes)"
    } catch {
        Write-Log "WARN: failed to write Windows host config: $($_.Exception.Message)"
    }
}

function Push-WslGuestConfig {
    # The actual file the WSL gateway reads. Strategy: stage to
    # %TEMP%\openclaw-config-<guid>.json, translate the path with
    # `wslpath`, then `install` it as openclaw:openclaw mode 0640 in
    # one atomic step (no race where the file briefly exists with
    # wrong owner / mode). Failure is FATAL — without this file the
    # gateway will boot with no API key and any LLM call fails.
    param(
        [Parameter(Mandatory)] [string]$Json,
        [Parameter(Mandatory)] [string]$Distro
    )
    $hostTmp = Join-Path $env:TEMP ("openclaw-config-{0}.json" -f ([Guid]::NewGuid().ToString('N')))
    try {
        Set-Content -LiteralPath $hostTmp -Value $Json -Encoding UTF8 -NoNewline

        # Convert C:\Users\...\AppData\Local\Temp\foo.json -> /mnt/c/...
        # so the in-WSL `install` command can read it.
        $wslSrc = (& wsl.exe -d $Distro -- wslpath -u $hostTmp 2>$null).Trim()
        if (-not $wslSrc) {
            throw "wslpath returned empty for $hostTmp"
        }

        & wsl.exe -d $Distro -u root -- bash -c (
            "install -m 0640 -o openclaw -g openclaw " +
            "'$wslSrc' /home/openclaw/.openclaw/openclaw.json"
        ) 2>&1 | Tee-Object -FilePath $LogFile -Append | Out-Null

        if ($LASTEXITCODE -ne 0) {
            throw "wsl install command failed with exit $LASTEXITCODE"
        }
        Write-Log "Wrote WSL guest config: /home/openclaw/.openclaw/openclaw.json ($(($Json).Length) bytes, mode 0640, owner openclaw)"
    } finally {
        # Always wipe the host-side temp copy — it briefly held the
        # apiKey in plain text under %TEMP%, where corp DLP scanners
        # love to find such strings.
        if (Test-Path $hostTmp) {
            Remove-Item -LiteralPath $hostTmp -Force -ErrorAction SilentlyContinue
        }
    }
}

function Apply-CloudProviderConfig {
    # Phase 2 entry point: call after provision.sh has succeeded (so
    # /home/openclaw/.openclaw/ exists and is owned by the openclaw
    # user) and BEFORE `wsl --terminate`, so when systemd cold-boots
    # the gateway service the config is already in place.
    param(
        [Parameter(Mandatory)] [string]$Distro,
        [Parameter(Mandatory)] [hashtable]$Options
    )
    $templatePath = Join-Path $AppDir "openclaw-template.json"
    $userProfile  = $env:USERPROFILE

    if ([string]::IsNullOrWhiteSpace($Options.ProviderApiKey)) {
        # No-key path: still ship a valid openclaw.json so the gateway
        # boots without errors; user can fill in the key later via the
        # OpenClaw web UI. Use the template as-is (no patching).
        Write-Log "No cloud apiKey provided; writing unpatched template to host + WSL"
        $json = Get-Content -LiteralPath $templatePath -Raw -Encoding UTF8
        Write-WindowsHostConfig -Json $json -UserProfile $userProfile
        Push-WslGuestConfig    -Json $json -Distro $Distro
        return
    }

    # Sanity-check provider id (defensive: install-options.ini could be
    # tampered with between Phase 1 write and Phase 2 read). Unknown id
    # falls back to skip-patch behaviour, which is preferable to
    # writing a malformed openclaw.json that breaks gateway startup.
    $known = @('openrouter', 'google', 'anthropic', 'openai', 'together')
    if ($known -notcontains $Options.ProviderId) {
        Write-Log "WARN: unknown provider id '$($Options.ProviderId)'; writing unpatched template"
        $json = Get-Content -LiteralPath $templatePath -Raw -Encoding UTF8
        Write-WindowsHostConfig -Json $json -UserProfile $userProfile
        Push-WslGuestConfig    -Json $json -Distro $Distro
        return
    }

    Write-Log "Patching openclaw.json for provider=$($Options.ProviderId), model=$($Options.ProviderModel)"
    $cfg  = Build-OpenClawConfig -TemplatePath $templatePath -Provider $Options
    $json = Convert-ConfigToJson -Object $cfg
    Write-WindowsHostConfig -Json $json -UserProfile $userProfile
    Push-WslGuestConfig    -Json $json -Distro $Distro
}

function Remove-InstallOptionsSecrets {
    # Strip the [provider] section (which contains the apiKey in plain
    # text) from install-options.ini AFTER it has been consumed. We
    # keep the [install] and [shortcuts] sections so subsequent re-runs
    # (e.g. user manually invokes Phase 2 to retry) still know where
    # the launcher / icon / startMenu live. The apiKey itself only
    # exists on disk thereafter inside the WSL guest config (mode
    # 0640, owner openclaw) and the host backward-compat copy.
    $iniPath = Join-Path $AppDir "install-options.ini"
    if (-not (Test-Path $iniPath)) { return }
    try {
        $kept = New-Object System.Collections.Generic.List[string]
        $inProvider = $false
        foreach ($line in Get-Content -LiteralPath $iniPath -Encoding UTF8) {
            $trimmed = $line.Trim()
            if ($trimmed.StartsWith('[')) {
                $inProvider = ($trimmed -ieq '[provider]')
                if (-not $inProvider) { $kept.Add($line) }
                continue
            }
            if (-not $inProvider) { $kept.Add($line) }
        }
        Set-Content -LiteralPath $iniPath -Value $kept -Encoding UTF8
        Write-Log "Stripped [provider] section from install-options.ini (apiKey wiped from disk)"
    } catch {
        Write-Log "WARN: failed to strip [provider] from install-options.ini: $($_.Exception.Message)"
    }
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
             "resume automatically after you log back in (Phase 2: " +
             "downloads packages + builds OpenClaw, ~15-30 min).`n`n" +
             "To monitor live progress after reboot, open PowerShell:`n" +
             "  Get-Content `"$LogFile`" -Wait -Tail 50")
        Write-Log "Resume task registered; awaiting reboot."
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
         "automatically after you log back in (Phase 2: downloads " +
         "packages + builds OpenClaw, ~15-30 min).`n`n" +
         "Click OK, then save your work and reboot.`n`n" +
         "To monitor live progress after reboot, open PowerShell:`n" +
         "  Get-Content `"$LogFile`" -Wait -Tail 50")
    Write-Log "WSL installed; reboot required. Resume task registered."
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

    # User-visible banner. When Phase 2 is launched by the resume task
    # after a reboot, the user sees a PowerShell window pop up out of
    # nowhere — make sure they immediately understand WHAT it is, HOW
    # LONG it takes, and HOW TO MONITOR it without staring at a blank
    # screen for 25 minutes.
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "  aiDAPTIVClaw Phase 2: WSL Sandbox Provisioning" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  This window will:" -ForegroundColor Yellow
    Write-Host "    1. Import a vanilla Ubuntu 24.04 base into WSL"
    Write-Host "    2. apt-install build dependencies"
    Write-Host "    3. Download Node.js + pnpm"
    Write-Host "    4. Build OpenClaw (~15-30 minutes total)"
    Write-Host "    5. Open your browser to the dashboard when done"
    Write-Host ""
    Write-Host "  Do not close this window until you see your browser open." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Live progress is also written to:" -ForegroundColor Gray
    Write-Host "    $LogFile" -ForegroundColor Gray
    Write-Host "  To tail it from another shell:" -ForegroundColor Gray
    Write-Host "    Get-Content `"$LogFile`" -Wait -Tail 50" -ForegroundColor Gray
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host ""

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

    # Apply .wslconfig BEFORE provisioning so:
    #   - vmIdleTimeout=-1 protects the 15-25 minute build from being killed
    #     by the WSL2 idle timeout.
    #   - networkingMode=mirrored (Win11 22H2+) is in effect when the
    #     freshly-imported distro starts, avoiding a second wsl --shutdown
    #     and a re-init of localhost forwarding mid-provision.
    Update-WslConfig
    Set-WslMirroredNetworking

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
                 "resume automatically after you log back in.`n`n" +
                 "To monitor live progress after reboot, open PowerShell:`n" +
                 "  Get-Content `"$LogFile`" -Wait -Tail 50")
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

    # provision.sh / wsl.conf / openclaw-gateway.service are committed to
    # the repo with LF-only line endings (.gitattributes enforces eol=lf)
    # and Inno Setup ships them byte-for-byte, so they arrive on the
    # customer's disk with no CRs to strip.
    #
    # The previous defensive `sed -i 's/\r$//' ...` here was actively
    # HARMFUL: GNU sed BRE treats the `\r` escape as a literal `r`, so
    # the substitution silently stripped the trailing `r` from any line
    # ending in `r` — corrupting `pnpm build:docker` into
    # `pnpm build:docke` and dead-ending provisioning at step 5/8 with
    # `ERR_PNPM_RECURSIVE_EXEC_FIRST_FAIL`. We rely on the .gitattributes
    # invariant instead.
    & wsl.exe -d $DistroName -u root -- chmod +x /tmp/provision.sh | Out-Null

    # Run provision.sh as root inside the distro. This is the long step:
    #   apt update + install (5-10 min, depends on mirror)
    #   download Node.js + pnpm tarballs (~1 min)
    #   pnpm install + rebuild + build + ui:build (5-15 min)
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

    # Seed openclaw.json into both the WSL guest (.openclaw is owned by
    # the openclaw user, created by provision.sh step 7) and the
    # Windows host backward-compat location. MUST happen BEFORE the
    # `wsl --terminate` below so when systemd cold-boots the gateway,
    # the file is already in place — the gateway reads the config at
    # service startup, not on demand. Then strip the apiKey from
    # install-options.ini so it does not sit in plain text in {app}\.
    $installOpts = Read-InstallOptions
    Apply-CloudProviderConfig -Distro $DistroName -Options $installOpts
    Remove-InstallOptionsSecrets

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

    # Create user-facing shortcuts and write the install-complete marker.
    # By construction, this is the LAST thing we do before declaring
    # success — so "shortcut on disk" always implies "Phase 2 finished
    # successfully and the gateway responded". A user who sees an icon
    # appear on their desktop knows the install is genuinely usable; a
    # user who looks and sees no icon knows it failed (or is still
    # in-flight). No misleading half-state is possible.
    New-LauncherShortcuts
    Write-InstallCompleteMarker

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

    # Both phases need admin: Phase 1 calls wsl --install (DISM-level
    # operation) and Phase 2 calls Start-Service vmcompute / wsl --import
    # (writes to ProgramData). The Inno Setup installer launches Phase 1
    # already-elevated. Phase 2's scheduled task is registered with
    # RunLevel=Highest so it inherits an elevated token at logon. But if
    # the user runs the script by hand from a standard shell — or some
    # corporate policy stripped the task's privilege — we self-elevate
    # rather than fail with a confusing ACCESS_DENIED later.
    if (-not (Test-IsAdmin)) {
        Write-Log "Not running elevated; relaunching self via UAC (Phase=$Phase)"
        $argList = @(
            "-NoProfile", "-ExecutionPolicy", "Bypass",
            "-File", "`"$PSCommandPath`"",
            "-AppDir", "`"$AppDir`"",
            "-Phase", $Phase
        )
        if ($FromInstaller) { $argList += "-FromInstaller" }
        Start-Process powershell.exe -Verb RunAs -ArgumentList $argList -Wait
        exit 0
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
