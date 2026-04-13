# aiDAPTIVClaw Windows Installer Design

## Overview

Create a traditional Windows installer (.exe) using Inno Setup that allows end users to install aiDAPTIVClaw (based on OpenClaw) with a wizard experience. The installer bundles source code and Node.js, then builds the project on the customer's machine (online install, network required).

## Requirements

| Item | Decision |
|------|----------|
| Target users | End users / customers, guided install |
| Platform | Windows only |
| Installer format | Traditional setup wizard (.exe) via Inno Setup |
| Node.js | 24 LTS embedded in installer |
| Model / inference engine | Not included; config points to `localhost:13141` / `localhost:13142` |
| WebUI | Built on target machine via `pnpm ui:build` |
| Channels | Not pre-configured; user sets up later |
| Launch method | Desktop / Start Menu shortcut -> start Gateway + auto-open browser |
| Features | Custom install path + Uninstall (via Add/Remove Programs) |
| Network | Required during installation for `pnpm install` |

## Architecture

### Online Install Mode

The installer bundles **source code** (not pre-built artifacts). On the customer's machine, it runs the full build pipeline:

```
Customer runs aidaptiv-claw-setup-x.x.x.exe
  |
  +-- Inno Setup extracts files to install dir:
  |     - Source code (src/, ui/, extensions/, packages/, etc.)
  |     - Node.js 24 LTS (node.exe)
  |     - Installer helpers (launcher, config template)
  |
  +-- post-install.cmd runs in a visible console:
  |     1. Install pnpm (via corepack or PowerShell)
  |     2. pnpm install (downloads dependencies, needs network)
  |     3. pnpm build (compiles TypeScript)
  |     4. pnpm ui:build (builds WebUI)
  |     5. Install hybrid-gateway plugin
  |     6. Link openclaw CLI globally
  |
  +-- Inno Setup writes config + creates shortcuts
  |
  +-- (Optional) Install daemon for auto-start on login
  |
  Done - user can launch aiDAPTIVClaw
```

### Installer Package Contents

```
aidaptiv-claw-setup-x.x.x.exe
|
+-- Node.js 24 LTS (node.exe, ~30MB)
|
+-- Source code (cleaned, no .git/node_modules/test files)
|     +-- src/
|     +-- ui/
|     +-- extensions/ (includes hybrid-gateway)
|     +-- packages/
|     +-- scripts/
|     +-- patches/
|     +-- vendor/
|     +-- package.json, pnpm-workspace.yaml, pnpm-lock.yaml
|     +-- openclaw.mjs, tsconfig.json, tsdown.config.ts
|     +-- .npmrc, LICENSE
|
+-- Installer helpers
      +-- post-install.cmd (build automation script)
      +-- openclaw-launcher.vbs (hidden-window launcher)
      +-- openclaw-launcher.cmd (gateway startup + browser open)
      +-- openclaw-template.json (config template)
      +-- openclaw-icon_ico_96x96.ico
```

### Directory Layout After Installation

```
%LOCALAPPDATA%\aiDAPTIVClaw\             <-- Program + source files
+-- node.exe                              <-- Node.js 24 LTS
+-- openclaw.mjs                          <-- CLI entry point
+-- package.json, pnpm-workspace.yaml
+-- src/                                  <-- Source code
+-- dist/                                 <-- Built output (generated)
|   +-- entry.js
|   +-- control-ui/                       <-- WebUI (generated)
+-- node_modules/                         <-- Dependencies (downloaded)
+-- extensions/hybrid-gateway/
+-- ui/
+-- openclaw-launcher.vbs                 <-- Shortcut target
+-- openclaw-launcher.cmd
+-- openclaw-icon_ico_96x96.ico

%USERPROFILE%\.openclaw\                  <-- User data (preserved on uninstall)
+-- openclaw.json                         <-- Config
+-- workspace/
+-- sessions/
+-- credentials/
```

## Config Template Processing

Template config (`openclaw-template.json`) is written to `%USERPROFILE%\.openclaw\openclaw.json` during installation. Dynamic field replacement:

| Field | Template Value | Replaced With |
|-------|---------------|---------------|
| `agents.defaults.workspace` | `C:\Users\user\.openclaw\workspace` | Actual `%USERPROFILE%\.openclaw\workspace` |
| `meta.lastTouchedVersion` | `2026.3.12` | Installer version |
| `wizard.lastRunVersion` | `2026.3.12` | Installer version |

If config already exists, the installer skips writing to avoid overwriting customizations.

## Launcher Design

**`openclaw-launcher.vbs`** - Shortcut target, hides console window.

**`openclaw-launcher.cmd`** - Starts Gateway in minimized window, waits for port 18789, then opens browser. Timeout after 30 seconds with error message.

## Daemon (Auto-Start on Login)

Uses OpenClaw's built-in Windows Scheduled Task mechanism (`src/daemon/schtasks.ts`):
- Installer offers optional checkbox: "Start gateway automatically on login"
- If checked: runs `openclaw gateway daemon install`
- Falls back to Windows Startup folder if schtasks permission denied
- Uninstaller runs `openclaw gateway daemon uninstall`

## Installer Wizard Flow

1. Welcome page
2. License agreement (MIT)
3. Choose install path (default: `%LOCALAPPDATA%\aiDAPTIVClaw`)
4. Additional options:
   - Create desktop shortcut (checked)
   - Create Start Menu shortcut (checked)
   - Start gateway automatically on login (checked)
5. Ready to install (summary)
6. Installation progress (file extraction)
7. Post-install build (visible console window showing pnpm install/build progress)
8. Completion (option to launch immediately)

## Build Pipeline (Developer Side)

Single command: `.\scripts\build-installer.ps1`

1. Validate Inno Setup Compiler is installed
2. Download Node.js 24 LTS (cached in `installer/.node-cache/`)
3. Stage source code to `installer/build/` (excludes .git, node_modules, apps/, docs/, test files)
4. Run Inno Setup Compiler -> produces `installer/output/aidaptiv-claw-setup-x.x.x.exe`

## Uninstall Behavior

- **Removed**: `%LOCALAPPDATA%\aiDAPTIVClaw\` (program + source + node_modules)
- **Removed**: Daemon scheduled task / startup entry
- **Preserved**: `%USERPROFILE%\.openclaw\` (user config and data)

## Files in Repository

```
installer/
+-- openclaw.iss               <-- Inno Setup script
+-- post-install.cmd            <-- Build automation (runs on customer machine)
+-- openclaw-launcher.vbs       <-- Hidden-window launcher
+-- openclaw-launcher.cmd       <-- Startup logic
+-- openclaw-template.json      <-- Config template
+-- openclaw-icon_ico_96x96.ico <-- App icon
+-- openclaw-icon.png           <-- Source icon (PNG)
+-- license.txt                 <-- License for wizard
+-- build/                      <-- Staging dir (gitignored)
+-- output/                     <-- Output dir (gitignored)
+-- .node-cache/                <-- Node.js download cache (gitignored)
scripts/
+-- build-installer.ps1         <-- One-click build script
```

## Estimated Sizes

- Installer .exe: ~20-40 MB (compressed source + Node.js)
- Installed size on customer machine: ~500 MB-1 GB (after pnpm install + build)
- Installation time: 5-15 minutes (depends on network speed and hardware)

## Known Limitations

- Network required during installation (pnpm install downloads dependencies)
- Build can fail due to native module compilation issues (sharp, koffi, etc.)
- No auto-update mechanism (manual reinstall for upgrades)
- No silent install support
- Installation time depends on customer's network and hardware
