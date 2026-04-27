<#
.SYNOPSIS
    Build the NATIVE-flavor aiDAPTIVClaw Windows installer (.exe) using
    Inno Setup. Restored from commit 2b0bc718 and adjusted for the
    installer/native/ + installer/shared/ folder split.

.DESCRIPTION
    This script packages the OpenClaw source code and Node.js into an
    installer that builds on the customer's Windows machine directly
    (no WSL). It coexists with the WSL flavor (build-installer-wsl.ps1);
    both are reachable through the dispatcher scripts/build-installer.ps1.

    Pipeline:
    1. Validates required tools (Inno Setup Compiler)
    2. Downloads Node.js 24 LTS if not cached (installer/.node-cache/)
    3. Stages source code into installer/native/build/ (excludes node_modules, .git, tests)
    4. Runs Inno Setup against installer/native/openclaw.iss
    5. Final .exe lands in installer/output/aidaptiv-claw-setup-native-<ver>.exe

.PARAMETER AppVersion
    Custom version number for the installer. If not specified, reads from package.json.

.PARAMETER NodeVersion
    Node.js version to embed. Default: 24.0.0

.EXAMPLE
    pwsh scripts\build-installer.ps1 -Variant native
    pwsh scripts\build-installer-native.ps1
    pwsh scripts\build-installer-native.ps1 -AppVersion 1.0.0
    pwsh scripts\build-installer-native.ps1 -AppVersion 1.0.0 -NodeVersion 24.1.0
#>

param(
    [string]$AppVersion = "",
    [string]$NodeVersion = "24.0.0"
)

$ErrorActionPreference = "Stop"
$RepoRoot     = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$InstallerDir = Join-Path $RepoRoot "installer"
$NativeDir    = Join-Path $InstallerDir "native"
# Stage adjacent to native/openclaw.iss so its `Source: "build\*"` line
# resolves correctly. Output stays under installer/output (shared with
# the WSL flavor; OutputBaseFilename keeps the two .exe files apart).
$BuildDir     = Join-Path $NativeDir "build"
$OutputDir    = Join-Path $InstallerDir "output"
$NodeCacheDir = Join-Path $InstallerDir ".node-cache"

# Use custom version or fall back to package.json
if (-not $AppVersion) {
    $PackageJson = Get-Content (Join-Path $RepoRoot "package.json") -Raw | ConvertFrom-Json
    $AppVersion = $PackageJson.version
}

Write-Host ""
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "  aiDAPTIVClaw Installer Builder (NATIVE)"   -ForegroundColor Cyan
Write-Host "  Version: $AppVersion"                      -ForegroundColor Cyan
Write-Host "  Mode: Online (build on Windows target)"    -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host ""

# --- Step 0: Validate tools ---
Write-Host "[Step 0] Validating required tools..." -ForegroundColor Yellow

$IsccPaths = @(
    "C:\Program Files (x86)\Inno Setup 6\ISCC.exe",
    "C:\Program Files\Inno Setup 6\ISCC.exe"
)
$IsccPath = $null
foreach ($p in $IsccPaths) {
    if (Test-Path $p) {
        $IsccPath = $p
        break
    }
}
if (Get-Command iscc -ErrorAction SilentlyContinue) {
    $IsccPath = (Get-Command iscc).Source
}
if (-not $IsccPath) {
    Write-Error "Inno Setup 6 is not installed. Download from: https://jrsoftware.org/isdl.php"
    exit 1
}
Write-Host "  Inno Setup: OK ($IsccPath)" -ForegroundColor Green

# --- Step 1: Download Node.js ---
Write-Host ""
Write-Host "[Step 1] Preparing Node.js $NodeVersion..." -ForegroundColor Yellow

if (-not (Test-Path $NodeCacheDir)) {
    New-Item -ItemType Directory -Path $NodeCacheDir -Force | Out-Null
}

$NodeExeCache = Join-Path $NodeCacheDir "node-v$NodeVersion.exe"
if (Test-Path $NodeExeCache) {
    Write-Host "  Using cached Node.js binary."
} else {
    $NodeUrl = "https://nodejs.org/dist/v$NodeVersion/win-x64/node.exe"
    Write-Host "  Downloading Node.js from $NodeUrl..."
    try {
        Invoke-WebRequest -Uri $NodeUrl -OutFile $NodeExeCache -UseBasicParsing
    }
    catch {
        Write-Error "Failed to download Node.js. Check version $NodeVersion is valid."
        exit 1
    }
}
Write-Host "  Node.js ready." -ForegroundColor Green

# --- Step 2: Stage source code ---
Write-Host ""
Write-Host "[Step 2] Staging source code..." -ForegroundColor Yellow

if (Test-Path $BuildDir) {
    Write-Host "  Cleaning previous build..."
    Remove-Item -Recurse -Force $BuildDir
}
New-Item -ItemType Directory -Path $BuildDir -Force | Out-Null

if (-not (Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}

# Copy Node.js binary
Write-Host "  Copying Node.js binary..."
Copy-Item $NodeExeCache (Join-Path $BuildDir "node.exe")

# Copy root files needed for build
$IncludeFiles = @(
    "package.json", "pnpm-workspace.yaml", "pnpm-lock.yaml",
    "openclaw.mjs", "tsconfig.json", "tsconfig.plugin-sdk.dts.json",
    "tsdown.config.ts", ".npmrc", "LICENSE"
)
Write-Host "  Copying root config files..."
foreach ($file in $IncludeFiles) {
    $srcPath = Join-Path $RepoRoot $file
    if (Test-Path $srcPath) {
        Copy-Item $srcPath (Join-Path $BuildDir $file)
    }
}

# Use robocopy to copy directories while excluding node_modules, .git, dist, etc.
# robocopy exits with codes 0-7 for success; 8+ for errors
$ExcludeDirs = @("node_modules", ".git", "dist", ".next", ".build", "__pycache__", ".pnpm", "build")
$ExcludeFiles = @("*.test.ts", "*.e2e.test.ts", "*.spec.ts")
$RobocopyExclDirs = ($ExcludeDirs | ForEach-Object { "/XD" ; $_ })
$RobocopyExclFiles = ($ExcludeFiles | ForEach-Object { "/XF" ; $_ })

$CopyDirs = @("src", "ui", "extensions", "packages", "scripts", "patches", "vendor", "skills")

# Extra subdirectories needed for build (a2ui canvas bundle)
$ExtraSubDirs = @(
    "apps\shared\OpenClawKit\Tools\CanvasA2UI",
    "apps\shared\OpenClawKit\Sources\OpenClawKit\Resources",
    "docs\reference\templates"
)

foreach ($dir in $CopyDirs) {
    $srcPath = Join-Path $RepoRoot $dir
    $destPath = Join-Path $BuildDir $dir
    if (Test-Path $srcPath) {
        Write-Host "  Copying $dir/ (excluding node_modules)..."
        $robocopyArgs = @($srcPath, $destPath, "/E", "/NFL", "/NDL", "/NJH", "/NJS", "/NC", "/NS", "/NP") + $RobocopyExclDirs + $RobocopyExclFiles
        & robocopy @robocopyArgs | Out-Null
        $rc = $LASTEXITCODE
        if ($rc -ge 8) {
            Write-Error "robocopy failed for $dir (exit code $rc)"
            exit 1
        }
    }
}

# Copy extra subdirectories
foreach ($subDir in $ExtraSubDirs) {
    $srcPath = Join-Path $RepoRoot $subDir
    $destPath = Join-Path $BuildDir $subDir
    if (Test-Path $srcPath) {
        Write-Host "  Copying $subDir/..."
        New-Item -ItemType Directory -Path (Split-Path $destPath -Parent) -Force | Out-Null
        $robocopyArgs = @($srcPath, $destPath, "/E", "/NFL", "/NDL", "/NJH", "/NJS", "/NC", "/NS", "/NP") + $RobocopyExclDirs + $RobocopyExclFiles
        & robocopy @robocopyArgs | Out-Null
    }
}

$StagedSize = [math]::Round(((Get-ChildItem -Path $BuildDir -Recurse -File | Measure-Object -Property Length -Sum).Sum / 1MB), 1)
$StagedCount = (Get-ChildItem -Path $BuildDir -Recurse -File | Measure-Object).Count
Write-Host "  Staged: $StagedCount files, $StagedSize MB" -ForegroundColor Green

# --- Step 3: Run Inno Setup Compiler ---
Write-Host ""
Write-Host "[Step 3] Building installer..." -ForegroundColor Yellow

$IssFile = Join-Path $NativeDir "openclaw.iss"
& $IsccPath "/DAppVersion=$AppVersion" $IssFile
if ($LASTEXITCODE -ne 0) {
    Write-Error "Inno Setup compilation failed."
    exit 1
}

# --- Done ---
$OutputExe = Join-Path $OutputDir "aidaptiv-claw-setup-native-$AppVersion.exe"
$OutputSize = if (Test-Path $OutputExe) { [math]::Round((Get-Item $OutputExe).Length / 1MB, 1) } else { "?" }
Write-Host ""
Write-Host "==========================================" -ForegroundColor Green
Write-Host "  Installer built successfully!"             -ForegroundColor Green
Write-Host "  Output: $OutputExe"                        -ForegroundColor Green
Write-Host "  Size: ${OutputSize} MB"                    -ForegroundColor Green
Write-Host "==========================================" -ForegroundColor Green
Write-Host ""
