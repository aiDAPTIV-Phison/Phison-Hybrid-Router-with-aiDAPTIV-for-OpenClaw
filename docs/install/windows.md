# Install aiDAPTIVClaw on Windows (WSL2 sandbox)

aiDAPTIVClaw on Windows runs entirely inside a private WSL2 distro called
`aidaptivclaw`. The installer ships a pre-built Ubuntu 24.04 root
filesystem containing OpenClaw, Node.js, pnpm, and a hardened systemd
unit. Your Windows machine never installs Node.js, never builds source,
and never grants the agent direct read/write access to your Windows file
system outside the sandbox.

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
| Network | Outbound HTTPS to `nodejs.org`, `github.com`, model providers |

## Quick install

1. Download `aidaptiv-claw-setup-<version>.exe`.
2. Right-click the installer and choose **Run as administrator** (the
   installer needs admin to register the WSL distro).
3. Click through the wizard and accept the license.
4. The installer:
   - Verifies your Windows version and CPU virtualization.
   - Installs WSL2 if missing (one-time; **requires reboot**).
   - Imports the bundled `aidaptivclaw` distro.
   - Boots the sandbox; systemd starts the gateway automatically.
   - Opens the Control UI in your default browser.
5. If a reboot is required, log back in afterwards and aiDAPTIVClaw setup
   resumes automatically (Windows RunOnce). The Control UI opens once
   ready.

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
