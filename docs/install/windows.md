# Install aiDAPTIVClaw on Windows (WSL2 sandbox)

aiDAPTIVClaw on Windows runs entirely inside a private WSL2 distro called
`aidaptivclaw`. The installer ships a vanilla Ubuntu 24.04 base rootfs
plus the OpenClaw source code; on first install, the installer imports
the base into a private distro and then provisions it online — `apt`
installs base packages, downloads Node.js + pnpm, and builds OpenClaw
inside the sandbox. Your Windows machine never installs Node.js, never
runs the OpenClaw build outside WSL, and never grants the agent direct
read/write access to your Windows file system outside the sandbox.

> **Why online build?** Smaller installer (~150 MB instead of ~1 GB),
> and the build machine doesn't need WSL2/VT-x to produce the .exe.
> Trade-off: first install on the customer machine takes ~15-30 min and
> requires internet access during that window.

> Design rationale: see [docs/plans/2026-04-23-wsl-sandbox-design.md](../plans/2026-04-23-wsl-sandbox-design.md)
> and [docs/plans/2026-04-23-wsl-sandbox-brainstorm-summary.md](../plans/2026-04-23-wsl-sandbox-brainstorm-summary.md).

## Requirements

| Requirement | Minimum |
| --- | --- |
| Windows | 10 22H2 (build 19045) or Windows 11 |
| CPU | x86_64 with VT-x (Intel) or AMD-V (AMD), enabled in BIOS |
| RAM | 8 GB (16 GB recommended) |
| Disk | 6 GB free for installer + WSL distro |
| Privileges | Local administrator account |
| Network at install time | **Required.** Outbound HTTPS to `archive.ubuntu.com` (apt), `nodejs.org` (Node.js), `github.com` (pnpm), and the npm registry. The first install downloads ~600 MB of packages. |
| Network at runtime | Outbound HTTPS to model providers you configure. |
| First install time | ~15-30 minutes (apt + npm install + OpenClaw build inside WSL). Subsequent launches start in seconds. |

## Quick install

1. Download `aidaptiv-claw-setup-<version>.exe`.
2. Right-click the installer and choose **Run as administrator** (the
   installer needs admin to register the WSL distro).
3. Click through the wizard and accept the license.
4. The installer:
   - Verifies your Windows version and CPU virtualization.
   - Installs WSL2 if missing (one-time; **requires reboot**).
   - Imports the bundled Ubuntu 24.04 base as the `aidaptivclaw` distro.
   - **Provisions OpenClaw online** (15-25 min): apt installs base
     packages, downloads Node.js + pnpm, builds OpenClaw inside WSL,
     and enables the systemd gateway unit. Progress is teed to
     `%LOCALAPPDATA%\Programs\aiDAPTIVClaw\install.log`.
   - Boots the sandbox; systemd starts the gateway automatically.
   - Opens the Control UI in your default browser.
5. If a reboot is required, log back in afterwards and aiDAPTIVClaw setup
   resumes automatically (Windows RunOnce). Provisioning then runs as
   above and the Control UI opens once ready.

> **Plan ~30 minutes for the first install.** The wizard's status line
> reads "Provisioning WSL sandbox (downloads packages + builds OpenClaw,
> ~15-30 min)..." — that's normal, not a hang. Tail the install log to
> watch progress:
> ```powershell
> Get-Content "$env:LOCALAPPDATA\Programs\aiDAPTIVClaw\install.log" -Wait -Tail 50
> ```

That's it.

## What the sandbox does and does not allow

The OpenClaw agent runs as the non-root `openclaw` user inside WSL with
heavy systemd hardening:

- **Workspace (`/home/openclaw/workspace`)**: read + write.
- **Agent state (`/home/openclaw/.openclaw`)**: read + write.
- **Everything else inside the distro**: read-only (`ProtectSystem=strict`).
- **Windows drives (`C:\`, `D:\`, etc.)**: invisible. WSL automount is
  off and Windows interop (running `.exe` files) is disabled.
- **Network**: open. Outbound traffic goes through the normal Windows
  network stack so VPNs / corporate proxies still work.
- **Privilege escalation**: blocked (`NoNewPrivileges`, all capabilities
  dropped, system call filter denies `@privileged`/`@mount`/`@module`).

If you need to give the agent read access to a specific Windows folder,
that capability is intentionally not implemented in the MVP — see the
roadmap at the end of the design doc.

## Troubleshooting

<a id="bios"></a>

### "Virtualization not enabled" dialog at install time

The installer detected that CPU virtualization (Intel VT-x or AMD-V) is
disabled in BIOS. WSL2 requires it.

1. Reboot and enter your BIOS/UEFI setup (typically `F2`, `Del`, `F10`,
   or `Esc` at boot — depends on motherboard).
2. Find one of:
   - **Intel CPUs**: `Intel Virtualization Technology`, `VT-x`, `Vanderpool`.
   - **AMD CPUs**: `SVM Mode`, `AMD-V`, `AMD Virtualization`.
3. Set it to **Enabled**, save, exit.
4. Boot back into Windows and re-run the installer.

To check whether VT-x is on without rebooting, open Task Manager →
Performance → CPU. The bottom of the panel shows "Virtualization:
Enabled" or "Disabled".

<a id="wsl-install-failed"></a>

### "WSL install failed" dialog

Common causes and fixes:

- **No internet**: the installer downloads the WSL kernel from Microsoft
  Update. Connect and retry.
- **Group Policy**: enterprise environments sometimes block Windows
  Optional Features. Open `gpedit.msc` and check
  `Computer Configuration → Administrative Templates → System →
  Hyper-V` and adjacent paths. If a policy blocks WSL, ask your IT team
  to allow it. As a workaround, install WSL manually as Administrator,
  reboot, then re-run the aiDAPTIVClaw installer:

  ```powershell
  wsl --install --no-distribution
  ```

- **Antivirus**: some endpoint protection products block the WSL kernel
  installer (`wsl.exe --install`). Whitelist `%SystemRoot%\System32\wsl.exe`
  and the `Microsoft.WSL` MSIX bundle, then retry.
- **Hyper-V conflict**: third-party hypervisors (older VirtualBox, VMware
  Workstation < 15.5.5) can block WSL2. Update the hypervisor or remove it.

After fixing the underlying issue, re-run `wsl --install --no-distribution`
in Administrator PowerShell, reboot, and re-run aiDAPTIVClaw setup.

<a id="provisioning-failed"></a>

### "Provisioning failed" dialog during install

The installer imported the base Ubuntu rootfs but `provision.sh` failed
inside the distro. The most common causes:

- **Network**: `apt update`, `nodejs.org`, or `github.com` was
  unreachable. Common when on a corporate proxy that needs `http_proxy`
  / `https_proxy` env vars. Set them in WSL before retrying:

  ```powershell
  wsl -d aidaptivclaw -u root -e bash -c "echo 'export http_proxy=http://proxy:port' >> /etc/environment; echo 'export https_proxy=http://proxy:port' >> /etc/environment"
  ```

- **Out of disk space**: provisioning needs ~3 GB headroom on the system
  drive (downloaded packages + build artifacts before cleanup). Check:

  ```powershell
  Get-PSDrive C
  ```

- **DNS issues inside WSL**: try
  `wsl -d aidaptivclaw -u root -e bash -c "ping -c1 archive.ubuntu.com"`.
  If it fails, see Microsoft's [WSL DNS guide](https://learn.microsoft.com/windows/wsl/networking#dns-issues).

After fixing the root cause, retry provisioning without re-extracting the
installer:

```powershell
powershell -File "C:\Program Files\aiDAPTIVClaw\post-install.ps1" `
    -AppDir "C:\Program Files\aiDAPTIVClaw" -Phase 2
```

`-Phase 2` automatically unregisters the half-baked distro and starts
fresh. The full provisioning log is appended to `install.log`.

### "Gateway didn't start" dialog after reboot

WSL provisioned, but `openclaw-gateway.service` did not become healthy
within 30 seconds. Inspect the unit:

```powershell
wsl -d aidaptivclaw -u root -e systemctl status openclaw-gateway.service
wsl -d aidaptivclaw -u root -e journalctl -u openclaw-gateway.service -n 200
```

The most common cause is a port conflict — another process on Windows is
already listening on `127.0.0.1:18789`. Find and stop it:

```powershell
Get-NetTCPConnection -LocalPort 18789
```

After freeing the port, restart the unit:

```powershell
wsl -d aidaptivclaw -u root -e systemctl restart openclaw-gateway.service
```

### Control UI opens but shows "connection refused"

WSL2's default localhost forwarder failed to bridge. Restart WSL:

```powershell
wsl --shutdown
```

Then re-run the desktop shortcut. If the issue is recurring on Windows
11 22H2 or later, opt into mirrored networking by adding the following
to `%USERPROFILE%\.wslconfig`:

```ini
[wsl2]
networkingMode=mirrored
```

Run `wsl --shutdown` once to apply, then relaunch.

## Manually re-running setup

If the post-install step failed and you want to retry without
re-extracting the installer:

```powershell
powershell -File "C:\Program Files\aiDAPTIVClaw\post-install.ps1" `
    -AppDir "C:\Program Files\aiDAPTIVClaw" -Phase 1
```

`-Phase 2` skips prerequisite checks and goes straight to the WSL
import + first-boot step.

## Uninstalling

Use **Settings → Apps → Installed apps → aiDAPTIVClaw → Uninstall**.

The uninstaller runs `wsl --unregister aidaptivclaw`, which permanently
deletes the sandbox VM **including everything in your workspace at
`/home/openclaw/workspace`**. Back up anything you want to keep first:

```powershell
wsl -d aidaptivclaw -u openclaw -e tar -czf - /home/openclaw/workspace `
    > workspace-backup.tar.gz
```

After uninstall, the Windows-side config under `%USERPROFILE%\.openclaw\`
remains by default (the uninstaller asks before deleting it).
