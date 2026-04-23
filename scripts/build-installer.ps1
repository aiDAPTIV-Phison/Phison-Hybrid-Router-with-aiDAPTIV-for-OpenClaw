<#
.SYNOPSIS
    Build the aiDAPTIVClaw Windows installer (.exe) using Inno Setup.

.DESCRIPTION
    Pipeline (WSL2 sandbox flavor):
      1. Validate Inno Setup Compiler is installed.
      2. Ensure installer/rootfs/aidaptivclaw.tar.gz exists; build it via
         scripts/build-rootfs.ps1 if missing or if -ForceRebuildRootfs.
      3. Run Inno Setup Compiler against installer/openclaw.iss.

    The legacy "stage source + ship Node.js + build on customer machine"
    pipeline was retired with the WSL2 redesign — source code, Node.js,
    pnpm and the OpenClaw build artifacts are all baked into the rootfs.

.PARAMETER AppVersion
    Version stamped into the installer. Falls back to package.json version.

.PARAMETER ForceRebuildRootfs
    Rebuild the rootfs even if installer/rootfs/aidaptivclaw.tar.gz
    already exists. Useful after editing provision.sh / wsl.conf /
    openclaw-gateway.service.

.EXAMPLE
    .\scripts\build-installer.ps1
    .\scripts\build-installer.ps1 -AppVersion 1.0.0
    .\scripts\build-installer.ps1 -ForceRebuildRootfs
#>
param(
    [string]$AppVersion = "",
    [switch]$ForceRebuildRootfs
)

$ErrorActionPreference = "Stop"
$RepoRoot      = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$InstallerDir  = Join-Path $RepoRoot "installer"
$RootfsDir     = Join-Path $InstallerDir "rootfs"
$RootfsTarball = Join-Path $RootfsDir "aidaptivclaw.tar.gz"
$OutputDir     = Join-Path $InstallerDir "output"
$IssFile       = Join-Path $InstallerDir "openclaw.iss"

if (-not $AppVersion) {
    $PackageJson = Get-Content (Join-Path $RepoRoot "package.json") -Raw | ConvertFrom-Json
    $AppVersion = $PackageJson.version
}

Write-Host ""
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "  aiDAPTIVClaw Installer Builder"           -ForegroundColor Cyan
Write-Host "  Version: $AppVersion"                      -ForegroundColor Cyan
Write-Host "  Mode: WSL2 sandbox (offline rootfs)"       -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host ""

# --- Step 0: Validate tools ---
Write-Host "[Step 0] Validating tools..." -ForegroundColor Yellow

$IsccPaths = @(
    "C:\Program Files (x86)\Inno Setup 6\ISCC.exe",
    "C:\Program Files\Inno Setup 6\ISCC.exe"
)
$IsccPath = $null
foreach ($p in $IsccPaths) {
    if (Test-Path $p) { $IsccPath = $p; break }
}
if (Get-Command iscc -ErrorAction SilentlyContinue) {
    $IsccPath = (Get-Command iscc).Source
}
if (-not $IsccPath) {
    Write-Error "Inno Setup 6 is not installed. Download from: https://jrsoftware.org/isdl.php"
    exit 1
}
Write-Host "  Inno Setup: OK ($IsccPath)" -ForegroundColor Green

# --- Step 1: Ensure rootfs tarball exists ---
Write-Host ""
Write-Host "[Step 1] Preparing WSL rootfs..." -ForegroundColor Yellow

if ($ForceRebuildRootfs -and (Test-Path $RootfsTarball)) {
    Write-Host "  -ForceRebuildRootfs set; deleting existing tarball."
    Remove-Item $RootfsTarball -Force
}

if (-not (Test-Path $RootfsTarball)) {
    Write-Host "  Rootfs not found; running scripts/build-rootfs.ps1 (15-25 min cold, 5-10 min warm)..."
    & (Join-Path $RepoRoot "scripts\build-rootfs.ps1")
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Rootfs build failed. See output above."
        exit 1
    }
}

if (-not (Test-Path $RootfsTarball)) {
    Write-Error "Expected $RootfsTarball after build, but it is missing."
    exit 1
}

$RootfsSizeMb = [math]::Round((Get-Item $RootfsTarball).Length / 1MB, 1)
Write-Host "  Rootfs ready: $RootfsTarball ($RootfsSizeMb MB)" -ForegroundColor Green

# --- Step 2: Run Inno Setup Compiler ---
Write-Host ""
Write-Host "[Step 2] Building installer..." -ForegroundColor Yellow

if (-not (Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}

& $IsccPath "/DAppVersion=$AppVersion" $IssFile
if ($LASTEXITCODE -ne 0) {
    Write-Error "Inno Setup compilation failed."
    exit 1
}

# --- Done ---
$OutputExe = Join-Path $OutputDir "aidaptiv-claw-setup-$AppVersion.exe"
$OutputSize = if (Test-Path $OutputExe) { [math]::Round((Get-Item $OutputExe).Length / 1MB, 1) } else { "?" }
Write-Host ""
Write-Host "==========================================" -ForegroundColor Green
Write-Host "  Installer built successfully!"             -ForegroundColor Green
Write-Host "  Output: $OutputExe"                        -ForegroundColor Green
Write-Host "  Size: ${OutputSize} MB"                    -ForegroundColor Green
Write-Host "==========================================" -ForegroundColor Green
Write-Host ""
