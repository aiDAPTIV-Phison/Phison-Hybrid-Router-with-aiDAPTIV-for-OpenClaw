# WSL2 Sandbox for aiDAPTIVClaw — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans` to implement this plan task-by-task.
>
> Each task is bite-sized (2-15 min). Because this is installer/OS-level work, traditional unit tests don't apply; each task ends with a concrete verification command and expected output instead.

> **🔄 REVISION 2026-04-23 — switched from Q2=A (offline) to Q2=C (online build)**
>
> The original plan baked OpenClaw + Node.js + apt packages into a pre-built `aidaptivclaw.tar.gz` rootfs at build time, requiring the build machine to have WSL2 + VT-x. This blocked developers whose CPU only has VT-d, not VT-x.
>
> The new design ships:
>   1. A vanilla **Canonical Ubuntu 24.04 WSL base rootfs** (~340 MB, downloaded once at build time and cached). Source URL: `https://cloud-images.ubuntu.com/wsl/releases/24.04/current/ubuntu-noble-wsl-amd64-wsl.rootfs.tar.gz` — the older `/wsl/<codename>/current/` path was deprecated by Canonical in 2025 and now only ships manifests.
>   2. **OpenClaw source code** packed via `git archive HEAD` (~10–30 MB)
>   3. The same `wsl.conf`, `openclaw-gateway.service`, and `provision.sh`
>
> All inside a single Inno Setup `.exe`. The build machine no longer needs WSL or VT-x; it only needs Inno Setup 6 + git + PowerShell.
>
> Provisioning (apt install + pnpm install + build) now happens on the **customer machine** during Phase 2 of `post-install.ps1`. Install time stretches from ~3 min (offline) to **15–30 min (online)**, and the customer machine **must have internet** during install.
>
> Sections below have been re-tagged accordingly:
> - **Phase 1** (rootfs build pipeline): files renamed, `scripts/build-rootfs.ps1` deleted, `provision.sh` modified to read source from a tarball.
> - **Phase 3 / Task 3.1** (`scripts/build-installer.ps1`): no longer invokes WSL; just downloads Ubuntu base, runs `git archive`, and calls `iscc`.
> - **Phase 2 / Task 2.2** (`post-install.ps1`): Phase 2 now imports base rootfs, stages source/configs, and runs `provision.sh` inside the customer's distro.
>
> The original code blocks below are kept for historical traceability; ground truth is the actual files in `installer/` and `scripts/`.

> **🔄 REVISION 2026-04-26 — foreground launch model (Q5/Q7 re-evaluation)**
>
> Original plan (Q5=D, Q7=A): the gateway is a hardened systemd unit that auto-starts on distro boot; the desktop shortcut just opens a browser; a hidden keep-alive `wsl --exec /bin/sleep infinity` keeps the distro from idle-shutting-down between clicks.
>
> Customer feedback in 2026-04-26 testing was that this hides the gateway from the user: there is no terminal to read live logs, no `Ctrl-C` to stop the gateway, and the auto-launched browser at install time felt presumptuous. The native dev experience (`node openclaw.mjs gateway run`) — visible terminal, streaming logs, Ctrl-C to quit — is what users actually want from this product.
>
> **The launch model is now:**
>
> 1. **Install ≠ launch.** `post-install.ps1` Phase 2 finishes when provisioning is done. It writes a marker, creates the desktop shortcut, and exits. **It does not start the gateway and does not open the browser.** The user must explicitly click the desktop icon to launch.
> 2. **Click → visible Windows Terminal tab.** `installer/openclaw-launcher.cmd` launches `wt.exe new-tab --title "aiDAPTIVClaw Gateway" -- wsl.exe -d aidaptivclaw -u openclaw -- /opt/openclaw/run-gateway.sh`. The terminal is the gateway: stdout/stderr stream to it; the gateway is PID 1 of the wsl session via `exec`, so Ctrl-C delivers SIGINT directly to node and shuts the gateway down cleanly. Closing the terminal window also stops the gateway.
> 3. **Browser auto-opens after readiness.** The launcher polls `127.0.0.1:18789` from Windows; once the port is bound, it requests the dashboard URL with auth token and opens it in the user's default browser. Detecting "already running" (icon clicked twice) skips the new terminal and just opens a browser tab.
> 4. **No keep-alive helper.** WSL2 idle-shuts-down a distro a few seconds after the last `wsl.exe` session exits — but the gateway terminal IS a live `wsl.exe` session. As long as the user keeps the gateway window open, the distro stays alive. When they close it, the gateway stops, the wsl session exits, and the distro powers down — exactly the behaviour we want. The previously-required `installer/openclaw-keepalive.ps1` is deleted.
> 5. **Systemd unit shipped DISABLED.** `provision.sh` no longer runs `systemctl enable openclaw-gateway.service`. The unit file is still installed at `/etc/systemd/system/` so power users who want always-on daemon behaviour can `sudo systemctl enable --now openclaw-gateway.service` after first launch. Default users get the foreground experience.
>
> **What we lose vs. systemd unit:** The hardening directives in the unit (CapabilityBoundingSet, Protect*, ReadWritePaths, etc.) are no longer enforced because the gateway is no longer started by systemd. The remaining sandboxing is:
>
> - Runs as the non-root `openclaw` user (uid 1000, `/bin/bash` shell, password locked, not in sudo group). Cannot escalate. The shell was changed from `/usr/sbin/nologin` to `/bin/bash` on 2026-04-26 because `wsl.exe -u openclaw` enters via PAM and PAM spawns the login shell, so nologin caused "This account is currently not available." and exit 1 before run-gateway.sh ever ran. Reverting to nologin would only buy back a defense-in-depth that does not apply here: no sshd / getty exists in this distro, and the node gateway can already `child_process.spawn('/bin/bash')` regardless of the user's login shell.
> - WSL distro itself has `automount.enabled=false` + `interop.enabled=false` (`wsl.conf`), so the gateway sees neither `/mnt/c/*` nor `cmd.exe`.
> - Bound to `127.0.0.1:18789` only; never the distro's external interface.
> - **`/opt/openclaw` and `/opt/node` are `chown -R root:root` + `chmod -R a-w,a+rX` at the end of `provision.sh` step 6.** The openclaw user retains read+execute but not write, so a hostile gateway cannot backdoor `openclaw.mjs`, `run-gateway.sh`, or any bundled `node_modules` to persist across launches. This is the cheap-and-effective replacement for the `ProtectSystem=strict` directive that systemd was providing. Workspace and runtime state directories (`/home/openclaw/workspace`, `/home/openclaw/.openclaw`) remain fully writable as the gateway needs.
>
> This is enough sandboxing for our threat model (an LLM-driven gateway accidentally running malicious tool code, scoped to a non-root user inside a disposable WSL distro). Power users who want the systemd hardening on top can opt-in via the disabled unit.
>
> Affected files: `installer/rootfs/provision.sh` (no `enable`, ships `run-gateway.sh`), `installer/openclaw-launcher.cmd` (full rewrite), `installer/post-install.ps1` (Phase 2 ends after marker write), `installer/openclaw.iss` (no longer ships keep-alive helper). The hardening section below (Step 2: openclaw-gateway.service) and Section 9 (Hardening troubleshooting) still describe the unit's contents accurately — the unit file is unchanged, only its enabled state is.

> **🔄 REVISION 2026-04-27 — install-time `windowsbridge` checkbox (Q3 made user-selectable)**
>
> The original Q3=D decision (`/etc/wsl.conf` `[automount] enabled=false` + `[interop] enabled=false`) cleanly prevented the gateway from reading any Windows file or executing any Windows .exe. In 2026-04-27 dogfooding it became clear that this also blocks an entire class of high-frequency real-user requests:
>
> - "set me a 7am alarm" → no `schtasks.exe` reachable
> - "copy this snippet to my clipboard" → no Windows clipboard bridge
> - "open `D:\projects\foo` in Explorer" → no `explorer.exe`
> - "save this markdown to my Desktop" → no `/mnt/c`
> - Any Office automation via COM, any "create a Windows shortcut", any "play this in Windows Media Player", etc.
>
> **Resolution: opt-in checkbox at install time.** A new Inno Setup task `windowsbridge` (default UNCHECKED) is added to `installer/wsl/openclaw.iss`. The task description explicitly enumerates both what is gained ("alarms, clipboard, opening folders, Office automation") and what is lost ("strict sandbox"). Selection state propagates through `install-options.ini` `[mode] permissive=0|1` to `post-install.ps1` Phase 2, which sed-flips the staged `wsl.conf` between `enabled=false` and `enabled=true` BEFORE provision.sh installs it at `/etc/wsl.conf`. The on-disk `installer/wsl/rootfs/wsl.conf` is never modified — staging happens on a copy in `/tmp/rootfs-config/` inside the distro.
>
> **What the user actually sees:**
>
> - **Installer page:** "Windows integration" group with one checkbox: "Allow OpenClaw to access Windows files and run Windows commands (needed for: alarms, clipboard, opening folders, Office automation). Leave unchecked for strict sandbox." Default: unchecked.
> - **`post-install.ps1` Phase 2 banner:** echoes either `Sandbox mode: STRICT SANDBOX (Windows bridge disabled)` or `Sandbox mode: PERMISSIVE (Windows bridge enabled)` to the visible PowerShell window so users know what they're getting.
> - **Every gateway launch:** `run-gateway.sh` reads `/etc/wsl.conf` line 1 (which `post-install.ps1` prepended with `# MODE: STRICT SANDBOX (...)` or `# MODE: PERMISSIVE (...)`) and prints it as a banner before `exec node`. So even months later the user can glance at the gateway terminal and see which mode they're in.
> - **Self-report from outside:** `wsl -d aidaptivclaw -- head -1 /etc/wsl.conf` returns the same `# MODE: ...` line. Useful for support diagnostics.
>
> **Threat-model impact when the user opts INTO permissive mode:**
>
> - **A.1 (LLM reads arbitrary Windows files):** No longer mitigated. The gateway can read `~/Documents`, `~/Downloads`, browser cookie databases on disk, `~/.ssh/`, anything the user can read.
> - **A.2 (LLM executes arbitrary Windows .exe):** No longer mitigated. The gateway can spawn `cmd.exe`, `powershell.exe`, `explorer.exe`, `schtasks.exe`, `wmic.exe`, etc., with the user's token.
> - **What still holds in permissive mode:**
>   - Non-root `openclaw` user (uid 1000, locked password, no sudo) — gateway cannot become root inside the distro.
>   - `/opt/openclaw` and `/opt/node` are root-owned read-only — gateway cannot backdoor its own binaries to persist.
>   - Gateway bound to `127.0.0.1:18789` only — no LAN exposure, regardless of interop.
>   - WSL distro itself is per-Windows-user, so cross-Windows-user host attacks still need a separate vector.
>
> **Why a checkbox and not a runtime toggle?** Switching `wsl.conf` flags requires a `wsl --terminate` to take effect, which would kill any running gateway session. Doing it at install time keeps the runtime experience clean ("you click the icon, the gateway runs"). Users who change their mind can re-run the installer; the task is **not** marked `checkedonce`, so the box is re-asked on every reinstall and never silently stale.
>
> **Migration target (still planned, not in this revision):** Ship a Windows-side broker (`installer/native/broker.exe` or similar) that exposes a narrow whitelist API on a loopback port — `POST /broker/alarm`, `GET/PUT /broker/clipboard`, `POST /broker/explorer`, `POST /broker/save-to-desktop` — then make the broker the recommended way to satisfy these use cases and recommend that strict-sandbox users leave `windowsbridge` unchecked. Until that broker exists, **users who need any of the listed features must check the box and accept that they have effectively opted out of A.1 / A.2 mitigation.**
>
> **Affected files:**
>
> - `installer/wsl/openclaw.iss` — new `[Tasks] windowsbridge`, new `GetWindowsBridgeFlag` helper, `WriteInstallOptions` writes `[mode] permissive=0|1`.
> - `installer/wsl/post-install.ps1` — `Read-InstallOptions` parses `permissive`; `Invoke-Phase2` echoes the active mode in its banner and sed-flips the staged `wsl.conf` between strict and permissive (and prepends a `# MODE: ...` marker line either way).
> - `installer/wsl/rootfs/wsl.conf` — header rewritten to document the two modes; defaults remain strict.
> - `installer/wsl/rootfs/provision.sh` — comment in step 4 (user creation) updated so it doesn't claim wsl.conf is unconditionally strict; comment in step 6 (wsl-pro masking) updated so it doesn't depend on automount being off; `run-gateway.sh` now echoes the `# MODE: ...` banner from `/etc/wsl.conf` at every launch.

**Goal:** Convert aiDAPTIVClaw from a native Windows installation (full user privileges) into a WSL2-confined installation (non-root user inside an isolated Ubuntu 24.04 distro with systemd hardening), so OpenClaw can no longer read arbitrary Windows files or escalate privileges if compromised.

**Architecture (Q2=C, online build):** Installer ships a vanilla Ubuntu 24.04 WSL base rootfs + an `openclaw-source.tar.gz` produced by `git archive HEAD` + `provision.sh` + `wsl.conf` + `openclaw-gateway.service`. On install, `wsl --import` registers the base rootfs as the private distro `aidaptivclaw`, then `provision.sh` runs **inside the customer's distro** to install Node.js + pnpm + build OpenClaw under `/opt/openclaw` and enable the systemd unit. Subsequent boots: the systemd unit (`openclaw-gateway.service`) starts the gateway as the non-root `openclaw` user with hardening directives confining writes to `/home/openclaw/{workspace,.openclaw}` and `/tmp`. The Windows launcher only triggers `wsl.exe -d aidaptivclaw` and opens the browser at `http://localhost:18789` (reachable via WSL2 default localhost forwarding).

**Target-machine install flow (dual-phase, handles missing WSL):** `post-install.ps1` runs in two phases. Phase 1 verifies prerequisites — Windows version, CPU virtualization (hard-fail with BIOS instructions if disabled, since no API can fix BIOS), and WSL2. If WSL is missing, Phase 1 runs `wsl --install --no-distribution`, registers a one-shot HKCU RunOnce entry to fire Phase 2 after the required reboot, and exits with code 2 (Inno Setup interprets this as "reboot recommended"). If WSL is already present, Phase 1 short-circuits straight into Phase 2 in the same process — no reboot. Phase 2 imports the **base** rootfs, stages source + configs into the distro, runs `provision.sh` (the long step: ~15–25 min, downloads packages, builds OpenClaw), patches `.wslconfig` with `vmIdleTimeout=-1`, boots the distro to start the gateway, waits for the gateway HTTP endpoint, opens the browser, and removes its own RunOnce entry. Failures at any stage produce friendly dialogs that link to `docs/install/windows.md` for self-service troubleshooting (BIOS enable, manual `wsl --install`, corporate Group Policy workarounds, network failures during apt/pnpm).

**Build pipeline (Q2=C):** No WSL on the build machine. `scripts/build-installer.ps1` (a) caches Canonical's official Ubuntu 24.04 WSL base rootfs to `installer/rootfs/ubuntu-base.tar.gz`, (b) packs git-tracked source via `git archive --format=tar.gz HEAD` to `installer/rootfs/openclaw-source.tar.gz`, then (c) invokes `iscc.exe` to bundle everything into the `.exe`.

**Tech Stack:** Inno Setup (installer), PowerShell + Bash (provisioning), WSL2, Ubuntu 24.04 (Canonical WSL rootfs), systemd, Node.js 22+, pnpm.

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
# Use `pnpm build` (NOT `build:docker`): our installer ships vendor/ and
# apps/ via `git archive`, so canvas:a2ui:bundle can run. `build:docker`
# is for Docker images that exclude those dirs via .dockerignore.
pnpm build
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
>
> **`vmIdleTimeout=-1` only protects the shared utility VM, not individual distros.** Empirically (see `journalctl -u systemd-logind` showing `Operation canceled @p9io.cpp:258 (AcceptAsync)` immediately followed by `The system will power off now!`), `vmIdleTimeout` only controls the shared WSL2 utility VM (`vmmem`/`vmmemWSL`). **Individual distros are still powered off by `systemd-logind` a few seconds after the last `wsl.exe` user session against them exits**, even when a long-running systemd service is active inside. Under the 2026-04-26 foreground launch model this is not a problem — see the revision block at the top of this document. The visible "aiDAPTIVClaw Gateway" Windows Terminal tab IS the wsl.exe session keeping the distro alive; closing it intentionally allows the distro to power off, exactly the desired behaviour. The previously-shipped `installer/openclaw-keepalive.ps1` (which spawned a hidden `wsl --exec /bin/sleep infinity`) is no longer needed and has been removed.

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
# ProtectHome must be `read-only`, NOT `tmpfs`. tmpfs hides /home/openclaw and the
# subsequent ReadWritePaths bind-mounts fail with status=226/NAMESPACE before node runs.
ProtectSystem=strict
ProtectHome=read-only
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
# RestrictNamespaces= intentionally omitted. RestrictNamespaces=yes makes the
# OpenClaw gateway exit with status=1 during init (probably koffi / sharp /
# Node worker_threads call clone(2) / unshare(2) with namespace flags). See
# "Hardening troubleshooting" below.
LockPersonality=yes

# Architecture / system calls
# SystemCallFilter / SystemCallArchitectures intentionally omitted -- same
# bisection as RestrictNamespaces. Most likely culprit is `~@resources`
# blocking setrlimit(2). Re-introduce only as a permissive ALLOW-list
# captured from a known-good `strace -c` run, not as a tightened denylist.

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

If `pnpm install` or `pnpm build` fails, the issue is in OpenClaw itself, not the pipeline. Inspect with `-KeepBuildDistro` then `wsl -d aidaptivclaw-build -u root` to drop into a shell.

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

### Task 2.2: Replace `post-install.cmd` with dual-phase `post-install.ps1`

**Files:**
- Create: `installer/post-install.ps1`
- Delete: `installer/post-install.cmd` (in Task 2.5 after verifying replacement works)

**Background — flow on the target machine:**

```
Phase 1 (initial install, run by Inno Setup [Code]):
  1. Check Windows >= Win10 22H2 / Win11   -> hard fail with friendly dialog if not
  2. Check VT-x / AMD-V enabled             -> hard fail with BIOS instructions if not
                                               (no API can fix BIOS)
  3. Check WSL2 availability:
     a. WSL already OK -> jump to Phase 1.5 in the same process (no reboot)
     b. WSL missing    -> run `wsl --install --no-distribution`,
                          register HKCU RunOnce to fire Phase 2 after the
                          required reboot, prompt user to reboot, exit.
                          (`wsl --install` failure -> dialog with manual
                           command + abort, no RunOnce registered.)

Phase 1.5 (WSL was already OK; no reboot needed):
  Continues straight into Phase 2 work in the same Inno Setup session.

Phase 2 (after reboot, fired by HKCU RunOnce):
  1. Re-verify VT-x + WSL2 (defensive)
  2. Set WSL default version to 2 if not already
  3. wsl --import aidaptivclaw -> %ProgramData%\aiDAPTIVClaw\wsl\
  4. Update %USERPROFILE%\.wslconfig with vmIdleTimeout=-1
  5. First-boot the distro (systemd auto-starts openclaw-gateway.service)
  6. Wait for http://localhost:18789 to respond (max 30s)
  7. Open browser to dashboard URL
  8. Show "Setup complete" toast / dialog
  9. Cleanup HKCU RunOnce entry
```

**Step 1: Write `installer/post-install.ps1`**

```powershell
<#
.SYNOPSIS
    aiDAPTIVClaw target-machine post-install / WSL provisioning.

.DESCRIPTION
    Dual-phase script. Phase selection by -Phase parameter:

      Phase 1 (called from Inno Setup):
        * Verify Windows version, virtualization, WSL.
        * If WSL missing: install it, register HKCU RunOnce for Phase 2,
          ask user to reboot.
        * If WSL OK: fall through to Phase 2 logic in the same process.

      Phase 2 (called after reboot via RunOnce, OR rerun by user):
        * wsl --import the bundled rootfs.
        * Configure .wslconfig.
        * Boot distro and verify gateway responds.
        * Open browser to dashboard URL.
        * Cleanup the RunOnce entry.

    Exit codes (consumed by Inno Setup [Code]):
        0  success (Phase 1 went through to Phase 2 inline, all good)
        2  reboot required (Phase 1 installed WSL, RunOnce registered)
        3  prerequisites unmet (VT-x off / Windows too old / etc.)
        1  any other failure (see install.log)

.PARAMETER AppDir
    Directory where the installer placed files (Inno Setup {app}).
.PARAMETER Phase
    1 (default, called from installer) or 2 (called from RunOnce after reboot).
.PARAMETER FromInstaller
    Set when invoked from Inno Setup [Code]; suppresses interactive prompts.
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
$DocsUrl     = "https://github.com/<your-org>/aiDAPTIVClaw/blob/main/docs/install/windows.md"

function Write-Log {
    param([string]$Message)
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts] [Phase$Phase] $Message"
    Write-Host $line
    Add-Content -Path $LogFile -Value $line
}

function Show-FatalDialog {
    param([string]$Title, [string]$Body)
    Add-Type -AssemblyName PresentationFramework -ErrorAction SilentlyContinue
    [System.Windows.MessageBox]::Show($Body, $Title, 'OK', 'Error') | Out-Null
}

function Test-VirtualizationEnabled {
    # Returns $true if CPU virtualization is enabled at firmware level.
    # WSL2 cannot run without this.
    try {
        $cpu = Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1
        return [bool]$cpu.VirtualizationFirmwareEnabled
    } catch {
        return $false
    }
}

function Test-WindowsVersionOk {
    # WSL2 supported on Win10 1903+ but we require 22H2+ for production stability.
    $ver = [Environment]::OSVersion.Version
    if ($ver.Major -lt 10) { return $false }
    if ($ver.Build -lt 19045) { return $false }  # 19045 = Win10 22H2 RTM
    return $true
}

function Test-Wsl2Ready {
    & wsl.exe --status 2>&1 | Out-Null
    return ($LASTEXITCODE -eq 0)
}

function Register-Phase2RunOnce {
    # HKCU RunOnce: fires once on the next interactive logon for THIS user, then auto-deletes.
    $cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$AppDir\post-install.ps1`" -AppDir `"$AppDir`" -Phase 2"
    if (-not (Test-Path $RunOnceKey)) { New-Item -Path $RunOnceKey -Force | Out-Null }
    Set-ItemProperty -Path $RunOnceKey -Name $RunOnceName -Value $cmd
    Write-Log "Registered HKCU RunOnce: $RunOnceName"
}

function Unregister-Phase2RunOnce {
    if (Test-Path "$RunOnceKey") {
        Remove-ItemProperty -Path $RunOnceKey -Name $RunOnceName -ErrorAction SilentlyContinue
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
            "aiDAPTIVClaw requires Windows 10 22H2 or Windows 11.`n`nPlease update Windows and run the installer again."
        Write-Log "ERROR: Unsupported Windows version: $([Environment]::OSVersion.Version)"
        exit 3
    }

    # 2. CPU virtualization gate (no API can fix this)
    if (-not (Test-VirtualizationEnabled)) {
        Show-FatalDialog "Virtualization not enabled" `
            ("aiDAPTIVClaw requires CPU virtualization (Intel VT-x or AMD-V) to be enabled in BIOS.`n`n" +
             "Please reboot, enter BIOS/UEFI setup, and enable:`n" +
             "  - Intel CPU: 'Intel Virtualization Technology' or 'VT-x'`n" +
             "  - AMD CPU:  'SVM Mode' or 'AMD-V'`n`n" +
             "Then run the installer again.`n`n" +
             "See: $DocsUrl#bios")
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
             "Please run the following in an Administrator PowerShell, then reboot:`n`n" +
             "  wsl --install --no-distribution`n`n" +
             "Then run the installer again.`n`n" +
             "Common causes:`n" +
             "  - No internet connection`n" +
             "  - Group Policy blocks Windows Optional Features`n" +
             "  - Antivirus blocks the installer`n`n" +
             "See: $DocsUrl#wsl-install-failed")
        Write-Log "ERROR: 'wsl --install' failed (exit $LASTEXITCODE)"
        exit 1
    }

    # WSL kernel installed. We MUST reboot before `wsl --import` will work.
    Register-Phase2RunOnce

    Add-Type -AssemblyName PresentationFramework -ErrorAction SilentlyContinue
    [System.Windows.MessageBox]::Show(
        ("WSL2 has been installed.`n`n" +
         "Windows must reboot to activate it. Setup will resume automatically " +
         "after you log back in.`n`n" +
         "Click OK, then save your work and reboot."),
        "Reboot required", 'OK', 'Information') | Out-Null

    Write-Log "WSL installed; reboot required. RunOnce registered."
    exit 2  # signals Inno Setup to suggest a reboot
}

# ============================================================
#  Phase 2: import distro, boot it, open browser
# ============================================================
function Invoke-Phase2 {
    Write-Log "Starting Phase 2 (WSL import + first boot)"

    # Defensive re-check (handle: user disabled VT-x between phases)
    if (-not (Test-VirtualizationEnabled)) {
        Show-FatalDialog "Virtualization disabled" `
            "CPU virtualization is no longer enabled. Please re-enable it in BIOS and re-run the installer."
        Unregister-Phase2RunOnce
        exit 3
    }
    if (-not (Test-Wsl2Ready)) {
        Show-FatalDialog "WSL not ready" `
            "WSL2 is still not available. Please open an Administrator PowerShell and run 'wsl --install --no-distribution', then reboot."
        Unregister-Phase2RunOnce
        exit 3
    }

    # Set WSL default version
    & wsl.exe --set-default-version 2 2>&1 | Out-Null

    # Tarball check
    if (-not (Test-Path $Tarball)) {
        Show-FatalDialog "Missing rootfs" "Rootfs file not found: $Tarball"
        Unregister-Phase2RunOnce
        exit 1
    }
    Write-Log "Tarball OK ($([math]::Round((Get-Item $Tarball).Length / 1MB,1)) MB)"

    # Idempotent import (drop previous distro first)
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

    # Patch %USERPROFILE%\.wslconfig (idempotent)
    $wslConfigPath = Join-Path $env:USERPROFILE ".wslconfig"
    $wslConfigContent = if (Test-Path $wslConfigPath) { Get-Content $wslConfigPath -Raw } else { "" }
    if ($wslConfigContent -notmatch "(?ms)^\[wsl2\][^\[]*vmIdleTimeout") {
        if ($wslConfigContent.Length -gt 0 -and -not $wslConfigContent.EndsWith("`n")) {
            $wslConfigContent += "`r`n"
        }
        $wslConfigContent += "`r`n# Added by aiDAPTIVClaw installer: keep sandbox VM alive.`r`n[wsl2]`r`nvmIdleTimeout=-1`r`n"
        Set-Content -Path $wslConfigPath -Value $wslConfigContent -Encoding UTF8
        Write-Log ".wslconfig updated"
        & wsl.exe --shutdown 2>&1 | Out-Null   # apply the new config
    }

    # First boot: systemd auto-starts openclaw-gateway.service
    & wsl.exe -d $DistroName -u root -e /bin/true 2>&1 | Out-Null
    Start-Sleep -Seconds 3

    # Wait for gateway
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
            ("The OpenClaw gateway did not respond within 30 seconds.`n`n" +
             "Diagnose with:`n" +
             "  wsl -d $DistroName -u root -e systemctl status openclaw-gateway.service`n`n" +
             "See $LogFile for details.")
        Unregister-Phase2RunOnce
        exit 1
    }

    # Open browser
    $dashUrl = & wsl.exe -d $DistroName -u openclaw -e /opt/openclaw/bin/openclaw dashboard --print-url 2>$null
    if ([string]::IsNullOrWhiteSpace($dashUrl)) { $dashUrl = "http://localhost:18789/" }
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
    New-Item -ItemType File -Path $LogFile -Force | Out-Null

    if ($Phase -eq '1') {
        Invoke-Phase1
    } else {
        Invoke-Phase2
    }
} catch {
    Write-Log "FATAL: $_"
    Show-FatalDialog "aiDAPTIVClaw setup error" "$_`n`nSee $LogFile"
    exit 1
}
```

> **Note on `Show-FatalDialog`:** uses `System.Windows.MessageBox` from `PresentationFramework`. This is loaded on demand and requires .NET Framework 4.5+ (built into Win10 22H2). If for any reason WPF is not loadable, the script falls back to console output (still logged).

**Step 2: Lint check**

```powershell
Invoke-ScriptAnalyzer installer\post-install.ps1
```

Expected: no errors. `Write-Host` warnings are acceptable.

If `Invoke-ScriptAnalyzer` is not installed: `Install-Module PSScriptAnalyzer -Scope CurrentUser`.

**Step 3: Manual smoke test (host machine, with WSL already installed)**

```powershell
mkdir -Force $env:TEMP\openclaw-smoke
Copy-Item installer\post-install.ps1 $env:TEMP\openclaw-smoke\
# Phase 1 should detect WSL is OK and short-circuit straight into Phase 2.
# Without a real rootfs it will fail at "Missing rootfs" — that's expected.
powershell -File $env:TEMP\openclaw-smoke\post-install.ps1 -AppDir $env:TEMP\openclaw-smoke -Phase 1
```

Expected: dialog "Missing rootfs" pops up. This proves Phase 1 → Phase 2 fall-through works.

**Step 4: Commit**

```powershell
git add installer/post-install.ps1
git commit -m "installer: add dual-phase post-install.ps1 with WSL auto-install"
```

---

### Task 2.3: Update `openclaw.iss` `[Code]` section to call the PowerShell script

**Files:**
- Modify: `installer/openclaw.iss`

**Step 1: Replace `RunPostInstallBuild` procedure**

In `installer/openclaw.iss`, find the `RunPostInstallBuild` procedure (around line 282-337). Replace it with the dual-phase aware version:

```pascal
{ --- Post-install: provision WSL sandbox (Phase 1) ---
  Phase 1 may either:
    (a) Complete inline (WSL already present -> exit 0)
    (b) Install WSL and request a reboot (exit 2; HKCU RunOnce already
        registered by post-install.ps1 to fire Phase 2 after reboot)
    (c) Fail prerequisites (exit 3) or other error (exit 1) }

procedure RunPostInstallBuild;
var
  ResultCode: Integer;
  AppDir, LogFile, Params: String;
  ExecResult: Boolean;
begin
  NeedsReboot := False;
  BuildSucceeded := False;
  AppDir := ExpandConstant('{app}');
  LogFile := AppDir + '\install.log';

  Params := '-NoProfile -ExecutionPolicy Bypass -File "' + AppDir + '\post-install.ps1"' +
            ' -AppDir "' + AppDir + '"' +
            ' -Phase 1' +
            ' -FromInstaller';

  SaveStringToFile(LogFile, '=== Installer [Code] diagnostic ===' + #13#10, False);
  SaveStringToFile(LogFile, 'invocation: powershell.exe ' + Params + #13#10, True);

  WizardForm.StatusLabel.Caption := 'Provisioning WSL sandbox (this may take a few minutes)...';
  WizardForm.Refresh;

  ExecResult := Exec('powershell.exe', Params, AppDir,
                     SW_SHOWNORMAL, ewWaitUntilTerminated, ResultCode);

  SaveStringToFile(LogFile,
                   'exec_result: ' + IntToStr(Ord(ExecResult)) +
                   ', exit_code: ' + IntToStr(ResultCode) + #13#10, True);

  if ExecResult and (ResultCode = 0) then
  begin
    { Phase 1 short-circuited into Phase 2 inline. All done. }
    BuildSucceeded := True;
  end
  else if ExecResult and (ResultCode = 2) then
  begin
    { WSL was just installed and a reboot is required.
      RunOnce already registered by post-install.ps1.
      Tell Inno Setup to suggest a reboot at the end of the wizard. }
    NeedsReboot := True;
    BuildSucceeded := True;  { not really a failure — just needs reboot }
  end
  else if ExecResult and (ResultCode = 3) then
  begin
    { Hard prerequisite failure (no VT-x / unsupported Windows).
      post-install.ps1 already showed a dialog. Mark as failed so Inno
      Setup ends with an error wizard page. }
    BuildSucceeded := False;
  end
  else
  begin
    MsgBox('WSL sandbox provisioning failed (exit code: ' + IntToStr(ResultCode) + ').' + #13#10 + #13#10 +
           'Check the log file:' + #13#10 + LogFile + #13#10 + #13#10 +
           'You can retry from PowerShell:' + #13#10 +
           '  powershell -File "' + AppDir + '\post-install.ps1" -AppDir "' + AppDir + '" -Phase 1',
           mbError, MB_OK);
    BuildSucceeded := False;
  end;
end;

{ Tell Inno Setup whether to add a "reboot now" prompt at the end. }
function NeedRestart(): Boolean;
begin
  Result := NeedsReboot;
end;
```

Add `NeedsReboot: Boolean;` to the existing `var` declaration block at the top of the `[Code]` section.

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

### Task 2.7: Cloud Provider configuration (wizard CloudPage → openclaw.json)

**Goal:** Restore the cloud-provider configuration UX that the WSL rewrite accidentally dropped, without falling back into the old "key written to host before install completes" risk model.

**Files:**
- Modify: `installer/openclaw.iss` — add `CloudPage` (wizard custom page after `wpSelectTasks`), 4 provider-metadata helpers (`GetProviderId` / `GetProviderBaseUrl` / `GetProviderApi` / `GetProviderDefaultModel`), extend `WriteInstallOptions` to persist `[provider]` section, delete `WriteConfigFile` + `ReplaceSubstring` (functionality moves to PowerShell).
- Modify: `installer/post-install.ps1` — extend `Read-InstallOptions` to load `[provider]` section, add 5 new functions (`Set-JsonProperty`, `Build-OpenClawConfig`, `Convert-ConfigToJson`, `Write-WindowsHostConfig`, `Push-WslGuestConfig`, `Apply-CloudProviderConfig`, `Remove-InstallOptionsSecrets`), wire `Apply-CloudProviderConfig` + `Remove-InstallOptionsSecrets` into `Invoke-Phase2` AFTER provision.sh succeeds and BEFORE `wsl --terminate`.
- Unchanged: `installer/openclaw-template.json` (used as the canonical pre-patch base by `Build-OpenClawConfig`).

**Provider metadata table** (5 providers, default model ids reflect 2026-04 frontier-tier "fast / cheap" choices, verified against each provider's official docs):

| idx | label                  | id           | baseUrl                                           | api                    | default model |
|-----|------------------------|--------------|---------------------------------------------------|------------------------|---------------|
| 0   | OpenRouter             | `openrouter` | `https://openrouter.ai/api/v1`                    | `openai-completions`   | `google/gemini-3.1-flash-lite-preview` |
| 1   | Google Gemini          | `google`     | `https://generativelanguage.googleapis.com/v1beta` | `google-generative-ai` | `gemini-3-flash-preview` |
| 2   | Anthropic (Claude)     | `anthropic`  | `https://api.anthropic.com`                       | `anthropic-messages`   | `claude-sonnet-4-6` |
| 3   | OpenAI                 | `openai`     | `https://api.openai.com/v1`                       | `openai-completions`   | `gpt-5.4-mini` |
| 4   | Together AI            | `together`   | `https://api.together.xyz/v1`                     | `openai-completions`   | `meta-llama/Llama-4-Maverick-17B-128E-Instruct-FP8` |

**Cross-phase data flow:**

```
Phase 1 (Inno wizard)                              Phase 2 (post-install.ps1)
───────────────────────                            ──────────────────────────
CloudPage:                                         Read install-options.ini
  ProviderCombo + ApiKeyEdit                          ↓
  + ModelEdit                                      Apply-CloudProviderConfig:
       │                                             ├─ Build-OpenClawConfig
       ▼                                             │    (load template,
WriteInstallOptions                                  │     patch 3 sites)
  → install-options.ini                              ├─ Write-WindowsHostConfig
       │  [install] / [shortcuts]                    │    (%USERPROFILE%\.openclaw\)
       │  [provider] id, baseUrl, api,               └─ Push-WslGuestConfig
       │             model, apiKey                        (wsl install -m 0640
       ▼                                                  -o openclaw -g openclaw)
post-install.ps1 -Phase 1                              ↓
                                                   Remove-InstallOptionsSecrets
                                                     (strip [provider] section
                                                      from .ini, apiKey wiped)
                                                       ↓
                                                   wsl --terminate → systemd cold-boot
                                                       ↓
                                                   gateway service starts and reads
                                                   /home/openclaw/.openclaw/openclaw.json
```

**Three patch sites** in `Build-OpenClawConfig` (mirror legacy `configure-cloud.cjs` plus one extra fix):

```jsonc
// Patch 1: insert/update provider entry, preserve any existing fields
"models.providers.<id>" = { baseUrl, apiKey, api, models: existing.models ?? [] }

// Patch 2: point hybrid-gateway's cloud tier at the chosen provider
"plugins.entries.hybrid-gateway.config.models.cloud" = { provider: <id>, model }

// Patch 3 (NEW): retarget agents.defaults.model.primary
//   The legacy configure-cloud.cjs forgot this — without it, choosing
//   e.g. Anthropic on the wizard would silently leave the agent's
//   primary model pointing at openrouter/google/gemini-3.1-flash-lite-preview,
//   defeating the whole point of letting the user pick a provider.
"agents.defaults.model.primary" = "<id>/<model>"
```

**Security notes:**

- `ApiKeyEdit.PasswordChar = '*'` masks the key on screen (legacy installer didn't).
- API key travels through `install-options.ini` `[provider]` section in plain text — same risk model as the legacy installer (which wrote it directly to `%USERPROFILE%\.openclaw\openclaw.json`). Exposure window: from Phase 1 wizard finish until Phase 2 consumes it (~build + reboot + provision = 30–60 min). Mitigation: `Remove-InstallOptionsSecrets` strips the `[provider]` section the instant Phase 2 finishes patching.
- WSL guest copy is written with `install -m 0640 -o openclaw -g openclaw` so only the openclaw user (and root) can read it — gateway can read, no other process inside the distro can.
- Host-side temp file in `%TEMP%` (used by `Push-WslGuestConfig` to bridge to WSL via `wslpath`) is deleted in a `finally` block, even on error.

**Empty-key path:** If the user leaves API Key blank, Phase 2 detects empty `ProviderApiKey` and writes the unpatched template to both locations. Gateway boots without errors but any LLM call fails until the user fills in a key from the OpenClaw web UI.

**Verification:**

```powershell
# After install completes, confirm both copies exist and contain the chosen provider:
Get-Content "$env:USERPROFILE\.openclaw\openclaw.json" | ConvertFrom-Json |
  Select-Object -ExpandProperty agents | Select-Object -ExpandProperty defaults |
  Select-Object -ExpandProperty model | Select-Object -ExpandProperty primary
# Expected: matches "<id>/<model>" from the wizard.

wsl -d aidaptivclaw -u openclaw -- cat /home/openclaw/.openclaw/openclaw.json |
  Select-String '"primary"'
# Expected: same value.

# install-options.ini should no longer contain [provider]:
Get-Content "$env:ProgramFiles\aiDAPTIVClaw\install-options.ini" |
  Select-String '\[provider\]|apiKey='
# Expected: no matches.
```

**Step: Commit**

```bash
git add installer/openclaw.iss installer/post-install.ps1
git commit -m "installer: restore cloud provider wizard page (CloudPage) and seed openclaw.json in Phase 2"
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
- Create: `docs/install/windows.md`

**Required anchors (the post-install.ps1 dialogs link to these):**
- `#bios` — how to enable virtualization in BIOS
- `#wsl-install-failed` — what to do if the auto WSL install failed

**Step 1: Document the new install experience**

Sections to cover:

1. **Prerequisites**
   - Windows 10 22H2 or Windows 11 (22H2+ recommended)
   - CPU virtualization (Intel VT-x / AMD-V) enabled in BIOS — see `#bios`
   - Internet connection during install (for WSL2 kernel download if not already present)
   - ~2GB free disk space on system drive

2. **What the installer does**
   - Phase 1: prerequisite checks; if WSL2 missing, runs `wsl --install --no-distribution` and asks for a reboot
   - After reboot: Phase 2 fires automatically via Windows RunOnce on first logon
   - Phase 2: imports the bundled rootfs as a private WSL distro `aidaptivclaw`, configures `.wslconfig`, boots the distro, opens browser to dashboard
   - Total user time: ~3 minutes (no reboot path) or ~5 minutes (with reboot)

3. **Where the workspace lives**
   - Inside WSL: `/home/openclaw/workspace`
   - From Windows Explorer: `\\wsl.localhost\aidaptivclaw\home\openclaw\workspace`
   - Include screenshot of how to pin this UNC path in Explorer Quick Access

4. **Authorizing Windows folders for read-only access**
   - Currently NOT supported in MVP (D-2 follow-up). Document the manual workaround: copy files into the workspace UNC path.

5. **How to uninstall**
   - Control Panel → uninstall. The uninstaller automatically `wsl --unregister aidaptivclaw`, which destroys the sandbox VM and all data inside it.

6. **<a id="bios"></a>Enabling virtualization in BIOS**
   Step-by-step with example screenshots:
   - Reboot, press the key shown briefly on boot (commonly F2, Del, F10, F12, Esc)
   - Look under: `Advanced` → `CPU Configuration` (Intel) or `Advanced` → `CPU Features` (AMD)
   - Enable: `Intel Virtualization Technology` / `Intel VT-x` / `Intel VMX` OR `SVM Mode` / `AMD-V`
   - Some OEMs (Lenovo, HP) hide the option under `Security` instead of `Advanced`
   - Save (commonly F10) → reboot → re-run the installer
   - Verify in PowerShell: `(Get-CimInstance Win32_Processor).VirtualizationFirmwareEnabled` should return `True`

7. **<a id="wsl-install-failed"></a>WSL auto-install failed**
   Three common causes and remediation:

   - **No internet at install time.** Manually run as Administrator:
     ```powershell
     wsl --install --no-distribution
     ```
     then reboot, then re-run the aiDAPTIVClaw installer.

   - **Group Policy / corporate IT blocks Windows Optional Features.** Ask IT to enable:
     ```
     Computer Configuration > Administrative Templates > Windows Components >
       Hyper-V > "Allow Hyper-V to be enabled"
     ```
     and the **Windows Subsystem for Linux** Windows Feature.
     If IT cannot help, the product will not work on this machine.

   - **Antivirus blocks the installer.** Whitelist `aidaptiv-claw-setup.exe` and `wsl.exe`.

8. **General troubleshooting**
   - "Gateway did not respond on port 18789" → run:
     ```powershell
     wsl -d aidaptivclaw -u root -e systemctl status openclaw-gateway.service
     wsl -d aidaptivclaw -u root -e journalctl -u openclaw-gateway.service -n 100
     ```
   - "Gateway window closed by itself after a minute (under 2026-04-26 foreground launch model)" → unexpected; the gateway window IS the distro's keep-alive. If it closed without user input, the gateway probably crashed — check the terminal scrollback for stack traces. If the terminal is gone too, re-click the desktop icon: the launcher will boot the distro, spawn a fresh terminal tab, and you'll see the next failure live.
   - "openclaw-gateway journal shows `Operation canceled @p9io.cpp:258` followed by `power off`" (only relevant if a power user opted into the systemd unit via `systemctl enable --now`) → the entire distro got idle-shut-down by WSL2 because no `wsl.exe` session was attached. Workaround for daemon mode: keep at least one wsl.exe session open (e.g. `wsl -d aidaptivclaw bash`) or switch back to the default foreground launch model.
   - "wsl-pro.service spamming the journal with cmd.exe errors" → harmless leftover from Ubuntu 24.04's preinstalled Ubuntu Pro bridge. `provision.sh` runs `systemctl mask wsl-pro.service` to silence it; if you imported the distro by hand and skipped provision.sh, mask it manually.
   - To start fresh: `wsl --unregister aidaptivclaw` then re-run the installer.

9. **Hardening troubleshooting (`openclaw-gateway.service` won't start)**

   Symptom: `openclaw-gateway.service` enters a tight crash loop. `systemctl status` shows `Main process exited, code=exited, status=1/FAILURE` with the journal containing `[hybrid-gw] initializing` followed by `[gateway] force: no listeners on port 18789` but **no** subsequent `[gateway] listening` line. CPU time per attempt is ~18–20 s. There is no signal name (no `SIGSYS` / `SIGSEGV` / `SIGTERM`) — Node calls `process.exit(1)` cleanly.

   Root cause: a hardening directive in the original Q5=D profile is incompatible with the OpenClaw runtime. We bisected this on a target machine by writing a drop-in at `/etc/systemd/system/openclaw-gateway.service.d/diag.conf` containing exactly:

   ```ini
   [Service]
   RestrictNamespaces=no
   SystemCallFilter=
   SystemCallArchitectures=
   ```

   followed by `systemctl daemon-reload && systemctl restart openclaw-gateway.service`. With those three directives reset (and **all** other hardening — `ProtectSystem=strict`, `ProtectHome=read-only`, `ReadWritePaths=`, `PrivateTmp=yes`, `PrivateDevices=yes`, `ProtectKernel*=yes`, `ProtectProc=invisible`, `ProcSubset=pid`, `NoNewPrivileges=yes`, `CapabilityBoundingSet=`, `RestrictSUIDSGID=yes`, `LockPersonality=yes`, `RestrictRealtime=yes` — still in effect) the gateway comes up cleanly and `Invoke-WebRequest http://127.0.0.1:18789/` returns HTTP 200.

   Conclusion: the shipping `openclaw-gateway.service` omits `RestrictNamespaces=`, `SystemCallFilter=` and `SystemCallArchitectures=`. Re-tightening any of them is a future task and must be done by capturing OpenClaw's actual runtime syscalls (e.g. `strace -c`) and emitting a permissive ALLOW-list — not by tightening the denylist further.

   Likely root causes (each compatible with `process.exit(1)` and ~20 s CPU before exit):
   - `RestrictNamespaces=yes` blocks `clone(2)` / `unshare(2)` with namespace flags. Several Node native modules (koffi, sharp, worker_threads internals on certain libc paths) call these during init.
   - `SystemCallFilter=~@resources` blocks `setrlimit(2)`, which Node calls at startup to raise its file-descriptor limit. Node is tolerant of EPERM here but throws on other paths.
   - `SystemCallFilter=~@debug` blocks `ptrace(2)`, used by some native modules' crash handlers.

**Step 2: Commit**

```powershell
git add docs/install/windows.md
git commit -m "docs: document WSL2 sandbox install + BIOS / WSL troubleshooting"
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
