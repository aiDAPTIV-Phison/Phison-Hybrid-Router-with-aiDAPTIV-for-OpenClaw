#Requires -Version 5.1
<#
.SYNOPSIS
    Normalize line endings in repo files based on platform.

.DESCRIPTION
    Windows-only artifacts (.cmd, .bat, .ps1, .vbs, .iss, .reg) MUST use
    CRLF -- some Windows cmd.exe versions silently mis-parse LF-only .cmd
    files (every `set` line is treated as an unknown command, `setlocal`
    becomes `'ocal'`, etc., and the launcher reports "marker missing"
    even when the marker is on disk).

    WSL/Linux artifacts (.sh, .service, wsl.conf) MUST keep LF; CRLF
    inside those breaks bash, systemd, and netplan parsers.

    This script enforces both, in-place. Idempotent. Run from anywhere
    in the repo; it operates on the repo root.

.PARAMETER Check
    If set, only report files that would change without writing them.
    Useful as a CI/build-time sanity check (returns non-zero on drift).

.EXAMPLE
    pwsh scripts/fix-line-endings.ps1
    pwsh scripts/fix-line-endings.ps1 -Check
#>
[CmdletBinding()]
param([switch]$Check)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot

# (path-glob, target-eol, recurse). Globs are evaluated relative to repoRoot.
# We use Recurse=true for the installer paths because the 2026-04-27 split
# put files under installer/native/, installer/shared/, installer/wsl/, and
# installer/wsl/rootfs/. The previous flat layout (installer/*.cmd etc.) is
# still picked up by the same recursive sweep.
$rules = @(
    @{ Path = 'installer'; Filter = '*.cmd';     Eol = 'CRLF'; Recurse = $true }
    @{ Path = 'installer'; Filter = '*.bat';     Eol = 'CRLF'; Recurse = $true }
    @{ Path = 'installer'; Filter = '*.ps1';     Eol = 'CRLF'; Recurse = $true }
    @{ Path = 'installer'; Filter = '*.vbs';     Eol = 'CRLF'; Recurse = $true }
    @{ Path = 'installer'; Filter = '*.iss';     Eol = 'CRLF'; Recurse = $true }
    @{ Path = 'installer'; Filter = '*.reg';     Eol = 'CRLF'; Recurse = $true }
    # Linux-side artifacts inside the WSL rootfs (and the legacy top-level
    # rootfs path, kept for any leftover checkouts during the transition).
    @{ Path = 'installer\rootfs';     Filter = '*.sh';      Eol = 'LF'; Recurse = $true }
    @{ Path = 'installer\rootfs';     Filter = '*.service'; Eol = 'LF'; Recurse = $true }
    @{ Path = 'installer\rootfs';     Filter = '*.conf';    Eol = 'LF'; Recurse = $true }
    @{ Path = 'installer\wsl\rootfs'; Filter = '*.sh';      Eol = 'LF'; Recurse = $true }
    @{ Path = 'installer\wsl\rootfs'; Filter = '*.service'; Eol = 'LF'; Recurse = $true }
    @{ Path = 'installer\wsl\rootfs'; Filter = '*.conf';    Eol = 'LF'; Recurse = $true }
    @{ Path = 'scripts';   Filter = '*.ps1';     Eol = 'CRLF'; Recurse = $false }
)

function Convert-LineEndings {
    param(
        [Parameter(Mandatory)] [string]$FullPath,
        [Parameter(Mandatory)] [ValidateSet('CRLF','LF')] [string]$Eol
    )
    $bytes = [System.IO.File]::ReadAllBytes($FullPath)
    if ($bytes.Length -eq 0) {
        return [pscustomobject]@{ Changed = $false; CurrentEol = 'EMPTY' }
    }
    # Inspect current state
    $crlfCount = 0; $lfOnlyCount = 0
    for ($i = 0; $i -lt $bytes.Length; $i++) {
        if ($bytes[$i] -eq 0x0A) {
            if ($i -gt 0 -and $bytes[$i-1] -eq 0x0D) { $crlfCount++ }
            else { $lfOnlyCount++ }
        }
    }
    $current = if ($lfOnlyCount -eq 0 -and $crlfCount -gt 0) { 'CRLF' }
               elseif ($crlfCount -eq 0 -and $lfOnlyCount -gt 0) { 'LF' }
               elseif ($crlfCount -eq 0 -and $lfOnlyCount -eq 0) { 'NONE' }
               else { 'MIXED' }
    if ($current -eq $Eol) {
        return [pscustomobject]@{ Changed = $false; CurrentEol = $current }
    }
    # Decode as UTF-8 (preserve BOM if present), normalize, re-emit.
    # We split on \r?\n and rejoin with the desired terminator. This
    # collapses any mixed/CR-only sequences to the target.
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $startIdx = if ($hasBom) { 3 } else { 0 }
    $text = [System.Text.Encoding]::UTF8.GetString($bytes, $startIdx, $bytes.Length - $startIdx)
    # Normalize all line breaks to LF first, then expand to target.
    $text = $text -replace "`r`n", "`n" -replace "`r", "`n"
    if ($Eol -eq 'CRLF') {
        $text = $text -replace "`n", "`r`n"
    }
    if (-not $script:CheckOnly) {
        $enc = New-Object System.Text.UTF8Encoding($hasBom)
        [System.IO.File]::WriteAllText($FullPath, $text, $enc)
    }
    return [pscustomobject]@{ Changed = $true; CurrentEol = $current }
}

$script:CheckOnly = [bool]$Check
$drift = 0
$ok = 0
foreach ($rule in $rules) {
    $dir = Join-Path $repoRoot $rule.Path
    if (-not (Test-Path $dir)) { continue }
    $gciArgs = @{ Path = $dir; Filter = $rule.Filter; File = $true; ErrorAction = 'SilentlyContinue' }
    if ($rule.Recurse) { $gciArgs['Recurse'] = $true }
    Get-ChildItem @gciArgs | ForEach-Object {
        $rel = $_.FullName.Substring($repoRoot.Length + 1)
        $r = Convert-LineEndings -FullPath $_.FullName -Eol $rule.Eol
        if ($r.Changed) {
            $drift++
            $verb = if ($CheckOnly) { 'NEEDS-FIX' } else { 'FIXED   ' }
            Write-Host ("{0}  {1,-4} -> {2,-4}  {3}" -f $verb, $r.CurrentEol, $rule.Eol, $rel)
        } else {
            $ok++
        }
    }
}

Write-Host ""
if ($CheckOnly) {
    if ($drift -gt 0) {
        Write-Host "$drift file(s) have wrong line endings. Run without -Check to fix." -ForegroundColor Red
        exit 1
    }
    Write-Host "All $ok file(s) have correct line endings." -ForegroundColor Green
    exit 0
}
Write-Host "Fixed $drift file(s); $ok file(s) already correct." -ForegroundColor Green
