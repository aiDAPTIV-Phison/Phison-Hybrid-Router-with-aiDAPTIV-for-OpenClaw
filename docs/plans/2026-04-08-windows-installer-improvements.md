# Windows Installer Improvements

**Date:** 2026-04-08
**Status:** Approved

## Summary

Three improvements to the Windows installer (Inno Setup) addressing issues
found after initial deployment:

1. Auto-fill gateway auth token in Control UI on first launch
2. Add interactive cloud API key configuration during install
3. Fix missing runtime files (workspace templates + bundled skills)

## Changes

### 1. Launcher: auto-fill gateway token

**Problem:** `openclaw-launcher.cmd` opens `http://localhost:18789` without
the gateway auth token, causing a "gateway token mismatch" error on first
connection.

**Solution:** Replace the hardcoded browser launch with `openclaw dashboard`,
which reads the token from `openclaw.json` and opens the browser with
`#token=...` in the URL fragment. The Control UI automatically extracts and
applies the token from the URL hash.

**File:** `installer/openclaw-launcher.cmd`

### 2. Post-install: interactive cloud API key setup

**Problem:** The hybrid-gateway plugin's cloud tier requires an OpenRouter
API key (or other provider key), but the installer has no mechanism for
users to configure this.

**Solution:** Add a new step in `post-install.cmd` after the build completes
that runs `openclaw configure --section model` in the existing console
window. This presents the full interactive CLI wizard where users can
select a provider and enter their API key. Users can skip this step; configuration is also
available later via the Control UI config page.

**File:** `installer/post-install.cmd`

### 3. Build script: package missing runtime directories

**Problem:** `build-installer.ps1` does not include `docs/reference/templates/`
or `skills/` in the staged files. At runtime:

- Missing `docs/reference/templates/` causes:
  `Error: Missing workspace template: AGENTS.md (...). Ensure docs/reference/templates are packaged.`
- Missing `skills/` means no bundled skills are available to the agent.

**Solution:** Add both directories to the build staging:

- `docs\reference\templates` added to `$ExtraSubDirs` (13 small .md files)
- `skills` added to `$CopyDirs` (bundled skills directory)

**File:** `scripts/build-installer.ps1`

## Files Modified

| File | Change |
|------|--------|
| `installer/openclaw-launcher.cmd` | Replace `start "" "http://..."` with `openclaw dashboard` |
| `installer/post-install.cmd` | Add step 7: `openclaw configure --section model` |
| `scripts/build-installer.ps1` | Add `docs\reference\templates` and `skills` to staging |

## Not Changed

- `installer/openclaw.iss` — no structural changes to the Inno Setup script
- `installer/openclaw-template.json` — token remains empty; daemon install
  auto-generates it; model/provider config stays as-is
- Gateway startup flow — launcher still starts gateway + waits + opens browser
- Daemon install — remains an optional checkbox during install
