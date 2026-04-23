# WSL2 Sandbox for aiDAPTIVClaw — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans` to implement this plan task-by-task.
>
> Each task is bite-sized (2-15 min). Because this is installer/OS-level work, traditional unit tests don't apply; each task ends with a concrete verification command and expected output instead.

**Goal:** Convert aiDAPTIVClaw from a native Windows installation (full user privileges) into a WSL2-confined installation (non-root user inside an isolated Ubuntu 24.04 distro with systemd hardening), so OpenClaw can no longer read arbitrary Windows files or escalate privileges if compromised.

**Architecture:** Installer ships a pre-built Ubuntu 24.04 rootfs (`aidaptivclaw.tar.gz`) containing a fully built OpenClaw under `/opt/openclaw`. On install, `wsl --import` registers the rootfs as a private distro `aidaptivclaw`. A systemd unit (`openclaw-gateway.service`) starts the gateway as the non-root `openclaw` user with hardening directives confining writes to `/home/openclaw/{workspace,.openclaw}` and `/tmp`. The Windows launcher only triggers `wsl.exe -d aidaptivclaw` and opens the browser at `http://localhost:18789` (reachable via WSL2 default localhost forwarding).

**Tech Stack:** Inno Setup (installer), Bash + Docker (rootfs build in CI), WSL2, Ubuntu 24.04, systemd, Node.js 22+, pnpm.

**Reference:** Decisions are summarized in `docs/plans/2026-04-23-wsl-sandbox-brainstorm-summary.md`. Read that first for context on every "why".

---

## Phase 0 — Setup & Prerequisites

### Task 0.1: Confirm host build prerequisites

**Files:** None (host check only).

**Step 1: Verify Inno Setup 6 + Docker Desktop are installed on the build machine**

Run (PowerShell):

```powershell
& "C:\Program Files (x86)\Inno Setup 6\ISCC.exe" /? | Select-Object -First 1
docker --version
```

Expected:

```
Inno Setup 6 Command-Line Compiler
Docker version 24.x.x or later
```

If either is missing, install before proceeding. Docker is needed because rootfs build runs inside a Linux container (so the build is reproducible regardless of build host OS).

**Step 2: Verify WSL2 is installed for local smoke tests**

Run:

```powershell
wsl --status
```

Expected: `Default Version: 2`. If `Default Version: 1` or WSL not installed, run `wsl --install --no-distribution` and reboot.

**Step 3: No commit (environment-only check)**

---

## Phase 1 — Rootfs Build Pipeline (CI side)

> This phase produces `aidaptivclaw.tar.gz`, a pre-built Ubuntu 24.04 rootfs containing OpenClaw, ready to be embedded in the installer.

### Task 1.1: Create rootfs build Dockerfile

**Files:**
- Create: `installer/rootfs/Dockerfile`

**Step 1: Write the Dockerfile**

```dockerfile
# Build aidaptivclaw rootfs: Ubuntu 24.04 + Node 22 + pnpm + OpenClaw built under /opt/openclaw.
# The output of this image's filesystem is exported as aidaptivclaw.tar.gz and shipped in the installer.
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive \
    PNPM_HOME=/opt/pnpm \
    PATH=/opt/pnpm:/opt/node/bin:$PATH

# System packages: systemd is required because the WSL distro boots with [boot] systemd=true
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl gnupg git python3 build-essential \
        dbus systemd systemd-sysv \
        sudo locales tzdata \
    && locale-gen en_US.UTF-8 \
    && rm -rf /var/lib/apt/lists/*

# Node.js 22 LTS (matches the version embedded in the Windows installer)
ARG NODE_VERSION=22.11.0
RUN mkdir -p /opt/node && curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz" \
    | tar -xJ --strip-components=1 -C /opt/node

# pnpm via standalone install (deterministic, no global npm install)
ARG PNPM_VERSION=9.12.0
RUN curl -fsSL "https://github.com/pnpm/pnpm/releases/download/v${PNPM_VERSION}/pnpm-linux-x64" -o /opt/pnpm/pnpm \
    && chmod +x /opt/pnpm/pnpm

# Create non-root openclaw user. uid 1000 is conventional for the first user.
# No password, no shell login (nologin), not in sudo group.
RUN useradd --create-home --uid 1000 --shell /usr/sbin/nologin openclaw

# Stage source code (caller copies the repo into /tmp/openclaw-src before docker build)
COPY --chown=openclaw:openclaw src/ /tmp/openclaw-src/

# Build OpenClaw as the openclaw user, install to /opt/openclaw
USER openclaw
WORKDIR /tmp/openclaw-src
RUN /opt/pnpm/pnpm install --ignore-scripts \
    && /opt/pnpm/pnpm rebuild esbuild sharp koffi protobufjs \
    && /opt/pnpm/pnpm build:docker \
    && /opt/pnpm/pnpm ui:build

USER root
RUN mkdir -p /opt/openclaw \
    && cp -r /tmp/openclaw-src/. /opt/openclaw/ \
    && chown -R openclaw:openclaw /opt/openclaw \
    && rm -rf /tmp/openclaw-src

# WSL distro boot config (consumed when wsl --import registers the rootfs)
COPY installer/rootfs/wsl.conf /etc/wsl.conf
COPY installer/rootfs/openclaw-gateway.service /etc/systemd/system/openclaw-gateway.service

# Enable the gateway service so systemd starts it on distro boot
RUN systemctl enable openclaw-gateway.service

# Workspace + config dirs (writable allowlist targets in the systemd unit)
RUN mkdir -p /home/openclaw/workspace /home/openclaw/.openclaw /home/openclaw/readonly \
    && chown -R openclaw:openclaw /home/openclaw

# Strip apt caches and other noise to shrink the rootfs tarball
RUN apt-get clean && rm -rf /var/lib/apt/lists/* /var/cache/apt /tmp/* /var/tmp/*

CMD ["/sbin/init"]
```

**Step 2: Verify the Dockerfile builds (smoke test, do not export yet)**

Run from repo root:

```powershell
# Dummy src so docker build won't fail; real src is staged in Task 1.3
mkdir -Force installer\rootfs\.smoke-src
echo '{"name":"smoke","version":"0.0.0"}' | Out-File -Encoding utf8 installer\rootfs\.smoke-src\package.json
docker build -f installer/rootfs/Dockerfile --build-arg NODE_VERSION=22.11.0 -t aidaptivclaw-rootfs-smoke installer/rootfs/
```

Expected: build fails at the `pnpm install` step (no real `pnpm-lock.yaml`). This is FINE — we're only verifying the Dockerfile syntax + base image fetch. Real build runs in Task 1.3.

If it fails BEFORE the `pnpm install` step (e.g. apt error, node download error, COPY error), fix the Dockerfile.

**Step 3: Commit**

```bash
git add installer/rootfs/Dockerfile
git commit -m "installer: add rootfs Dockerfile for Ubuntu 24.04 sandbox base"
```

---

### Task 1.2: Create WSL boot config + systemd unit

**Files:**
- Create: `installer/rootfs/wsl.conf`
- Create: `installer/rootfs/openclaw-gateway.service`

**Step 1: Write `installer/rootfs/wsl.conf`**

```ini
# WSL distro boot configuration for aidaptivclaw.
# See https://learn.microsoft.com/windows/wsl/wsl-config

[boot]
# Enable systemd as PID 1 so openclaw-gateway.service starts automatically on distro boot.
systemd=true

[user]
# Default user when entering the distro via "wsl -d aidaptivclaw" without -u.
default=openclaw

[automount]
# Do NOT auto-mount Windows drives. This is the critical sandbox hardening.
# OpenClaw inside this distro will not see /mnt/c by default.
enabled=false

[network]
# generateHosts/generateResolvConf default to true; we keep them so DNS works.
# We do NOT set hostname here; let WSL pick one to avoid confusion with other distros.

[interop]
# Disable Windows interop: prevent OpenClaw from launching Windows .exe files.
enabled=false
appendWindowsPath=false
```

> **Note on `vmIdleTimeout=-1`:** This setting belongs in the host-side `%USERPROFILE%\.wslconfig`, NOT in the per-distro `/etc/wsl.conf`. It is handled by the installer in Task 3.4.

**Step 2: Write `installer/rootfs/openclaw-gateway.service`**

```ini
# systemd unit for OpenClaw gateway running inside the aidaptivclaw WSL distro.
# Hardening directives implement the "workspace-writable, system read-only" sandbox
# described in docs/plans/2026-04-23-wsl-sandbox-brainstorm-summary.md (Q5).

[Unit]
Description=OpenClaw Gateway (sandboxed)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=openclaw
Group=openclaw
WorkingDirectory=/home/openclaw

# Environment
Environment=HOME=/home/openclaw
Environment=NODE_ENV=production
Environment=OPENCLAW_GATEWAY_BIND=127.0.0.1
Environment=OPENCLAW_GATEWAY_PORT=18789

ExecStart=/opt/node/bin/node /opt/openclaw/openclaw.mjs gateway run \
    --bind 127.0.0.1 --port 18789 --force

# --- Sandbox hardening (systemd reference: https://www.freedesktop.org/software/systemd/man/systemd.exec.html) ---

# Filesystem: most of the distro becomes read-only; only writable paths are explicitly listed.
ProtectSystem=strict
ProtectHome=tmpfs
ReadWritePaths=/home/openclaw/workspace /home/openclaw/.openclaw
PrivateTmp=yes

# Privileges
NoNewPrivileges=yes
CapabilityBoundingSet=
AmbientCapabilities=
RestrictSUIDSGID=yes

# Devices: only /dev/null, /dev/zero, /dev/random, /dev/urandom, /dev/tty
PrivateDevices=yes

# Kernel surface
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectKernelLogs=yes
ProtectControlGroups=yes
ProtectClock=yes
ProtectHostname=yes
ProtectProc=invisible
ProcSubset=pid

# Namespaces
RestrictNamespaces=yes
LockPersonality=yes

# Architecture / system calls
SystemCallArchitectures=native
SystemCallFilter=@system-service
SystemCallFilter=~@privileged @resources @mount @debug @cpu-emulation @obsolete @raw-io @reboot @swap @module

# Memory: deny W+X (defense-in-depth against JIT-style exploits; Node uses RWX for V8 so we leave this off if Node breaks)
# MemoryDenyWriteExecute=yes  # disabled: Node V8 needs RWX pages
RestrictRealtime=yes

# Network: open for now (Q4 = A in brainstorm summary). Tighten in a follow-up.
# Do NOT set IPAddressDeny=any until network allowlist is designed.

# Restart policy
Restart=on-failure
RestartSec=5
StartLimitInterval=60
StartLimitBurst=3

# Logging
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
```

**Step 3: Verify with `systemd-analyze` later**

Note: we cannot fully verify the unit until it runs inside the built rootfs (Task 1.4). For now, verify it parses syntactically.

Run (any Linux box, including a smoke WSL):

```bash
systemd-analyze verify installer/rootfs/openclaw-gateway.service 2>&1 | head -20
```

Expected: no errors mentioning `[Unit]` / `[Service]` syntax. Warnings about "ExecStart binary not found" are EXPECTED at this stage (the binary exists only inside the rootfs).

**Step 4: Commit**

```bash
git add installer/rootfs/wsl.conf installer/rootfs/openclaw-gateway.service
git commit -m "installer: add WSL boot config + hardened systemd unit for gateway"
```

---

### Task 1.3: Create rootfs build script

**Files:**
- Create: `scripts/build-rootfs.ps1`

**Step 1: Write the build script**

```powershell
<#
.SYNOPSIS
    Build aidaptivclaw.tar.gz: a pre-built Ubuntu 24.04 WSL rootfs containing OpenClaw.

.DESCRIPTION
    Pipeline:
    1. Stage repo source (excluding node_modules, .git, dist, tests) into installer/rootfs/.src/
    2. docker build -f installer/rootfs/Dockerfile -> intermediate image
    3. docker create + docker export -> aidaptivclaw.tar.gz
    4. Output: installer/rootfs/aidaptivclaw.tar.gz (consumed by openclaw.iss in Task 2.1)

    The built rootfs is consumed by Inno Setup at packaging time and shipped to end users.
    Build time on a typical CI runner: ~10-20 min cold, ~3-5 min warm (Docker layer cache).

.PARAMETER NodeVersion
    Node.js version baked into the rootfs. Default 22.11.0 (matches Windows installer).
#>
param(
    [string]$NodeVersion = "22.11.0"
)

$ErrorActionPreference = "Stop"
$RepoRoot      = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$RootfsDir     = Join-Path $RepoRoot "installer\rootfs"
$SrcStaging    = Join-Path $RootfsDir ".src"
$OutputTarball = Join-Path $RootfsDir "aidaptivclaw.tar.gz"
$ImageTag      = "aidaptivclaw-rootfs:build"

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "  aidaptivclaw rootfs builder"             -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan

# --- Step 1: Stage source ---
Write-Host "[1/4] Staging source..." -ForegroundColor Yellow
if (Test-Path $SrcStaging) { Remove-Item -Recurse -Force $SrcStaging }
New-Item -ItemType Directory -Path $SrcStaging | Out-Null

# Use git ls-files to copy only tracked files (excludes node_modules/.git/dist by default)
Push-Location $RepoRoot
try {
    $tracked = git ls-files
    foreach ($f in $tracked) {
        $dest = Join-Path $SrcStaging $f
        $destDir = Split-Path $dest -Parent
        if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
        Copy-Item -LiteralPath (Join-Path $RepoRoot $f) -Destination $dest -Force
    }
} finally {
    Pop-Location
}
Write-Host "  Source staged to $SrcStaging" -ForegroundColor Green

# --- Step 2: docker build ---
Write-Host "[2/4] Building Docker image (this is the long step)..." -ForegroundColor Yellow
docker build `
    -f (Join-Path $RootfsDir "Dockerfile") `
    --build-arg NODE_VERSION=$NodeVersion `
    -t $ImageTag `
    --build-context src=$SrcStaging `
    $RootfsDir
if ($LASTEXITCODE -ne 0) {
    throw "docker build failed (exit $LASTEXITCODE)"
}

# --- Step 3: docker export -> tar.gz ---
Write-Host "[3/4] Exporting rootfs..." -ForegroundColor Yellow
$ContainerId = (docker create $ImageTag).Trim()
try {
    docker export $ContainerId | & "$env:ProgramFiles\7-Zip\7z.exe" a -tgzip -si $OutputTarball
    if ($LASTEXITCODE -ne 0) { throw "tar export / gzip failed" }
} finally {
    docker rm $ContainerId | Out-Null
}

$SizeMb = [math]::Round((Get-Item $OutputTarball).Length / 1MB, 1)
Write-Host "  Output: $OutputTarball ($SizeMb MB)" -ForegroundColor Green

# --- Step 4: Cleanup ---
Write-Host "[4/4] Cleanup..." -ForegroundColor Yellow
Remove-Item -Recurse -Force $SrcStaging
Write-Host "  Done." -ForegroundColor Green
```

> **Note on Dockerfile vs script `COPY`:** The Dockerfile uses `COPY src/ /tmp/openclaw-src/` which references a build context named `src` (line `--build-context src=$SrcStaging`). This requires Docker BuildKit (default in modern Docker Desktop). If the build host has BuildKit disabled, set `$env:DOCKER_BUILDKIT="1"` before running.

**Step 2: Verify the script runs end-to-end**

Run:

```powershell
$env:DOCKER_BUILDKIT = "1"
.\scripts\build-rootfs.ps1
```

Expected:
- Takes 10-20 min the first time (downloads ubuntu:24.04, node, pnpm; runs `pnpm install` + builds)
- Produces `installer\rootfs\aidaptivclaw.tar.gz`, size approximately 600MB-1.2GB

If `pnpm install` or `build:docker` fails, the issue is in OpenClaw itself, not the rootfs pipeline. Investigate logs from `docker build`.

**Step 3: Verify the tarball can be imported into WSL**

Run:

```powershell
$testDir = "$env:TEMP\aidaptivclaw-test"
mkdir -Force $testDir
wsl --import aidaptivclaw-test $testDir installer\rootfs\aidaptivclaw.tar.gz
wsl -d aidaptivclaw-test -u openclaw -e /opt/node/bin/node --version
```

Expected: prints `v22.11.0` (the Node version baked in).

Cleanup:

```powershell
wsl --unregister aidaptivclaw-test
Remove-Item -Recurse -Force $testDir
```

**Step 4: Commit**

```bash
git add scripts/build-rootfs.ps1
git commit -m "scripts: add rootfs build pipeline (docker -> wsl tarball)"
```

---

### Task 1.4: Verify systemd unit applies hardening correctly inside the built rootfs

**Files:** None (verification only).

**Step 1: Import the rootfs and start the gateway**

Run (assumes Task 1.3 produced `aidaptivclaw.tar.gz`):

```powershell
$testDir = "$env:TEMP\aidaptivclaw-verify"
mkdir -Force $testDir
wsl --import aidaptivclaw-verify $testDir installer\rootfs\aidaptivclaw.tar.gz
# First boot: trigger systemd
wsl -d aidaptivclaw-verify -u root -e /bin/true
# Wait for systemd to come up
Start-Sleep -Seconds 5
# Verify gateway service started
wsl -d aidaptivclaw-verify -u root -e systemctl is-active openclaw-gateway.service
```

Expected: `active`.

**Step 2: Verify hardening directives are in effect**

Run:

```powershell
# Get the gateway PID
$pid = wsl -d aidaptivclaw-verify -u root -e systemctl show -p MainPID --value openclaw-gateway.service
# Inspect its filesystem view
wsl -d aidaptivclaw-verify -u root -e cat /proc/$pid/status | Select-String -Pattern "NoNewPrivs|CapBnd"
wsl -d aidaptivclaw-verify -u root -e ls -la /proc/$pid/root/etc/wsl.conf
```

Expected:
- `NoNewPrivs: 1`
- `CapBnd: 0000000000000000` (empty capability bounding set)
- `/etc/wsl.conf` listed (unit can read system files)

**Step 3: Verify write to non-allowlisted path fails**

Run:

```powershell
# Try to write outside ReadWritePaths as the gateway user
wsl -d aidaptivclaw-verify -u openclaw -e bash -c "echo test > /etc/test-should-fail.txt; echo exit=\$?"
```

Expected: `exit=1` (Permission denied) — `/etc` is read-only because of `ProtectSystem=strict`.

**Step 4: Verify write to workspace succeeds**

Run:

```powershell
wsl -d aidaptivclaw-verify -u openclaw -e bash -c "echo test > /home/openclaw/workspace/ok.txt; cat /home/openclaw/workspace/ok.txt"
```

Expected: prints `test`.

**Step 5: Verify /mnt/c is invisible**

Run:

```powershell
wsl -d aidaptivclaw-verify -u openclaw -e ls /mnt/ 2>&1
```

Expected: empty output (no `c` directory) because `[automount] enabled=false` in `wsl.conf`.

**Step 6: Cleanup**

```powershell
wsl --unregister aidaptivclaw-verify
Remove-Item -Recurse -Force $testDir
```

**Step 7: No commit (verification only). If any step failed, fix the corresponding file in Task 1.1 / 1.2 and rerun the verification.**

---

## Phase 2 — Inno Setup Installer Changes

### Task 2.1: Modify `openclaw.iss` to ship the rootfs

**Files:**
- Modify: `installer/openclaw.iss`

**Step 1: Add rootfs to `[Files]` section**

In `installer/openclaw.iss`, find the `[Files]` section (line 43) and replace the `Source: "build\*"` line with rootfs files. The previous Windows-side staging is no longer needed.

Replace:

```pascal
[Files]
; Source code + Node.js (staged by build-installer.ps1)
Source: "build\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
; Launcher and helpers
Source: "openclaw-launcher.vbs"; DestDir: "{app}"; Flags: ignoreversion
Source: "openclaw-launcher.cmd"; DestDir: "{app}"; Flags: ignoreversion
Source: "post-install.cmd"; DestDir: "{app}"; Flags: ignoreversion
Source: "openclaw-template.json"; DestDir: "{app}"; Flags: ignoreversion
Source: "Gemini_Generated_Image_aiDAPTIV.ico"; DestDir: "{app}"; Flags: ignoreversion
Source: "configure-cloud.cjs"; DestDir: "{app}"; Flags: ignoreversion
```

With:

```pascal
[Files]
; Pre-built WSL rootfs (Ubuntu 24.04 + OpenClaw, built by scripts/build-rootfs.ps1)
Source: "rootfs\aidaptivclaw.tar.gz"; DestDir: "{app}"; Flags: ignoreversion
; Launcher and helpers (Windows side only)
Source: "openclaw-launcher.vbs"; DestDir: "{app}"; Flags: ignoreversion
Source: "openclaw-launcher.cmd"; DestDir: "{app}"; Flags: ignoreversion
Source: "post-install.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "openclaw-template.json"; DestDir: "{app}"; Flags: ignoreversion
Source: "Gemini_Generated_Image_aiDAPTIV.ico"; DestDir: "{app}"; Flags: ignoreversion
```

> Note: `post-install.cmd` -> `post-install.ps1` (rewritten in Task 2.2). `node.exe`, `configure-cloud.cjs`, and the entire build are gone — the rootfs already contains everything.

**Step 2: Remove the `installdaemon` task and uninstall daemon hook**

In `[Tasks]` (line 38-41), remove:

```pascal
Name: "installdaemon"; Description: "Start gateway automatically on login"; GroupDescription: "Additional options:"; Flags: checkedonce
```

In `[UninstallRun]` (line 65-67), remove the daemon uninstall (no Windows-side daemon exists anymore):

```pascal
Filename: "{app}\node.exe"; Parameters: """{app}\openclaw.mjs"" gateway daemon uninstall"; WorkingDir: "{app}"; Flags: waituntilterminated runhidden
```

Replace with WSL distro unregister (covered in Task 2.4).

**Step 3: Verify the .iss still compiles**

Run:

```powershell
& "C:\Program Files (x86)\Inno Setup 6\ISCC.exe" /Oinstaller\output installer\openclaw.iss
```

Expected: no errors, but the build will FAIL with "file not found: rootfs\aidaptivclaw.tar.gz" if you haven't run `build-rootfs.ps1` yet. That's fine — we just need ISCC to parse the script.

If you see Pascal syntax errors in the `[Code]` section, fix them.

**Step 4: Commit**

```bash
git add installer/openclaw.iss
git commit -m "installer: switch openclaw.iss from Windows-native to WSL rootfs install"
```

---

### Task 2.2: Replace `post-install.cmd` with `post-install.ps1` (WSL provisioning)

**Files:**
- Create: `installer/post-install.ps1`
- Delete: `installer/post-install.cmd` (in Task 2.5 after verifying replacement works)

**Step 1: Write the new provisioning script**

```powershell
<#
.SYNOPSIS
    aiDAPTIVClaw post-install: provisions the WSL2 sandbox.

.DESCRIPTION
    Replaces the previous Windows-native build pipeline. Steps:
    1. Verify WSL2 is available (offer to install if not).
    2. Verify CPU virtualization / Hyper-V is enabled.
    3. Import installer/aidaptivclaw.tar.gz as a private WSL distro `aidaptivclaw`.
    4. Configure %USERPROFILE%\.wslconfig vmIdleTimeout (prevent gateway from being killed by idle shutdown).
    5. First-boot the distro to trigger systemd + the gateway service.
    6. Smoke test: HTTP GET http://localhost:18789/ should return 200 within 30s.

.PARAMETER AppDir
    Directory where the installer placed files (passed by Inno Setup as {app}).
.PARAMETER FromInstaller
    Set to $true when called from Inno Setup [Code] section.
#>
param(
    [Parameter(Mandatory=$true)] [string]$AppDir,
    [switch]$FromInstaller
)

$ErrorActionPreference = "Stop"
$LogFile = Join-Path $AppDir "install.log"
$Tarball = Join-Path $AppDir "aidaptivclaw.tar.gz"
$DistroName = "aidaptivclaw"
$DistroDir = Join-Path $AppDir "distro"

function Write-Log {
    param([string]$Message)
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts] $Message"
    Write-Host $line
    Add-Content -Path $LogFile -Value $line
}

# --- Step 1: Verify WSL ---
Write-Log "[1/5] Checking WSL2..."
$wslStatus = & wsl --status 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Log "WSL is not installed. Running 'wsl --install --no-distribution'..."
    & wsl --install --no-distribution
    if ($LASTEXITCODE -ne 0) {
        Write-Log "ERROR: 'wsl --install' failed. User likely needs to enable virtualization in BIOS or update Windows."
        if (-not $FromInstaller) { Read-Host "Press Enter to exit" }
        exit 1
    }
    Write-Log "WSL installed. A reboot may be required before continuing."
    Write-Log "After reboot, re-run this script: $PSCommandPath -AppDir '$AppDir'"
    exit 2  # special exit code: reboot required
}
if ($wslStatus -match "Default Version: 1") {
    Write-Log "Setting WSL default version to 2..."
    & wsl --set-default-version 2
}
Write-Log "  WSL2 OK."

# --- Step 2: Verify tarball exists ---
Write-Log "[2/5] Checking rootfs tarball..."
if (-not (Test-Path $Tarball)) {
    Write-Log "ERROR: rootfs not found: $Tarball"
    if (-not $FromInstaller) { Read-Host "Press Enter to exit" }
    exit 1
}
$sizeMb = [math]::Round((Get-Item $Tarball).Length / 1MB, 1)
Write-Log "  Tarball OK ($sizeMb MB)."

# --- Step 3: Import distro ---
Write-Log "[3/5] Importing distro '$DistroName'..."
# If a previous install left a distro behind, unregister it first
$existing = & wsl --list --quiet 2>&1
if ($existing -match "^$DistroName`$") {
    Write-Log "  Removing previous '$DistroName' distro..."
    & wsl --unregister $DistroName 2>&1 | Out-Null
}
if (-not (Test-Path $DistroDir)) {
    New-Item -ItemType Directory -Path $DistroDir -Force | Out-Null
}
& wsl --import $DistroName $DistroDir $Tarball --version 2 2>&1 | Tee-Object -FilePath $LogFile -Append
if ($LASTEXITCODE -ne 0) {
    Write-Log "ERROR: 'wsl --import' failed."
    if (-not $FromInstaller) { Read-Host "Press Enter to exit" }
    exit 1
}
Write-Log "  Distro imported."

# --- Step 4: Configure host .wslconfig (vmIdleTimeout) ---
Write-Log "[4/5] Configuring %USERPROFILE%\.wslconfig..."
$wslConfigPath = Join-Path $env:USERPROFILE ".wslconfig"
$wslConfigContent = ""
if (Test-Path $wslConfigPath) {
    $wslConfigContent = Get-Content $wslConfigPath -Raw
}
# Idempotent: only add the [wsl2] vmIdleTimeout=-1 section if not already present.
# vmIdleTimeout=-1 prevents WSL from auto-shutting down the gateway after 60s idle.
if ($wslConfigContent -notmatch "(?ms)^\[wsl2\][^\[]*vmIdleTimeout") {
    if ($wslConfigContent.Length -gt 0 -and -not $wslConfigContent.EndsWith("`n")) {
        $wslConfigContent += "`r`n"
    }
    $wslConfigContent += @"

# Added by aiDAPTIVClaw installer: prevent the sandbox VM from being killed by idle shutdown.
[wsl2]
vmIdleTimeout=-1
"@
    Set-Content -Path $wslConfigPath -Value $wslConfigContent -Encoding UTF8
    Write-Log "  .wslconfig updated. Existing WSL distros will need 'wsl --shutdown' to apply."
} else {
    Write-Log "  .wslconfig already configured."
}

# --- Step 5: First boot + smoke test ---
Write-Log "[5/5] First boot + smoke test..."
# Trigger boot (systemd starts openclaw-gateway.service automatically because it was systemctl enable'd in the rootfs)
& wsl -d $DistroName -u root -e /bin/true
Start-Sleep -Seconds 3

# Wait for the gateway HTTP endpoint to respond on Windows-side localhost (WSL2 auto-forwarding)
$ready = $false
for ($i = 0; $i -lt 30; $i++) {
    try {
        $resp = Invoke-WebRequest -Uri "http://localhost:18789/" -UseBasicParsing -TimeoutSec 2 -ErrorAction Stop
        if ($resp.StatusCode -ge 200 -and $resp.StatusCode -lt 500) {
            $ready = $true
            break
        }
    } catch {
        # Not ready yet
    }
    Start-Sleep -Seconds 1
}
if (-not $ready) {
    Write-Log "WARNING: gateway did not respond on http://localhost:18789 within 30s."
    Write-Log "  Check: wsl -d $DistroName -u root -e systemctl status openclaw-gateway.service"
    # Don't fail install: user may want to debug. Just warn.
} else {
    Write-Log "  Gateway is responding on http://localhost:18789."
}

Write-Log "=========================================="
Write-Log "Setup complete!"
Write-Log "=========================================="
exit 0
```

**Step 2: Lint check the script**

Run:

```powershell
Invoke-ScriptAnalyzer installer\post-install.ps1
```

Expected: no errors. Warnings about `Write-Host` are acceptable (we want console output for the user).

If `Invoke-ScriptAnalyzer` is not installed: `Install-Module PSScriptAnalyzer -Scope CurrentUser`.

**Step 3: Commit**

```bash
git add installer/post-install.ps1
git commit -m "installer: add post-install.ps1 for WSL distro provisioning"
```

---

### Task 2.3: Update `openclaw.iss` `[Code]` section to call the PowerShell script

**Files:**
- Modify: `installer/openclaw.iss`

**Step 1: Replace `RunPostInstallBuild` procedure**

In `installer/openclaw.iss`, find the `RunPostInstallBuild` procedure (around line 282-337). Replace it with:

```pascal
{ --- Post-install: provision WSL sandbox --- }

procedure RunPostInstallBuild;
var
  ResultCode: Integer;
  AppDir, LogFile, Params: String;
  ExecResult: Boolean;
begin
  BuildSucceeded := False;
  AppDir := ExpandConstant('{app}');
  LogFile := AppDir + '\install.log';

  Params := '-NoProfile -ExecutionPolicy Bypass -File "' + AppDir + '\post-install.ps1" -AppDir "' + AppDir + '" -FromInstaller';

  SaveStringToFile(LogFile, '=== Installer [Code] diagnostic ===' + #13#10, False);
  SaveStringToFile(LogFile, 'invocation: powershell.exe ' + Params + #13#10, True);

  WizardForm.StatusLabel.Caption := 'Provisioning WSL sandbox (this may take a few minutes)...';
  WizardForm.Refresh;

  ExecResult := Exec('powershell.exe', Params, AppDir,
                     SW_SHOWNORMAL, ewWaitUntilTerminated, ResultCode);

  SaveStringToFile(LogFile, 'exec_result: ' + IntToStr(Ord(ExecResult)) + ', exit_code: ' + IntToStr(ResultCode) + #13#10, True);

  if ExecResult and (ResultCode = 0) then
  begin
    BuildSucceeded := True;
  end
  else if ExecResult and (ResultCode = 2) then
  begin
    { Special exit code from post-install.ps1: WSL was just installed, reboot required }
    MsgBox('WSL2 was just installed.' + #13#10 + #13#10 +
           'Please reboot Windows, then run:' + #13#10 +
           '  ' + AppDir + '\post-install.ps1 -AppDir "' + AppDir + '"' + #13#10 + #13#10 +
           'to complete the setup.',
           mbInformation, MB_OK);
    BuildSucceeded := False;
  end
  else
  begin
    MsgBox('WSL sandbox provisioning failed (exit code: ' + IntToStr(ResultCode) + ').' + #13#10 + #13#10 +
           'Check the log file:' + #13#10 +
           LogFile + #13#10 + #13#10 +
           'You can retry by running:' + #13#10 +
           'powershell.exe -File "' + AppDir + '\post-install.ps1" -AppDir "' + AppDir + '"',
           mbError, MB_OK);
    BuildSucceeded := False;
  end;
end;
```

**Step 2: Remove `InstallDaemon` and `ConfigureCloudProvider` procedures (and their call sites)**

`InstallDaemon` is no longer needed (Q7 = A, no auto-start). `ConfigureCloudProvider` belongs to the old Windows-native flow and now happens inside the WSL gateway via the WebUI on first launch.

In `CurStepChanged` (around line 426-434), simplify to:

```pascal
procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then
  begin
    WriteConfigFile;
    RunPostInstallBuild;
  end;
end;
```

Then delete `InstallDaemon` and `ConfigureCloudProvider` procedures and their helpers (`GetProviderId`, `GetProviderBaseUrl`, etc., lines ~84-143). Also delete the `CloudPage` UI in `InitializeWizard` (lines ~147-208) — replace `InitializeWizard` with an empty stub (or remove it entirely if no other custom page exists).

**Step 3: Update `WriteConfigFile` to write WSL-style paths**

Find `WriteConfigFile` (line 235) and update the path replacement on line 268. The default workspace path should now be `/home/openclaw/workspace` (not a Windows path). The template on line 49 of `openclaw-template.json` will also be updated in Task 2.6.

Replace this part of `WriteConfigFile`:

```pascal
Content := ReplaceSubstring(Content, 'C:\\Users\\user\\', ReplaceSubstring(UserProfile, '\', '\\') + '\\');
```

With:

```pascal
{ The template stores WSL paths directly; no Windows path substitution needed. }
{ The host-side openclaw.json is only consulted by the (now removed) Windows CLI;
  the gateway inside WSL reads /home/openclaw/.openclaw/openclaw.json which is
  initialized by first-boot of the rootfs. The host-side file is kept for
  uninstall-time data prompts. }
```

**Step 4: Verify .iss still compiles**

Run:

```powershell
& "C:\Program Files (x86)\Inno Setup 6\ISCC.exe" installer\openclaw.iss 2>&1 | Select-String -Pattern "error|Error" -Context 0,2
```

Expected: no error lines. If the rootfs tarball is missing, ISCC will report it — that's fine.

**Step 5: Commit**

```bash
git add installer/openclaw.iss
git commit -m "installer: rewire [Code] to call post-install.ps1 for WSL setup"
```

---

### Task 2.4: Update `[UninstallRun]` and `CurUninstallStepChanged` to remove WSL distro

**Files:**
- Modify: `installer/openclaw.iss`

**Step 1: Update uninstall procedure**

Replace `CurUninstallStepChanged` (around line 455-491) with:

```pascal
procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  AppDir, ConfigDir: String;
  ResultCode: Integer;
begin
  if CurUninstallStep = usUninstall then
  begin
    AppDir := ExpandConstant('{app}');

    { Unregister the WSL distro (this destroys the sandbox VM and all data inside it). }
    Exec(ExpandConstant('{cmd}'),
         '/C wsl --unregister aidaptivclaw',
         AppDir, SW_HIDE, ewWaitUntilTerminated, ResultCode);
  end;

  if CurUninstallStep = usPostUninstall then
  begin
    AppDir := ExpandConstant('{app}');

    { Remove any remaining files in the app directory }
    if DirExists(AppDir) then
      DelTree(AppDir, True, True, True);

    { Ask about removing the host-side config dir (mostly empty after the move to WSL,
      but may contain user-saved data from the old Windows-native version). }
    ConfigDir := ExpandConstant('{%USERPROFILE}') + '\.openclaw';
    if DirExists(ConfigDir) then
    begin
      if MsgBox('Do you want to remove aiDAPTIVClaw configuration files at?' + #13#10 +
                ConfigDir + #13#10 + #13#10 +
                'Workspace data inside the WSL sandbox has already been removed.',
                mbConfirmation, MB_YESNO) = IDYES then
      begin
        DelTree(ConfigDir, True, True, True);
      end;
    end;
  end;
end;
```

**Step 2: Update `[UninstallDelete]` section**

Replace lines 70-74:

```pascal
[UninstallDelete]
Type: filesandordirs; Name: "{app}\node_modules"
Type: filesandordirs; Name: "{app}\dist"
Type: filesandordirs; Name: "{app}\.pnpm-store"
Type: files; Name: "{app}\install.log"
```

With:

```pascal
[UninstallDelete]
Type: filesandordirs; Name: "{app}\distro"
Type: files; Name: "{app}\install.log"
Type: files; Name: "{app}\aidaptivclaw.tar.gz"
```

**Step 3: Commit**

```bash
git add installer/openclaw.iss
git commit -m "installer: cleanly unregister WSL distro on uninstall"
```

---

### Task 2.5: Delete obsolete Windows-side files

**Files:**
- Delete: `installer/post-install.cmd`
- Delete: `installer/configure-cloud.cjs`

**Step 1: Verify nothing else references these files**

Run:

```powershell
rg -l "post-install\.cmd|configure-cloud\.cjs" --glob "!docs/plans/**"
```

Expected: only `installer/openclaw.iss` and possibly `scripts/build-installer.ps1`. Both should be cleaned up by Tasks 2.3 and 3.1 respectively.

**Step 2: Delete the files**

```powershell
git rm installer/post-install.cmd installer/configure-cloud.cjs
```

**Step 3: Commit**

```bash
git commit -m "installer: remove Windows-native build helpers (replaced by WSL flow)"
```

---

### Task 2.6: Update `openclaw-template.json` for in-WSL paths

**Files:**
- Modify: `installer/openclaw-template.json`

**Step 1: Update default workspace path on line 49**

Change:

```json
"workspace": "C:\\Users\\user\\.openclaw\\workspace",
```

To:

```json
"workspace": "/home/openclaw/workspace",
```

This template is now baked into the rootfs at build time (we'll wire that in Task 3.2), and read by the gateway running inside WSL.

**Step 2: Commit**

```bash
git add installer/openclaw-template.json
git commit -m "installer: update template default workspace to WSL path"
```

---

## Phase 3 — Build Pipeline & Launcher

### Task 3.1: Update `scripts/build-installer.ps1` to invoke rootfs build

**Files:**
- Modify: `scripts/build-installer.ps1`

**Step 1: Replace the source-staging steps with a rootfs build call**

The previous script staged repo source + Node.js into `installer\build\`. Now we need to run `build-rootfs.ps1` and let Inno Setup pick up `installer\rootfs\aidaptivclaw.tar.gz`.

Find Step 1 + Step 2 (lines ~76-200 in the existing script). Replace them with:

```powershell
# --- Step 1: Build WSL rootfs ---
Write-Host ""
Write-Host "[Step 1] Building WSL rootfs..." -ForegroundColor Yellow

$RootfsScript = Join-Path $RepoRoot "scripts\build-rootfs.ps1"
$RootfsTarball = Join-Path $RepoRoot "installer\rootfs\aidaptivclaw.tar.gz"

# Skip rebuild if the tarball is newer than any tracked file (caching for fast iteration)
$rebuild = $true
if (Test-Path $RootfsTarball) {
    $tarballTime = (Get-Item $RootfsTarball).LastWriteTime
    $newestSrc = (git ls-files | ForEach-Object { Get-Item $_ -ErrorAction SilentlyContinue } | Sort-Object LastWriteTime -Descending | Select-Object -First 1).LastWriteTime
    if ($tarballTime -gt $newestSrc) {
        Write-Host "  Cached rootfs is up-to-date, skipping rebuild." -ForegroundColor Green
        $rebuild = $false
    }
}
if ($rebuild) {
    & $RootfsScript -NodeVersion $NodeVersion
    if ($LASTEXITCODE -ne 0) { throw "rootfs build failed" }
}

if (-not (Test-Path $RootfsTarball)) {
    throw "Rootfs tarball missing after build: $RootfsTarball"
}
$tarballMb = [math]::Round((Get-Item $RootfsTarball).Length / 1MB, 1)
Write-Host "  Rootfs ready ($tarballMb MB)." -ForegroundColor Green
```

Remove the now-obsolete steps:
- Old "Step 1: Download Node.js" (lines 76-98) — Node is inside the rootfs now.
- Old "Step 2: Stage source code" (lines 100-200+) — entire repo no longer copied to Windows.

The final ISCC invocation step at the bottom of the script stays the same.

**Step 2: Verify the script runs**

Run:

```powershell
.\scripts\build-installer.ps1 -AppVersion 2026.4.23
```

Expected:
- First run: invokes `build-rootfs.ps1` (10-20 min); then ISCC produces `installer\output\aidaptiv-claw-setup-2026.4.23.exe`
- Second run with no source changes: skips rootfs build, jumps straight to ISCC (~10s)

The output `.exe` should be approximately 600MB-1.2GB (was ~50-100MB before).

**Step 3: Commit**

```bash
git add scripts/build-installer.ps1
git commit -m "scripts: build-installer now bundles WSL rootfs instead of Windows source"
```

---

### Task 3.2: Rewrite `openclaw-launcher.cmd` to start WSL + open browser

**Files:**
- Modify: `installer/openclaw-launcher.cmd`

**Step 1: Replace the entire file**

```batch
@echo off
setlocal

:: aiDAPTIVClaw launcher (WSL2 sandbox edition)
:: Steps:
::   1. Boot the aidaptivclaw distro (systemd starts openclaw-gateway.service automatically)
::   2. Wait for the gateway HTTP endpoint to respond on http://localhost:18789
::   3. Open the default browser to the dashboard URL with the auth token.

set "DISTRO=aidaptivclaw"

:: --- Step 1: Trigger WSL distro boot ---
:: Running any command inside the distro causes WSL to start the VM (cold boot ~5-10s).
:: We run /bin/true: it does nothing but forces systemd PID 1 to come up,
:: which in turn starts the systemctl-enabled openclaw-gateway.service.
wsl -d %DISTRO% -u root -e /bin/true >nul 2>&1
if errorlevel 1 (
    echo [aiDAPTIVClaw] Failed to start WSL distro %DISTRO%.
    echo [aiDAPTIVClaw] Try running: wsl -d %DISTRO% -u root -e /bin/true
    echo [aiDAPTIVClaw] If the distro is missing, reinstall aiDAPTIVClaw.
    pause
    exit /b 1
)

:: --- Step 2: Wait for gateway port to become reachable ---
:: WSL2 auto-forwards 127.0.0.1:18789 inside the distro to localhost:18789 on Windows.
set /a TRIES=0
:waitloop
:: powershell one-liner: try to TCP-connect, exit 0 on success.
powershell -NoProfile -Command "$c=New-Object System.Net.Sockets.TcpClient; try { $c.Connect('127.0.0.1', 18789); $c.Close(); exit 0 } catch { exit 1 }" >nul 2>&1
if not errorlevel 1 goto :ready
set /a TRIES=TRIES+1
if %TRIES% GEQ 30 (
    echo [aiDAPTIVClaw] Gateway did not respond on port 18789 within 30 seconds.
    echo [aiDAPTIVClaw] Check status with: wsl -d %DISTRO% -u root -e systemctl status openclaw-gateway.service
    pause
    exit /b 1
)
timeout /t 1 /nobreak >nul
goto :waitloop

:ready
:: --- Step 3: Open browser via 'openclaw dashboard' inside WSL ---
:: This generates a URL with #token=... so the WebUI auto-authenticates.
:: We then echo the URL on Windows and `start` it.
for /f "delims=" %%U in ('wsl -d %DISTRO% -u openclaw -e /opt/node/bin/node /opt/openclaw/openclaw.mjs dashboard --print-url 2^>nul') do set "URL=%%U"
if "%URL%"=="" set "URL=http://localhost:18789/"
start "" "%URL%"
exit /b 0
```

> **Note on `--print-url`:** The current `openclaw dashboard` command opens the browser directly, which inside WSL would try to launch a Linux browser (none installed). We need `dashboard` to support a `--print-url` flag that prints the URL to stdout instead of trying to open it. This is a small OpenClaw CLI change tracked in Task 3.3.

**Step 2: Verify the launcher logic offline (without OpenClaw running)**

Run:

```powershell
cmd /c installer\openclaw-launcher.cmd
```

Expected (assuming no aidaptivclaw distro yet): "Failed to start WSL distro aidaptivclaw" + pause.

**Step 3: Commit**

```bash
git add installer/openclaw-launcher.cmd
git commit -m "installer: rewrite launcher to start WSL distro and open browser"
```

---

### Task 3.3: Add `--print-url` flag to `openclaw dashboard` command

**Files:**
- Modify: search for the existing `dashboard` command implementation

**Step 1: Locate the dashboard command**

Run:

```powershell
rg -l "dashboard" --glob "src/cli/**/*.ts" --glob "src/commands/**/*.ts"
```

Find the file that registers the `dashboard` subcommand.

**Step 2: Add `--print-url` option**

Add a new flag `--print-url` (boolean, default false). When true:
- Compute the dashboard URL (same logic as currently used to construct the URL passed to the OS browser opener)
- `console.log(url)` and `process.exit(0)` instead of calling the OS open-browser routine

**Step 3: Test the flag**

Run (after rebuilding OpenClaw with the change):

```bash
node openclaw.mjs dashboard --print-url
```

Expected: prints a single URL like `http://localhost:18789/#token=abcdef...` to stdout, exits 0, does NOT try to open a browser.

**Step 4: Commit**

```bash
git add <modified files>
git commit -m "cli: add --print-url flag to dashboard command for headless WSL launcher"
```

---

### Task 3.4: Verify Win11 22H2+ mirrored mode hint

**Files:**
- Modify: `installer/post-install.ps1`

**Step 1: Add Win11 22H2+ detection at the end of `post-install.ps1`**

Append before the final `exit 0`:

```powershell
# --- Bonus: hint Win11 22H2+ users about mirrored networking ---
$winBuild = [int](Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" CurrentBuildNumber).CurrentBuildNumber
if ($winBuild -ge 22621) {
    Write-Log ""
    Write-Log "TIP: You are on Windows 11 22H2 or later. For better networking performance,"
    Write-Log "     consider enabling WSL mirrored networking by adding this to %USERPROFILE%\.wslconfig:"
    Write-Log ""
    Write-Log "       [wsl2]"
    Write-Log "       networkingMode=mirrored"
    Write-Log ""
    Write-Log "     Then run 'wsl --shutdown' to apply. (Optional; localhost forwarding works either way.)"
}
```

**Step 2: Commit**

```bash
git add installer/post-install.ps1
git commit -m "installer: hint Win11 22H2+ users about mirrored networking option"
```

---

## Phase 4 — End-to-End Verification

### Task 4.1: Build a full installer and install on a clean Windows VM

**Files:** None (manual verification).

**Step 1: Build the installer**

Run:

```powershell
.\scripts\build-installer.ps1 -AppVersion 2026.4.23-wsltest
```

Expected output: `installer\output\aidaptiv-claw-setup-2026.4.23-wsltest.exe`, size ~600MB-1.2GB.

**Step 2: Install on a clean Win10 22H2 VM**

(Use Hyper-V / VMware / VirtualBox snapshot.)

1. Copy the `.exe` to the VM
2. Run the installer
3. Watch the post-install console window for the "[5/5] First boot + smoke test..." line
4. Verify it prints "Gateway is responding on http://localhost:18789."
5. Verify desktop icon was created
6. Click desktop icon → browser should open to the WebUI within ~10 seconds

**Step 3: Verify sandbox is in effect**

In a Windows PowerShell on the VM:

```powershell
# OpenClaw should NOT see C:\ inside the sandbox
wsl -d aidaptivclaw -u openclaw -e ls /mnt/ 2>&1
# Expected: empty

# OpenClaw should NOT be able to write outside its allowlist
wsl -d aidaptivclaw -u openclaw -e bash -c "echo x > /etc/x.txt; echo result=`$?"
# Expected: result=1 (Permission denied)

# But CAN write to workspace
wsl -d aidaptivclaw -u openclaw -e bash -c "echo x > /home/openclaw/workspace/x.txt; cat /home/openclaw/workspace/x.txt"
# Expected: x

# Workspace visible from Windows
ls "\\wsl.localhost\aidaptivclaw\home\openclaw\workspace"
# Expected: x.txt
```

**Step 4: Verify uninstall removes the distro**

```powershell
# Uninstall via Control Panel or:
& "${env:LOCALAPPDATA}\aiDAPTIVClaw\unins000.exe" /SILENT

# Verify distro is gone
wsl --list --quiet
# Expected: 'aidaptivclaw' should NOT appear
```

**Step 5: No commit (verification only). If any step failed, file an issue and trace back to the responsible task.**

---

### Task 4.2: Smoke test on Win11 22H2+

**Files:** None (manual verification).

**Step 1-4:** Repeat Task 4.1 on a Win11 22H2+ VM.

**Step 5: Verify the mirrored mode hint appears in the install log**

Open `%LOCALAPPDATA%\aiDAPTIVClaw\install.log` and grep for "TIP: You are on Windows 11 22H2".

Expected: hint message present.

---

## Phase 5 — Documentation

### Task 5.1: Update README and user docs

**Files:**
- Modify (or create): `docs/install/windows.md`

**Step 1: Document the new install experience**

Cover:
- Prerequisites: Win10 2004+ or Win11; CPU virtualization enabled in BIOS
- What happens during install (WSL distro import, ~5 min)
- Where the workspace lives: `\\wsl.localhost\aidaptivclaw\home\openclaw\workspace` (with screenshot showing how to pin it in Explorer)
- How to authorize a Windows folder for read-only access (when D-2 is implemented; for now: not yet supported, file Issue #...)
- How to uninstall (auto-unregisters distro)
- Troubleshooting:
  - "Gateway did not respond on port 18789" → check `wsl -d aidaptivclaw -u root -e systemctl status openclaw-gateway.service`
  - "wsl --import failed" → enable virtualization in BIOS / install Hyper-V

**Step 2: Commit**

```bash
git add docs/install/windows.md
git commit -m "docs: document WSL2 sandbox install on Windows"
```

---

### Task 5.2: Update brainstorm summary status

**Files:**
- Modify: `docs/plans/2026-04-23-wsl-sandbox-brainstorm-summary.md`

**Step 1: Mark status as Implemented**

Change the document header to add an "Implemented in" line linking back to this design plan.

**Step 2: Commit**

```bash
git add docs/plans/2026-04-23-wsl-sandbox-brainstorm-summary.md
git commit -m "docs: mark WSL sandbox brainstorm as implemented"
```

---

## Phase 6 — Known Risks & Follow-ups

These are intentionally NOT in the MVP. Track as follow-up issues.

| # | Risk / Limitation | Mitigation in MVP | Follow-up |
|---|---|---|---|
| 1 | **Network is fully open inside the sandbox.** Prompt-injected agent can POST workspace contents to any URL. | None — this is Q4=A in the brainstorm. | File issue: design domain allowlist (iptables + dnsmasq + ipset) for Phase 2. |
| 2 | **D-2 (per-folder read-only authorization) is not implemented.** Users have no UI to expose Windows folders read-only. | Manual workaround: user copies files into `\\wsl.localhost\...\workspace`. | File issue: WebUI button + WSL `mount --bind -o ro` orchestration. |
| 3 | **Cold start latency 5-15s on first launcher click.** | Launcher prints status; future: splash screen / preload. | File issue: pre-warm WSL distro in `Run` registry on user login (opt-in). |
| 4 | **Installer is ~1GB.** | Acceptable for MVP. | If size becomes a problem, switch to Q2=C (online build) but accept worse UX. |
| 5 | **CI build adds 7-20 min/release.** | Use Docker layer cache and `git ls-files` change detection. | Optimize: split rootfs into two layers (system + OpenClaw) so OpenClaw-only changes skip the apt step. |
| 6 | **WSL2 not available on Win10 1909 / Server 2019 / older.** | Documented prerequisite. | Out of scope; users on those versions cannot use this product. |
| 7 | **Sandbox-aware Cursor IDE / VS Code integration not done.** | Users still edit files via UNC path; Cursor's MCP can still talk to `localhost:18789`. | File issue: investigate if Cursor needs a sandbox-aware connector. |
| 8 | **No telemetry on sandbox effectiveness.** | None. | File issue: ship optional opt-in audit log of denied syscalls / mounts. |

---

## Execution Handoff

Plan complete and saved to `docs/plans/2026-04-23-wsl-sandbox-design.md`.

Two execution options:

**1. Subagent-Driven (this session)** — dispatch a fresh subagent per task, code review between tasks, fast iteration.

**2. Parallel Session (separate)** — open a new session in a worktree with the executing-plans skill, batch execution with checkpoints.

**Which approach?**
