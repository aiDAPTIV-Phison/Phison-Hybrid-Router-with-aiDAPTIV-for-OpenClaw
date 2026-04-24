; aiDAPTIVClaw Windows Installer - Inno Setup Script (WSL2 sandbox, Q2=C online build)
;
; Ships:
;   - Canonical's vanilla Ubuntu 24.04 WSL base rootfs (ubuntu-base.tar.gz, ~340 MB)
;   - OpenClaw source tarball (openclaw-source.tar.gz, ~10-30 MB, from `git archive HEAD`)
;   - rootfs config files (wsl.conf, openclaw-gateway.service, provision.sh)
;   - Windows-side launcher + dual-phase post-install.ps1
;
; On install, post-install.ps1 (Phase 2) imports the base rootfs as the
; private WSL distro `aidaptivclaw`, stages the source + configs into
; /tmp inside the distro, and runs provision.sh as root to apt-install
; packages, install Node.js, build OpenClaw, and enable the systemd unit.
; Provision time on the customer machine: ~15-30 min, requires internet.
;
; Build with: iscc.exe /DAppVersion=x.x.x openclaw.iss
;
; Design plan: docs/plans/2026-04-23-wsl-sandbox-design.md

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif

[Setup]
AppId={{E8A3F2B1-7C4D-4E5F-9A1B-2D3C4E5F6A7B}
AppName=aiDAPTIVClaw
AppVersion={#AppVersion}
AppVerName=aiDAPTIVClaw {#AppVersion}
AppPublisher=aiDAPTIV
AppPublisherURL=https://github.com/openclaw/openclaw
AppSupportURL=https://github.com/openclaw/openclaw/issues
DefaultDirName={commonpf}\aiDAPTIVClaw
DefaultGroupName=aiDAPTIVClaw
OutputDir=output
OutputBaseFilename=aidaptiv-claw-setup-{#AppVersion}
Compression=lzma2/ultra64
SolidCompression=yes
; Admin required: wsl --install and wsl --import need elevation,
; and we write to ProgramData and Program Files.
PrivilegesRequired=admin
SetupIconFile=Gemini_Generated_Image_aiDAPTIV.ico
UninstallDisplayIcon={app}\Gemini_Generated_Image_aiDAPTIV.ico
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
LicenseFile=license.txt
DisableProgramGroupPage=yes
InfoBeforeFile=pre-install-note.txt

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Additional options:"
Name: "startmenuicon"; Description: "Create a Start Menu shortcut"; GroupDescription: "Additional options:"; Flags: checkedonce

[Files]
; Canonical Ubuntu 24.04 WSL base rootfs (cached/downloaded by scripts/build-installer.ps1).
; Imported by post-install.ps1 Phase 2 as the `aidaptivclaw` distro.
Source: "rootfs\ubuntu-base.tar.gz"; DestDir: "{app}\rootfs"; Flags: ignoreversion

; OpenClaw source code packed via `git archive HEAD` at build time.
; provision.sh extracts this inside the customer's distro and builds OpenClaw.
Source: "rootfs\openclaw-source.tar.gz"; DestDir: "{app}\rootfs"; Flags: ignoreversion

; Distro config + provisioning script (staged into /tmp/ inside the distro
; by post-install.ps1, then consumed by provision.sh).
Source: "rootfs\wsl.conf"; DestDir: "{app}\rootfs"; Flags: ignoreversion
Source: "rootfs\openclaw-gateway.service"; DestDir: "{app}\rootfs"; Flags: ignoreversion
Source: "rootfs\provision.sh"; DestDir: "{app}\rootfs"; Flags: ignoreversion

; PowerShell provisioning orchestrator (runs in two phases — see header).
Source: "post-install.ps1"; DestDir: "{app}"; Flags: ignoreversion

; Launcher and helpers
Source: "openclaw-launcher.vbs"; DestDir: "{app}"; Flags: ignoreversion
Source: "openclaw-launcher.cmd"; DestDir: "{app}"; Flags: ignoreversion
Source: "openclaw-template.json"; DestDir: "{app}"; Flags: ignoreversion
Source: "Gemini_Generated_Image_aiDAPTIV.ico"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{userdesktop}\aiDAPTIVClaw"; Filename: "{app}\openclaw-launcher.vbs"; IconFilename: "{app}\Gemini_Generated_Image_aiDAPTIV.ico"; Tasks: desktopicon
Name: "{group}\aiDAPTIVClaw"; Filename: "{app}\openclaw-launcher.vbs"; IconFilename: "{app}\Gemini_Generated_Image_aiDAPTIV.ico"; Tasks: startmenuicon
Name: "{group}\Uninstall aiDAPTIVClaw"; Filename: "{uninstallexe}"; Tasks: startmenuicon

[Run]
; Optional post-install launch; only runs if WSL setup completed without
; needing a reboot (NeedsReboot=False). Otherwise the user reboots and a
; scheduled task fires Phase 2 + opens the browser automatically.
Filename: "{app}\openclaw-launcher.vbs"; Description: "Launch aiDAPTIVClaw"; Flags: nowait postinstall skipifsilent shellexec; Check: NotNeedsReboot

[UninstallDelete]
; Files left around after Phase 2 / runtime that aren't tracked by the installer.
Type: files; Name: "{app}\install.log"

[Code]
var
  BuildSucceeded: Boolean;
  NeedsReboot: Boolean;

{ --- String replace utility (used by WriteConfigFile) --- }

function ReplaceSubstring(const S, OldPattern, NewPattern: String): String;
var
  SearchFrom, Idx: Integer;
  Result_, Tail: String;
begin
  Result_ := S;
  SearchFrom := 1;
  while SearchFrom <= Length(Result_) do
  begin
    Tail := Copy(Result_, SearchFrom, Length(Result_) - SearchFrom + 1);
    Idx := Pos(OldPattern, Tail);
    if Idx = 0 then
      Break;
    Idx := Idx + SearchFrom - 1;
    Delete(Result_, Idx, Length(OldPattern));
    Insert(NewPattern, Result_, Idx);
    SearchFrom := Idx + Length(NewPattern);
  end;
  Result := Result_;
end;

{ --- Write host-side config file from template ---
  The host-side openclaw.json under %USERPROFILE%\.openclaw\ is kept for
  backward compat with the Windows CLI; the gateway running inside WSL
  reads its own config from /home/openclaw/.openclaw/openclaw.json. }

procedure WriteConfigFile;
var
  TemplateFile, ConfigDir, ConfigFile, UserProfile, Content: String;
  Lines: TArrayOfString;
  I: Integer;
begin
  UserProfile := ExpandConstant('{%USERPROFILE}');
  ConfigDir := UserProfile + '\.openclaw';
  ConfigFile := ConfigDir + '\openclaw.json';
  TemplateFile := ExpandConstant('{app}\openclaw-template.json');

  if FileExists(ConfigFile) then
  begin
    Log('Config file already exists, skipping: ' + ConfigFile);
    Exit;
  end;

  if not DirExists(ConfigDir) then
    ForceDirectories(ConfigDir);

  if LoadStringsFromFile(TemplateFile, Lines) then
  begin
    Content := '';
    for I := 0 to GetArrayLength(Lines) - 1 do
    begin
      if I > 0 then
        Content := Content + #13#10;
      Content := Content + Lines[I];
    end;

    { The template now stores WSL-native paths; no Windows path
      substitution needed. Only the version metadata gets bumped. }
    Content := ReplaceSubstring(Content, '"lastTouchedVersion": "2026.3.12"', '"lastTouchedVersion": "' + '{#AppVersion}' + '"');
    Content := ReplaceSubstring(Content, '"lastRunVersion": "2026.3.12"', '"lastRunVersion": "' + '{#AppVersion}' + '"');

    SaveStringToFile(ConfigFile, Content, False);
    Log('Config file written: ' + ConfigFile);
  end else
  begin
    Log('Failed to load template: ' + TemplateFile);
  end;
end;

{ --- Post-install: run dual-phase post-install.ps1 (Phase 1) --- }

procedure RunPostInstallBuild;
var
  ResultCode: Integer;
  AppDir, LogFile, Params: String;
  ExecResult: Boolean;
begin
  BuildSucceeded := False;
  NeedsReboot := False;
  AppDir := ExpandConstant('{app}');
  LogFile := AppDir + '\install.log';

  Params := '-NoProfile -ExecutionPolicy Bypass -File "' + AppDir + '\post-install.ps1"' +
            ' -AppDir "' + AppDir + '"' +
            ' -Phase 1' +
            ' -FromInstaller';

  SaveStringToFile(LogFile, '=== Installer [Code] diagnostic ===' + #13#10, False);
  SaveStringToFile(LogFile, 'invocation: powershell.exe ' + Params + #13#10, True);
  SaveStringToFile(LogFile, 'workdir: ' + AppDir + #13#10, True);

  WizardForm.StatusLabel.Caption := 'Provisioning WSL sandbox (downloads packages + builds OpenClaw, ~15-30 min)...';
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
    { WSL was just installed (or vmcompute pending reboot) -- reboot is
      required. Scheduled task already registered by post-install.ps1 to
      fire Phase 2 with elevated privileges at the next user logon. }
    NeedsReboot := True;
    BuildSucceeded := True;
  end
  else if ExecResult and (ResultCode = 3) then
  begin
    { Hard prerequisite failure (no VT-x / unsupported Windows).
      post-install.ps1 already showed a dialog. Mark as failed so the
      Inno Setup wizard ends with an error page. }
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

{ --- Inno Setup callbacks --- }

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then
  begin
    WriteConfigFile;
    RunPostInstallBuild;
  end;
end;

procedure CurPageChanged(CurPageID: Integer);
begin
  if CurPageID = wpFinished then
  begin
    if not BuildSucceeded then
    begin
      WizardForm.FinishedHeadingLabel.Caption := 'Installation Incomplete';
      WizardForm.FinishedLabel.Caption :=
        'aiDAPTIVClaw files have been extracted, but the WSL sandbox could not be provisioned.' + #13#10 + #13#10 +
        'Check the log file for details:' + #13#10 +
        ExpandConstant('{app}\install.log') + #13#10 + #13#10 +
        'You can monitor or tail it live with:' + #13#10 +
        ExpandConstant('  Get-Content "{app}\install.log" -Wait -Tail 50') + #13#10 + #13#10 +
        'You can retry the install from PowerShell:' + #13#10 +
        ExpandConstant('  powershell -File "{app}\post-install.ps1" -AppDir "{app}" -Phase 1');
      WizardForm.RunList.Visible := False;
    end
    else if NeedsReboot then
    begin
      WizardForm.FinishedHeadingLabel.Caption := 'Phase 1 of 2 complete -- reboot required';
      WizardForm.FinishedLabel.Caption :=
        'aiDAPTIVClaw has finished extracting files and configuring WSL.' + #13#10 + #13#10 +
        'IMPORTANT: This is only Phase 1. Phase 2 (download Ubuntu base, ' +
        'install Node.js, build OpenClaw -- approximately 15 to 30 minutes) ' +
        'will start AUTOMATICALLY after you reboot Windows and log back in.' + #13#10 + #13#10 +
        'A PowerShell window will pop up running the build. Do not close it.' + #13#10 + #13#10 +
        'To monitor live progress, open a separate PowerShell and run:' + #13#10 +
        ExpandConstant('  Get-Content "{app}\install.log" -Wait -Tail 50') + #13#10 + #13#10 +
        'When build completes, your browser will open to the OpenClaw dashboard.';
      WizardForm.RunList.Visible := False;
    end;
  end;
end;

{ Tell Inno Setup whether to add a "reboot now / later" prompt at the end.
  Hooked via the standard NeedRestart() callback. }
function NeedRestart(): Boolean;
begin
  Result := NeedsReboot;
end;

{ Used as a [Run] Check: to suppress the post-install launcher when a
  reboot is pending (RunOnce will open the browser after reboot instead). }
function NotNeedsReboot(): Boolean;
begin
  Result := not NeedsReboot;
end;

{ --- Uninstall: tear down the WSL distro --- }

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  AppDir, ConfigDir, DistroDir: String;
  ResultCode: Integer;
begin
  if CurUninstallStep = usUninstall then
  begin
    AppDir := ExpandConstant('{app}');

    { Unregister the WSL distro. This destroys the sandbox VM, including
      everything under /home/openclaw — which is the user's workspace.
      The uninstaller already prompts the user that this is irreversible. }
    Exec(ExpandConstant('{cmd}'),
         '/C wsl --unregister aidaptivclaw',
         AppDir, SW_HIDE, ewWaitUntilTerminated, ResultCode);

    { Tear down a pending Phase 2 resume task if a half-finished install
      left one behind — otherwise the task would fire after uninstall and
      try to invoke a now-deleted post-install.ps1. }
    Exec(ExpandConstant('{cmd}'),
         '/C schtasks /Delete /TN aiDAPTIVClawPhase2Resume /F',
         AppDir, SW_HIDE, ewWaitUntilTerminated, ResultCode);

    { Backwards-compat: also wipe any HKCU RunOnce entry from older
      installer versions that used RunOnce instead of a scheduled task. }
    RegDeleteValue(HKEY_CURRENT_USER,
                   'Software\Microsoft\Windows\CurrentVersion\RunOnce',
                   'aiDAPTIVClawPostInstall');
  end;

  if CurUninstallStep = usPostUninstall then
  begin
    AppDir := ExpandConstant('{app}');
    DistroDir := ExpandConstant('{commonappdata}') + '\aiDAPTIVClaw\wsl';

    { Remove the imported distro directory left behind by wsl --unregister
      (wsl --unregister normally cleans this up, but if the user manually
      mucked with it we make sure it's gone). }
    if DirExists(DistroDir) then
      DelTree(DistroDir, True, True, True);

    { Remove any remaining files in the app directory. }
    if DirExists(AppDir) then
      DelTree(AppDir, True, True, True);

    { Ask about removing the host-side config dir. }
    ConfigDir := ExpandConstant('{%USERPROFILE}') + '\.openclaw';
    if DirExists(ConfigDir) then
    begin
      if MsgBox('Do you want to remove aiDAPTIVClaw configuration files at:' + #13#10 +
                ConfigDir + #13#10 + #13#10 +
                'Workspace data inside the WSL sandbox has already been removed.',
                mbConfirmation, MB_YESNO) = IDYES then
      begin
        DelTree(ConfigDir, True, True, True);
      end;
    end;
  end;
end;
