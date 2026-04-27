<#
.SYNOPSIS
    Build the aiDAPTIVClaw Windows installer (.exe) using Inno Setup.

.DESCRIPTION
    Pipeline (WSL2 sandbox, online build flavor — Q2=C):
      1. Validate Inno Setup Compiler is installed.
      2. Cache Canonical's vanilla Ubuntu 24.04 WSL base rootfs at
         installer/rootfs/ubuntu-base.tar.gz (~340 MB, downloaded once).
      3. Pack git-tracked source via `git archive --format=tar.gz HEAD`
         into installer/rootfs/openclaw-source.tar.gz.
      4. Run Inno Setup Compiler against installer/openclaw.iss.

    The build machine does NOT need WSL2, VT-x, or Docker. The customer
    machine downloads packages and builds OpenClaw at install time
    (post-install.ps1 Phase 2 runs provision.sh inside the WSL distro).

.PARAMETER AppVersion
    Version stamped into the installer. Falls back to package.json version.

.PARAMETER ForceRefreshSource
    Repack openclaw-source.tar.gz even if it already exists.
    (Use when running back-to-back builds on uncommitted changes.)

.PARAMETER ForceRefreshBase
    Re-download the Ubuntu base rootfs even if cached. Normally never
    needed; Canonical updates the base only on Ubuntu point releases.

.EXAMPLE
    .\scripts\build-installer.ps1
    .\scripts\build-installer.ps1 -AppVersion 1.0.0
    .\scripts\build-installer.ps1 -ForceRefreshSource
#>
param(
    [string]$AppVersion = "",
    [switch]$ForceRefreshSource,
    [switch]$ForceRefreshBase
)

$ErrorActionPreference = "Stop"
$RepoRoot      = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$InstallerDir  = Join-Path $RepoRoot "installer"
$RootfsDir     = Join-Path $InstallerDir "rootfs"
$BaseTarball   = Join-Path $RootfsDir "ubuntu-base.tar.gz"
$SourceTarball = Join-Path $RootfsDir "openclaw-source.tar.gz"
$OutputDir     = Join-Path $InstallerDir "output"
$IssFile       = Join-Path $InstallerDir "openclaw.iss"

# Canonical's official Ubuntu 24.04 WSL base rootfs. Same image MS Store
# ships but with a stable URL suitable for unattended download.
#
# NOTE: Canonical removed `.rootfs.tar.gz` from `/wsl/<codename>/current/`
# in 2025 (only manifests left). The traditional tarball lives under
# `/wsl/releases/24.04/current/` instead. Avoid the new `.wsl` format
# from `releases.ubuntu.com/noble/`: it requires `wsl --import --from-file`
# which only works on customer machines with WSL 2.4.10+, raising the
# minimum-WSL-version bar without any benefit for our pipeline.
$BaseUrl = "https://cloud-images.ubuntu.com/wsl/releases/24.04/current/ubuntu-noble-wsl-amd64-wsl.rootfs.tar.gz"

if (-not $AppVersion) {
    $PackageJson = Get-Content (Join-Path $RepoRoot "package.json") -Raw | ConvertFrom-Json
    $AppVersion = $PackageJson.version
}

Write-Host ""
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "  aiDAPTIVClaw Installer Builder"           -ForegroundColor Cyan
Write-Host "  Version: $AppVersion"                      -ForegroundColor Cyan
Write-Host "  Mode: WSL2 sandbox (online build, Q2=C)"  -ForegroundColor Cyan
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

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Error "git is not on PATH. Required for `git archive`."
    exit 1
}
Write-Host "  git:        OK" -ForegroundColor Green

# Sanity check: refuse to build with LF-only Windows scripts. A LF-only
# .cmd file makes some Windows cmd.exe builds silently mis-parse every
# `set`/`setlocal` line, which manifests at runtime as the launcher's
# marker check failing even when the marker is on disk. We hit this
# once already (see .gitattributes for the full forensic note); never
# again -- if a developer re-introduces an LF-only Windows script via
# editor config or a careless `git checkout`, fail the build now.
$LineEndingFixer = Join-Path $PSScriptRoot "fix-line-endings.ps1"
if (Test-Path $LineEndingFixer) {
    & $LineEndingFixer -Check
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Line-ending sanity check failed. Run: pwsh $LineEndingFixer"
        exit 1
    }
    Write-Host "  Line endings: OK" -ForegroundColor Green
}

if (-not (Test-Path $RootfsDir)) {
    New-Item -ItemType Directory -Path $RootfsDir -Force | Out-Null
}

# --- Step 1: Cache Ubuntu base rootfs ---
Write-Host ""
Write-Host "[Step 1] Preparing Ubuntu 24.04 base rootfs..." -ForegroundColor Yellow

if ($ForceRefreshBase -and (Test-Path $BaseTarball)) {
    Write-Host "  -ForceRefreshBase set; deleting cached base."
    Remove-Item $BaseTarball -Force
}
if (-not (Test-Path $BaseTarball)) {
    Write-Host "  Downloading $BaseUrl ..."
    # Disable PS progress UI: it slows Invoke-WebRequest by 10x on large files.
    $PrevProgress = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
        Invoke-WebRequest -Uri $BaseUrl -OutFile $BaseTarball -UseBasicParsing
    } finally {
        $ProgressPreference = $PrevProgress
    }
} else {
    Write-Host "  Using cached base ($BaseTarball)"
}
$BaseSizeMb = [math]::Round((Get-Item $BaseTarball).Length / 1MB, 1)
Write-Host "  Base rootfs ready ($BaseSizeMb MB)" -ForegroundColor Green

# --- Step 2: Pack source via git archive ---
Write-Host ""
Write-Host "[Step 2] Packing OpenClaw source via git archive..." -ForegroundColor Yellow

if ($ForceRefreshSource -and (Test-Path $SourceTarball)) {
    Write-Host "  -ForceRefreshSource set; deleting existing source archive."
    Remove-Item $SourceTarball -Force
}

# Always repack unless explicitly cached: source changes faster than base
# rootfs and nothing tracks "is the .tar.gz up-to-date with HEAD".
if (Test-Path $SourceTarball) {
    Remove-Item $SourceTarball -Force
}

Push-Location $RepoRoot
try {
    # `git archive HEAD` includes only commit-tracked files. Uncommitted
    # changes will NOT be in the installer — commit before building.
    & git archive --format=tar.gz --output="$SourceTarball" HEAD
    if ($LASTEXITCODE -ne 0) {
        throw "git archive failed (exit $LASTEXITCODE)"
    }
} finally {
    Pop-Location
}
$SourceSizeMb = [math]::Round((Get-Item $SourceTarball).Length / 1MB, 1)
Write-Host "  Source archive ready ($SourceSizeMb MB)" -ForegroundColor Green

# --- Step 3: Run Inno Setup Compiler ---
Write-Host ""
Write-Host "[Step 3] Building installer..." -ForegroundColor Yellow

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
Write-Host "  (Customer install requires internet:"      -ForegroundColor Green
Write-Host "   apt + nodejs.org + github.com)"           -ForegroundColor Green
Write-Host "==========================================" -ForegroundColor Green
Write-Host ""
