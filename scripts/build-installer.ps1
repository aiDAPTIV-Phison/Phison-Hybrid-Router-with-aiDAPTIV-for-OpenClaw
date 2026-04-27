<#
.SYNOPSIS
    Dispatcher for the aiDAPTIVClaw Windows installer build pipeline.

.DESCRIPTION
    The repository ships TWO installer flavors that can be built and
    installed side by side on the same machine (different AppIds, so
    Windows treats them as independent products):

      - native: Original online-build flavor preserved from commit
                2b0bc718 and earlier. Stages OpenClaw source + Node.js
                into installer\native\build\, then runs Inno Setup
                against installer\native\openclaw.iss. Customer install
                builds OpenClaw on Windows directly (no WSL).

      - wsl:    WSL2 sandbox flavor. Ships Canonical Ubuntu 24.04 base
                rootfs + a `git archive HEAD` source tarball, then runs
                provision.sh inside the imported WSL distro at install
                time. See docs/plans/2026-04-23-wsl-sandbox-design.md.

    This script just forwards to the requested flavor's build script.

.PARAMETER Variant
    Which installer to build. One of: native, wsl. Default: wsl
    (current development target on this branch).

.PARAMETER AppVersion
    Version stamped into the installer. Falls back to package.json
    version inside the per-flavor build script.

.PARAMETER ForceRefreshSource
    [WSL only] Repack openclaw-source.tar.gz even if it already exists.

.PARAMETER ForceRefreshBase
    [WSL only] Re-download the Ubuntu base rootfs even if cached.

.PARAMETER NodeVersion
    [native only] Node.js version to bundle.

.EXAMPLE
    pwsh scripts\build-installer.ps1
    pwsh scripts\build-installer.ps1 -Variant wsl
    pwsh scripts\build-installer.ps1 -Variant native
    pwsh scripts\build-installer.ps1 -Variant native -AppVersion 1.0.0
#>
[CmdletBinding()]
param(
    [ValidateSet('native', 'wsl')]
    [string]$Variant = 'wsl',
    [string]$AppVersion = '',
    [switch]$ForceRefreshSource,
    [switch]$ForceRefreshBase,
    [string]$NodeVersion = '24.0.0'
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

switch ($Variant) {
    'native' {
        $target = Join-Path $here 'build-installer-native.ps1'
        if (-not (Test-Path $target)) {
            Write-Error "Missing $target"
            exit 1
        }
        # Forward only the params that the native script accepts.
        & $target -AppVersion $AppVersion -NodeVersion $NodeVersion
        exit $LASTEXITCODE
    }
    'wsl' {
        $target = Join-Path $here 'build-installer-wsl.ps1'
        if (-not (Test-Path $target)) {
            Write-Error "Missing $target"
            exit 1
        }
        # Forward only the params that the WSL script accepts.
        $fwd = @{ AppVersion = $AppVersion }
        if ($ForceRefreshSource) { $fwd['ForceRefreshSource'] = $true }
        if ($ForceRefreshBase)   { $fwd['ForceRefreshBase']   = $true }
        & $target @fwd
        exit $LASTEXITCODE
    }
}
