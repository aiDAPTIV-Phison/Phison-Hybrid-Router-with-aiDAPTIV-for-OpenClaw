<#
.SYNOPSIS
    Build aidaptivclaw.tar.gz: a pre-built Ubuntu 24.04 WSL rootfs containing OpenClaw.

.DESCRIPTION
    Pure WSL pipeline (no Docker). Steps:
      1. Cache + load Canonical Ubuntu 24.04 WSL base rootfs.
      2. Import as throwaway distro `aidaptivclaw-build`.
      3. Stream tracked source via `git archive | wsl tar -xf -`.
      4. Run installer/rootfs/provision.sh inside the distro as root.
      5. Export the resulting filesystem to installer/rootfs/aidaptivclaw.tar.gz.
      6. Unregister the build distro.

    Build time on a typical workstation:
      cold (no cached base): ~15-25 min
      warm (base cached):    ~5-10 min

.PARAMETER NodeVersion
    Node.js version baked into the rootfs. Default 22.11.0.

.PARAMETER PnpmVersion
    pnpm version baked into the rootfs. Default 9.12.0.

.PARAMETER KeepBuildDistro
    Skip `wsl --unregister` at the end. Useful for debugging:
    `wsl -d aidaptivclaw-build -u root` will then drop you into a shell.

.EXAMPLE
    .\scripts\build-rootfs.ps1
    .\scripts\build-rootfs.ps1 -NodeVersion 22.12.0
    .\scripts\build-rootfs.ps1 -KeepBuildDistro
#>
param(
    [string]$NodeVersion = "22.11.0",
    [string]$PnpmVersion = "9.12.0",
    [switch]$KeepBuildDistro
)

$ErrorActionPreference = "Stop"

$RepoRoot       = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$RootfsDir      = Join-Path $RepoRoot "installer\rootfs"
$CacheDir       = Join-Path $RootfsDir ".cache"
$BaseTarball    = Join-Path $CacheDir "ubuntu-24.04-base.tar.gz"
$OutputTarball  = Join-Path $RootfsDir "aidaptivclaw.tar.gz"
$BuildDistro    = "aidaptivclaw-build"
$BuildDistroDir = Join-Path $CacheDir "build-distro"

# Canonical official Ubuntu 24.04 WSL rootfs. Same image MS Store ships
# but with a stable URL suitable for CI automation.
$BaseUrl = "https://cloud-images.ubuntu.com/wsl/noble/current/ubuntu-noble-wsl-amd64-wsl.rootfs.tar.gz"

function Write-Step {
    param([string]$Stage, [string]$Message)
    Write-Host "[$Stage] $Message" -ForegroundColor Yellow
}

function Invoke-Wsl {
    # Wrapper that throws on non-zero exit so the script halts on first failure.
    param([Parameter(Mandatory)][string[]]$WslArgs)
    & wsl.exe @WslArgs
    if ($LASTEXITCODE -ne 0) {
        throw "wsl $($WslArgs -join ' ') failed (exit $LASTEXITCODE)"
    }
}

Write-Host ""
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "  aidaptivclaw rootfs builder (WSL native)" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host ""

# --- 0. Pre-flight ---
& wsl.exe --status | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "WSL2 is not installed on this build machine. Run: wsl --install --no-distribution, then reboot."
}
if (-not (Test-Path $CacheDir)) {
    New-Item -ItemType Directory -Path $CacheDir | Out-Null
}

# Defensive: drop any leftover build distro from a previously failed run.
$existing = (& wsl.exe --list --quiet) -split "`r?`n" | ForEach-Object { $_.Trim() }
if ($existing -contains $BuildDistro) {
    Write-Step "0/7" "Removing leftover build distro..."
    Invoke-Wsl @("--unregister", $BuildDistro)
}

# --- 1. Download Canonical base rootfs (cached) ---
if (-not (Test-Path $BaseTarball)) {
    Write-Step "1/7" "Downloading Ubuntu 24.04 WSL base rootfs..."
    Invoke-WebRequest -Uri $BaseUrl -OutFile $BaseTarball -UseBasicParsing
} else {
    Write-Step "1/7" "Using cached base rootfs ($BaseTarball)"
}

# --- 2. Import throwaway build distro ---
Write-Step "2/7" "Importing build distro..."
if (Test-Path $BuildDistroDir) { Remove-Item -Recurse -Force $BuildDistroDir }
New-Item -ItemType Directory -Path $BuildDistroDir | Out-Null
Invoke-Wsl @("--import", $BuildDistro, $BuildDistroDir, $BaseTarball, "--version", "2")

# --- 3. Stage rootfs config files (consumed by provision.sh step 6) ---
Write-Step "3/7" "Staging rootfs config files..."
Invoke-Wsl @("-d", $BuildDistro, "-u", "root", "--",
    "mkdir", "-p", "/tmp/rootfs-config", "/tmp/openclaw-src")

# Translate Windows paths to WSL paths via `wslpath -u`.
$wslConfPath = (& wsl.exe -d $BuildDistro -u root -- wslpath -u "$RootfsDir\wsl.conf").Trim()
$svcPath     = (& wsl.exe -d $BuildDistro -u root -- wslpath -u "$RootfsDir\openclaw-gateway.service").Trim()
$provPath    = (& wsl.exe -d $BuildDistro -u root -- wslpath -u "$RootfsDir\provision.sh").Trim()

Invoke-Wsl @("-d", $BuildDistro, "-u", "root", "--", "cp", $wslConfPath, "/tmp/rootfs-config/wsl.conf")
Invoke-Wsl @("-d", $BuildDistro, "-u", "root", "--", "cp", $svcPath,     "/tmp/rootfs-config/openclaw-gateway.service")
Invoke-Wsl @("-d", $BuildDistro, "-u", "root", "--", "cp", $provPath,    "/tmp/provision.sh")
Invoke-Wsl @("-d", $BuildDistro, "-u", "root", "--", "chmod", "+x", "/tmp/provision.sh")

# Strip CRLF in case provision.sh was checked out with Windows line endings.
Invoke-Wsl @("-d", $BuildDistro, "-u", "root", "--",
    "sed", "-i", "s/\r$//", "/tmp/provision.sh", "/tmp/rootfs-config/wsl.conf",
    "/tmp/rootfs-config/openclaw-gateway.service")

# --- 4. Stream tracked source code into the distro ---
# `git archive` includes only commit-tracked files (no node_modules, no
# uncommitted noise). The `cmd /c` wrapper preserves the binary tar stream;
# PowerShell's pipeline would re-encode it and corrupt the archive.
Write-Step "4/7" "Streaming source via git archive..."
Push-Location $RepoRoot
try {
    & cmd /c "git archive --format=tar HEAD | wsl.exe -d $BuildDistro -u root -- tar -xf - -C /tmp/openclaw-src"
    if ($LASTEXITCODE -ne 0) { throw "git archive | tar pipe failed (exit $LASTEXITCODE)" }
} finally {
    Pop-Location
}

# --- 5. Run provisioning script ---
Write-Step "5/7" "Running provision.sh inside build distro (long step)..."
Invoke-Wsl @(
    "-d", $BuildDistro, "-u", "root",
    "--",
    "env", "NODE_VERSION=$NodeVersion", "PNPM_VERSION=$PnpmVersion",
    "/tmp/provision.sh"
)

# --- 6. Shut down the distro to flush filesystem writes before export ---
Write-Step "6/7" "Shutting down build distro..."
Invoke-Wsl @("--terminate", $BuildDistro)

# --- 7. Export rootfs ---
Write-Step "7/7" "Exporting rootfs to $OutputTarball ..."
if (Test-Path $OutputTarball) { Remove-Item -Force $OutputTarball }
Invoke-Wsl @("--export", $BuildDistro, $OutputTarball, "--format", "tar.gz")

if (-not $KeepBuildDistro) {
    Invoke-Wsl @("--unregister", $BuildDistro)
    Remove-Item -Recurse -Force $BuildDistroDir -ErrorAction SilentlyContinue
}

$SizeMb = [math]::Round((Get-Item $OutputTarball).Length / 1MB, 1)
Write-Host ""
Write-Host "Done. Output: $OutputTarball ($SizeMb MB)" -ForegroundColor Green
Write-Host ""
