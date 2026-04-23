# WSL2 Sandbox for aiDAPTIVClaw — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans` to implement this plan task-by-task.
>
> Each task is bite-sized (2-15 min). Because this is installer/OS-level work, traditional unit tests don't apply; each task ends with a concrete verification command and expected output instead.

**Goal:** Convert aiDAPTIVClaw from a native Windows installation (full user privileges) into a WSL2-confined installation (non-root user inside an isolated Ubuntu 24.04 distro with systemd hardening), so OpenClaw can no longer read arbitrary Windows files or escalate privileges if compromised.

**Architecture:** Installer ships a pre-built Ubuntu 24.04 rootfs (`aidaptivclaw.tar.gz`) containing a fully built OpenClaw under `/opt/openclaw`. On install, `wsl --import` registers the rootfs as a private distro `aidaptivclaw`. A systemd unit (`openclaw-gateway.service`) starts the gateway as the non-root `openclaw` user with hardening directives confining writes to `/home/openclaw/{workspace,.openclaw}` and `/tmp`. The Windows launcher only triggers `wsl.exe -d aidaptivclaw` and opens the browser at `http://localhost:18789` (reachable via WSL2 default localhost forwarding).

**Build pipeline:** Rootfs is built natively in WSL (no Docker). A throwaway WSL distro is created from Canonical's official Ubuntu 24.04 WSL base rootfs, a bash provisioning script installs Node + pnpm + builds OpenClaw, then `wsl --export` produces the shippable tarball. Source code is injected into the build distro via `git archive HEAD | wsl -e tar -xf -` (no `/mnt/c` mount needed, only git-tracked files included).

**Tech Stack:** Inno Setup (installer), Bash (rootfs provision script), WSL2, Ubuntu 24.04 (Canonical WSL rootfs), systemd, Node.js 22+, pnpm.

**Reference:** Decisions are summarized in `docs/plans/2026-04-23-wsl-sandbox-brainstorm-summary.md`. Read that first for context on every "why".

---

## Phase 0 — Setup & Prerequisites

### Task 0.1: Confirm host build prerequisites

**Files:** None (host check only).

**Step 1: Verify Inno Setup 6 is installed**

Run (PowerShell):

```powershell
& "C:\Program Files (x86)\Inno Setup 6\ISCC.exe" /? | Select-Object -First 1
```

Expected: `Inno Setup 6 Command-Line Compiler`. If missing, install from https://jrsoftware.org/isdl.php.

**Step 2: Verify WSL2 is installed**

The same WSL is used for both building the rootfs and (in Task 4.x) testing the resulting installer. There is no Docker dependency.

Run:

```powershell
wsl --status
```

Expected: contains `Default Version: 2`.

If `wsl.exe` returns "Linux 子系統未安裝" / "Linux is not installed", run:

```powershell
wsl --install --no-distribution
```

Then **reboot Windows** (required after WSL feature activation) and re-run Step 2.

If `Default Version: 1`, run `wsl --set-default-version 2`.

**Step 3: Verify CPU virtualization is enabled**

Run:

```powershell
(Get-CimInstance Win32_Processor).VirtualizationFirmwareEnabled
```

Expected: `True`. If `False`, enable Intel VT-x / AMD-V in BIOS — WSL2 cannot run without it.

**Step 4: No commit (environment-only check)**

---

## Phase 1 — Rootfs Build Pipeline (CI side)

> This phase produces `aidaptivclaw.tar.gz`, a pre-built Ubuntu 24.04 rootfs containing OpenClaw, ready to be embedded in the installer.

### Task 1.1: Create rootfs provisioning script

**Files:**
- Create: `installer/rootfs/provision.sh`
- Create: `installer/rootfs/.gitignore` (ignore `.cache/`)

**Background:** Instead of Docker, the rootfs is built inside a throwaway WSL distro that is bootstrapped from Canonical's official Ubuntu 24.04 WSL rootfs. `provision.sh` is the single bash script that runs **as root inside the build distro** and turns a vanilla Ubuntu into the shippable rootfs. The orchestration script (Task 1.3) runs entirely on the Windows host using `wsl.exe`.

**Step 1: Write `installer/rootfs/provision.sh`**

```bash
#!/usr/bin/env bash
# Provision a vanilla Ubuntu 24.04 WSL rootfs into the shippable aidaptivclaw rootfs.
# Runs as root inside the throwaway build distro. Source code is expected at /tmp/openclaw-src,
# pre-staged by the orchestrator (Task 1.3) via `git archive | wsl tar -xf -`.
set -euo pipefail

NODE_VERSION="${NODE_VERSION:-22.11.0}"
PNPM_VERSION="${PNPM_VERSION:-9.12.0}"

export DEBIAN_FRONTEND=noninteractive

# 1. Base packages. systemd is mandatory because wsl.conf will enable [boot] systemd=true.
apt-get update
apt-get install -y --no-install-recommends \
    ca-certificates curl gnupg git python3 build-essential \
    dbus systemd systemd-sysv \
    sudo locales tzdata
locale-gen en_US.UTF-8
rm -rf /var/lib/apt/lists/*

# 2. Node.js 22 LTS — matches the version previously embedded in the Windows installer.
mkdir -p /opt/node
curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz" \
    | tar -xJ --strip-components=1 -C /opt/node
ln -sf /opt/node/bin/node /usr/local/bin/node

# 3. pnpm via standalone binary (deterministic, no global npm install).
mkdir -p /opt/pnpm
curl -fsSL "https://github.com/pnpm/pnpm/releases/download/v${PNPM_VERSION}/pnpm-linux-x64" \
    -o /opt/pnpm/pnpm
chmod +x /opt/pnpm/pnpm
ln -sf /opt/pnpm/pnpm /usr/local/bin/pnpm

# 4. Non-root runtime user. uid 1000 = conventional first user.
# nologin shell + no sudo group → cannot escalate even if process is compromised.
useradd --create-home --uid 1000 --shell /usr/sbin/nologin openclaw

# 5. Build OpenClaw as root for simplicity, chown to openclaw at the end.
# Build artefacts land in /opt/openclaw owned by the openclaw user.
test -d /tmp/openclaw-src || { echo "ERROR: /tmp/openclaw-src missing — orchestrator must stage source first" >&2; exit 1; }
cd /tmp/openclaw-src
pnpm install --ignore-scripts
pnpm rebuild esbuild sharp koffi protobufjs
pnpm build:docker
pnpm ui:build

mkdir -p /opt/openclaw
cp -a /tmp/openclaw-src/. /opt/openclaw/
chown -R openclaw:openclaw /opt/openclaw
rm -rf /tmp/openclaw-src

# 6. Install WSL boot config + systemd unit (created in Task 1.2, pre-staged at /tmp/rootfs-config/).
install -m 0644 /tmp/rootfs-config/wsl.conf /etc/wsl.conf
install -m 0644 /tmp/rootfs-config/openclaw-gateway.service /etc/systemd/system/openclaw-gateway.service
systemctl enable openclaw-gateway.service

# 7. Pre-create the writable allowlist directories referenced by the systemd unit's ReadWritePaths=.
install -d -m 0755 -o openclaw -g openclaw \
    /home/openclaw/workspace /home/openclaw/.openclaw /home/openclaw/readonly

# 8. Shrink rootfs: drop apt caches, build artefacts, build-time tooling.
apt-get purge -y build-essential || true
apt-get autoremove -y
apt-get clean
rm -rf /var/lib/apt/lists/* /var/cache/apt /tmp/* /var/tmp/* /root/.cache /root/.npm

echo "provision.sh: rootfs ready"
```

**Step 2: Create `installer/rootfs/.gitignore`**

```gitignore
# Cached Canonical base rootfs and build intermediates (see scripts/build-rootfs.ps1)
.cache/
*.tar
*.tar.gz
```

**Step 3: Lint shellcheck (best effort)**

```powershell
# Optional — skip if shellcheck not installed locally; CI will catch issues.
shellcheck installer/rootfs/provision.sh
```

Expected: no errors. SC2086 / SC2155 warnings are acceptable.

**Step 4: Commit**

```powershell
git add installer/rootfs/provision.sh installer/rootfs/.gitignore
git commit -m "installer: add rootfs provision.sh for WSL-native build"
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

### Task 1.3: Create rootfs build script (WSL-native)

**Files:**
- Create: `scripts/build-rootfs.ps1`

**Pipeline overview (no Docker):**

1. Download (and cache) Canonical's official Ubuntu 24.04 WSL base rootfs to `installer/rootfs/.cache/ubuntu-24.04-base.tar.gz`.
2. `wsl --import aidaptivclaw-build` from the cached base into a throwaway distro location.
3. Pre-stage `wsl.conf` + `openclaw-gateway.service` into `/tmp/rootfs-config/` inside the build distro.
4. Stream source code into the build distro: `git archive HEAD | wsl -d aidaptivclaw-build -u root -- tar -xf - -C /tmp/openclaw-src`. Only git-tracked files are included; no `node_modules`, no `.git` history, no `/mnt/c` mount required.
5. Run `provision.sh` inside the build distro as root.
6. Shut the distro down so all writes are flushed.
7. `wsl --export aidaptivclaw-build installer/rootfs/aidaptivclaw.tar.gz`.
8. `wsl --unregister aidaptivclaw-build` to delete the build distro.

**Step 1: Write `scripts/build-rootfs.ps1`**

```powershell
<#
.SYNOPSIS
    Build aidaptivclaw.tar.gz: a pre-built Ubuntu 24.04 WSL rootfs containing OpenClaw.

.DESCRIPTION
    Pure WSL pipeline (no Docker):
      1. Cache + load Canonical Ubuntu 24.04 WSL base rootfs.
      2. Import as throwaway distro `aidaptivclaw-build`.
      3. Stream tracked source via `git archive | wsl tar -xf -`.
      4. Run installer/rootfs/provision.sh inside the distro as root.
      5. Export the resulting filesystem to installer/rootfs/aidaptivclaw.tar.gz.
      6. Unregister the build distro.

    Build time on a typical workstation: ~15-25 min cold, ~5-10 min warm (base rootfs cached).

.PARAMETER NodeVersion
    Node.js version baked into the rootfs. Default 22.11.0.
.PARAMETER PnpmVersion
    pnpm version baked into the rootfs. Default 9.12.0.
.PARAMETER KeepBuildDistro
    Skip `wsl --unregister` at the end (useful for debugging).
#>
param(
    [string]$NodeVersion = "22.11.0",
    [string]$PnpmVersion = "9.12.0",
    [switch]$KeepBuildDistro
)

$ErrorActionPreference = "Stop"

$RepoRoot      = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$RootfsDir     = Join-Path $RepoRoot "installer\rootfs"
$CacheDir      = Join-Path $RootfsDir ".cache"
$BaseTarball   = Join-Path $CacheDir "ubuntu-24.04-base.tar.gz"
$OutputTarball = Join-Path $RootfsDir "aidaptivclaw.tar.gz"
$BuildDistro   = "aidaptivclaw-build"
$BuildDistroDir = Join-Path $CacheDir "build-distro"

# Canonical official Ubuntu 24.04 WSL rootfs — same image MS Store ships, but stable URL.
$BaseUrl = "https://cloud-images.ubuntu.com/wsl/noble/current/ubuntu-noble-wsl-amd64-wsl.rootfs.tar.gz"

function Step($n, $msg) {
    Write-Host "[$n] $msg" -ForegroundColor Yellow
}

function Invoke-Wsl {
    param([Parameter(Mandatory)][string[]]$Args)
    & wsl.exe @Args
    if ($LASTEXITCODE -ne 0) { throw "wsl $($Args -join ' ') failed (exit $LASTEXITCODE)" }
}

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "  aidaptivclaw rootfs builder (WSL native)" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan

# --- 0. Pre-flight ---
& wsl.exe --status | Out-Null
if ($LASTEXITCODE -ne 0) { throw "WSL2 not installed. See scripts/install-wsl.md or run 'wsl --install --no-distribution'." }
if (-not (Test-Path $CacheDir)) { New-Item -ItemType Directory -Path $CacheDir | Out-Null }

# Defensive: if a previous failed run left the build distro registered, drop it.
$existing = (& wsl.exe --list --quiet) -split "`r?`n" | ForEach-Object { $_.Trim() }
if ($existing -contains $BuildDistro) {
    Step "0" "Removing leftover build distro..."
    Invoke-Wsl @("--unregister", $BuildDistro)
}

# --- 1. Download Canonical base rootfs (cached) ---
if (-not (Test-Path $BaseTarball)) {
    Step "1/7" "Downloading Ubuntu 24.04 WSL base rootfs..."
    Invoke-WebRequest -Uri $BaseUrl -OutFile $BaseTarball -UseBasicParsing
} else {
    Step "1/7" "Using cached base rootfs ($BaseTarball)"
}

# --- 2. Import throwaway build distro ---
Step "2/7" "Importing build distro..."
if (Test-Path $BuildDistroDir) { Remove-Item -Recurse -Force $BuildDistroDir }
New-Item -ItemType Directory -Path $BuildDistroDir | Out-Null
Invoke-Wsl @("--import", $BuildDistro, $BuildDistroDir, $BaseTarball, "--version", "2")

# --- 3. Stage rootfs config files (consumed by provision.sh step 6) ---
Step "3/7" "Staging rootfs config files..."
Invoke-Wsl @("-d", $BuildDistro, "-u", "root", "--", "mkdir", "-p", "/tmp/rootfs-config", "/tmp/openclaw-src")
# Use `wsl --cd` so relative paths resolve against the Windows host.
$rootfsWin = ($RootfsDir -replace '\\','/') -replace '^([A-Za-z]):','/mnt/$($Matches[1].ToLower())'
# Above hack avoids needing /mnt: prefer `wslpath -u` instead.
$wslConfPath = (& wsl.exe -d $BuildDistro -u root -- wslpath -u "$RootfsDir\wsl.conf").Trim()
$svcPath     = (& wsl.exe -d $BuildDistro -u root -- wslpath -u "$RootfsDir\openclaw-gateway.service").Trim()
$provPath    = (& wsl.exe -d $BuildDistro -u root -- wslpath -u "$RootfsDir\provision.sh").Trim()
Invoke-Wsl @("-d", $BuildDistro, "-u", "root", "--", "cp", $wslConfPath, "/tmp/rootfs-config/wsl.conf")
Invoke-Wsl @("-d", $BuildDistro, "-u", "root", "--", "cp", $svcPath,     "/tmp/rootfs-config/openclaw-gateway.service")
Invoke-Wsl @("-d", $BuildDistro, "-u", "root", "--", "cp", $provPath,    "/tmp/provision.sh")
Invoke-Wsl @("-d", $BuildDistro, "-u", "root", "--", "chmod", "+x", "/tmp/provision.sh")

# --- 4. Stream tracked source code into the distro ---
# Why git archive: only commits tracked files, no node_modules, no junk, deterministic.
# Why `cmd /c` wrapper: PowerShell's pipeline corrupts binary streams; cmd preserves bytes.
Step "4/7" "Streaming source via git archive..."
Push-Location $RepoRoot
try {
    & cmd /c "git archive --format=tar HEAD | wsl.exe -d $BuildDistro -u root -- tar -xf - -C /tmp/openclaw-src"
    if ($LASTEXITCODE -ne 0) { throw "git archive | tar pipe failed" }
} finally {
    Pop-Location
}

# --- 5. Run provisioning script ---
Step "5/7" "Running provision.sh inside build distro (long step)..."
Invoke-Wsl @(
    "-d", $BuildDistro, "-u", "root",
    "--",
    "env", "NODE_VERSION=$NodeVersion", "PNPM_VERSION=$PnpmVersion",
    "/tmp/provision.sh"
)

# --- 6. Shut down the distro to flush filesystem writes ---
Step "6/7" "Shutting down build distro..."
Invoke-Wsl @("--terminate", $BuildDistro)

# --- 7. Export rootfs ---
Step "7/7" "Exporting rootfs to $OutputTarball ..."
if (Test-Path $OutputTarball) { Remove-Item -Force $OutputTarball }
Invoke-Wsl @("--export", $BuildDistro, $OutputTarball, "--format", "tar.gz")

if (-not $KeepBuildDistro) {
    Invoke-Wsl @("--unregister", $BuildDistro)
    Remove-Item -Recurse -Force $BuildDistroDir -ErrorAction SilentlyContinue
}

$SizeMb = [math]::Round((Get-Item $OutputTarball).Length / 1MB, 1)
Write-Host ""
Write-Host "Done. Output: $OutputTarball ($SizeMb MB)" -ForegroundColor Green
```

**Step 2: Run end-to-end**

```powershell
.\scripts\build-rootfs.ps1
```

Expected:
- Cold run: ~15-25 min (downloads Canonical base + Node + builds OpenClaw).
- Warm run: ~5-10 min (base rootfs cached, only OpenClaw rebuild).
- Output: `installer\rootfs\aidaptivclaw.tar.gz`, size approximately 500MB-1.2GB.

If `pnpm install` or `build:docker` fails, the issue is in OpenClaw itself, not the pipeline. Inspect with `-KeepBuildDistro` then `wsl -d aidaptivclaw-build -u root` to drop into a shell.

**Step 3: Verify the tarball imports correctly**

```powershell
$testDir = "$env:TEMP\aidaptivclaw-test"
New-Item -Force -ItemType Directory $testDir | Out-Null
wsl --import aidaptivclaw-test $testDir installer\rootfs\aidaptivclaw.tar.gz
wsl -d aidaptivclaw-test -u openclaw -e /opt/node/bin/node --version
```

Expected: prints `v22.11.0`.

Cleanup:

```powershell
wsl --unregister aidaptivclaw-test
Remove-Item -Recurse -Force $testDir
```

**Step 4: Commit**

```powershell
git add scripts/build-rootfs.ps1
git commit -m "scripts: add WSL-native rootfs build pipeline"
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
- First run: invokes `build-rootfs.ps1` (15-25 min cold, 5-10 min warm); then ISCC produces `installer\output\aidaptiv-claw-setup-2026.4.23.exe`
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
| 5 | **CI build adds 15-25 min/release.** | Cache Canonical base rootfs in `installer/rootfs/.cache/`; CI restores cache between runs. | Optimize: snapshot a "system-only" intermediate rootfs (post-apt, pre-OpenClaw) so day-to-day OpenClaw changes skip the apt step. |
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
