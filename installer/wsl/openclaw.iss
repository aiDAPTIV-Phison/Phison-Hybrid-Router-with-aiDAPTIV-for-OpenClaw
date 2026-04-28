; Phison Hybrid Router with aiDAPTIV for OpenClaw - Inno Setup Script (WSL2 sandbox, Q2=C online build)
;
; Ships:
;   - Canonical's vanilla Ubuntu 24.04 WSL base rootfs (ubuntu-base.tar.gz, ~340 MB)
;   - OpenClaw source tarball (openclaw-source.tar.gz, ~10-30 MB, from `git archive HEAD`)
;   - rootfs config files (wsl.conf, openclaw-gateway.service, provision.sh)
;   - Windows-side launcher + dual-phase post-install.ps1
;
; On install, post-install.ps1 (Phase 2) imports the base rootfs as the
; private WSL distro `phison-hybrid-openclaw`, stages the source + configs into
; /tmp inside the distro, and runs provision.sh as root to apt-install
; packages, install Node.js, build OpenClaw, and enable the systemd unit.
; Provision time on the customer machine: ~15-30 min, requires internet.
;
; Build with:
;   pwsh scripts\build-installer.ps1 -Variant wsl
;   (or directly: iscc.exe /DAppVersion=x.x.x installer\wsl\openclaw.iss)
;
; Coexists with the "native" flavor (installer/native/openclaw.iss) on the
; same machine -- the two installers carry different AppId GUIDs so Windows
; treats them as independent products.
;
; Layout assumptions (paths relative to this .iss file):
;   ..\shared\         -- icons / license / pre-install note / launcher.vbs
;   rootfs\            -- ubuntu-base.tar.gz, openclaw-source.tar.gz, configs
;   ..\output\         -- compiled .exe lands here (shared with native flavor)
;
; Design plan: docs/plans/2026-04-23-wsl-sandbox-design.md

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif

[Setup]
; Distinct AppId from the native flavor -- this lets the WSL build install
; in parallel without Windows treating it as an upgrade of the native one
; (which would clobber the native uninstall entry). Generated 2026-04-27.
; AppId regenerated 2026-04-28 for the Phison Hybrid Router with aiDAPTIV for
; OpenClaw rebrand. Treats this as a brand-new product so existing aiDAPTIVClaw
; installs are NOT touched on upgrade. Customers must manually uninstall the
; old aiDAPTIVClaw entry from "Programs and Features" if they want to fully
; migrate.
;
; Naming convention (see docs/plans/2026-04-23-wsl-sandbox-design.md):
;   - Long name "Phison Hybrid Router with aiDAPTIV for OpenClaw" is the
;     official brand and is used for all wide-display surfaces: wizard pages,
;     ARP DisplayName, dialog body text.
;   - Short name "Phison Hybrid OpenClaw" is used where Windows truncates
;     (terminal title, log prefix, dialog title bars) and for filesystem /
;     start-menu folder names where deeply-nested paths approach MAX_PATH=260.
;   - Lowercase identifier "phison-hybrid-openclaw" is the WSL distro name.
AppId={{C3471C10-DA2F-42B4-968B-2BDF7C19202D}
AppName=Phison Hybrid Router with aiDAPTIV for OpenClaw
AppVersion={#AppVersion}
AppVerName=Phison Hybrid Router with aiDAPTIV for OpenClaw {#AppVersion}
AppPublisher=aiDAPTIV
AppPublisherURL=https://github.com/aiDAPTIV-Phison/OpenClaw-Integration-with-aiDAPTIV
AppSupportURL=https://github.com/aiDAPTIV-Phison/OpenClaw-Integration-with-aiDAPTIV/issues
DefaultDirName={commonpf}\Phison Hybrid OpenClaw
DefaultGroupName=Phison Hybrid OpenClaw
OutputDir=..\output
OutputBaseFilename=phison-hybrid-openclaw-setup-wsl-{#AppVersion}
Compression=lzma2/ultra64
SolidCompression=yes
; Admin required: wsl --install and wsl --import need elevation,
; and we write to ProgramData and Program Files.
PrivilegesRequired=admin
SetupIconFile=..\shared\Gemini_Generated_Image_aiDAPTIV.ico
UninstallDisplayIcon={app}\Gemini_Generated_Image_aiDAPTIV.ico
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
LicenseFile=..\shared\license.txt
DisableProgramGroupPage=yes
InfoBeforeFile=..\shared\pre-install-note.txt

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Additional options:"
Name: "startmenuicon"; Description: "Create a Start Menu shortcut"; GroupDescription: "Additional options:"; Flags: checkedonce
; --- Windows-integration toggle (sandbox break-out, OFF by default) ---
;
; UNCHECKED (default): the installed distro keeps wsl.conf as shipped,
;   i.e. [automount] enabled=false + [interop] enabled=false +
;   appendWindowsPath=false. The gateway cannot see /mnt/c/* and cannot
;   spawn cmd.exe / powershell.exe / explorer.exe. This is the strict
;   sandbox model documented in 2026-04-23-wsl-sandbox-design.md.
;
; CHECKED: post-install.ps1 sed-flips those three flags to "true" before
;   provision.sh installs wsl.conf into /etc/wsl.conf. The gateway can
;   then read any Windows file the user can read AND launch arbitrary
;   Windows binaries -- enabling "set me an alarm", clipboard read/write,
;   "open D:\foo in Explorer", Office-COM automation, etc. This is a
;   deliberate weakening of threat-model items A.1 / A.2; the user opts
;   in via this checkbox after reading the description.
;
; checkedonce is intentionally NOT used: an upgrade should re-prompt
; the user, not silently re-apply a possibly stale choice from months
; ago.
Name: "windowsbridge"; Description: "Allow OpenClaw to access Windows files and run Windows commands (needed for: alarms, clipboard, opening folders, Office automation). Leave unchecked for strict sandbox."; GroupDescription: "Windows integration:"; Flags: unchecked

[Files]
; Canonical Ubuntu 24.04 WSL base rootfs (cached/downloaded by scripts/build-installer.ps1).
; Imported by post-install.ps1 Phase 2 as the `phison-hybrid-openclaw` distro.
Source: "rootfs\ubuntu-base.tar.gz"; DestDir: "{app}\rootfs"; Flags: ignoreversion

; OpenClaw source code packed via `git archive HEAD` at build time.
; provision.sh extracts this inside the customer's distro and builds OpenClaw.
Source: "rootfs\openclaw-source.tar.gz"; DestDir: "{app}\rootfs"; Flags: ignoreversion

; Distro config + provisioning script (staged into /tmp/ inside the distro
; by post-install.ps1, then consumed by provision.sh).
Source: "rootfs\wsl.conf"; DestDir: "{app}\rootfs"; Flags: ignoreversion
Source: "rootfs\openclaw-gateway.service"; DestDir: "{app}\rootfs"; Flags: ignoreversion
Source: "rootfs\provision.sh"; DestDir: "{app}\rootfs"; Flags: ignoreversion

; PowerShell provisioning orchestrator (runs in two phases -- see header).
Source: "post-install.ps1"; DestDir: "{app}"; Flags: ignoreversion

; Launcher and helpers.
;
; The launcher boots the distro, opens a Windows Terminal tab running
; the gateway in the foreground (Ctrl-C stops it), and points the user's
; browser at the dashboard. There is no longer a hidden keep-alive
; helper -- the visible gateway window IS the keep-alive: WSL2 only
; idle-shuts-down a distro when it has zero attached wsl.exe sessions,
; and the launcher's wt.exe tab counts as one for as long as the user
; keeps it open. See docs/plans/2026-04-23-wsl-sandbox-design.md.
Source: "..\shared\openclaw-launcher.vbs"; DestDir: "{app}"; Flags: ignoreversion
Source: "openclaw-launcher.cmd"; DestDir: "{app}"; Flags: ignoreversion
; openclaw.json template -- patched by post-install.ps1 Phase 2 with the
; user's cloud-provider choice (collected on the wizard's CloudPage and
; persisted via install-options.ini), then written to both
; %USERPROFILE%\.openclaw\openclaw.json and /home/openclaw/.openclaw/
; openclaw.json inside the WSL distro.
Source: "openclaw-template.json"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\shared\Gemini_Generated_Image_aiDAPTIV.ico"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
; The launcher shortcuts (desktop + Start Menu group) are NOT created
; here -- they are created later by [Code] / post-install.ps1 ONLY after
; Phase 2 provisioning succeeds and the gateway responds. This keeps
; the invariant "shortcut on disk = Phison Hybrid Router with aiDAPTIV for OpenClaw is installed and
; usable", so a half-finished install never leaves a misleading icon
; that the user might double-click and then see fail.
;
; Only the Uninstall entry is created here -- the user must always
; have a way to back out via Start Menu, even from a partial install
; (Add/Remove Programs is the other escape hatch, registered by Inno
; Setup itself regardless of [Icons]).
Name: "{group}\Uninstall Phison Hybrid OpenClaw"; Filename: "{uninstallexe}"

[Run]
; Optional post-install launch; only runs if WSL setup completed without
; needing a reboot (NeedsReboot=False). Otherwise the user reboots and a
; scheduled task fires Phase 2 + opens the browser automatically.
Filename: "{app}\openclaw-launcher.vbs"; Description: "Launch Phison Hybrid Router with aiDAPTIV for OpenClaw"; Flags: nowait postinstall skipifsilent shellexec; Check: NotNeedsReboot

[UninstallDelete]
; Files left around after Phase 2 / runtime that aren't tracked by the installer.
Type: files; Name: "{app}\install.log"

[Code]
var
  BuildSucceeded: Boolean;
  NeedsReboot: Boolean;
  // Cloud provider wizard page. Values are read by RunPostInstallBuild ->
  // WriteInstallOptions and consumed by post-install.ps1 Phase 2. The
  // actual openclaw.json (both Windows host copy and WSL guest copy) is
  // written by Phase 2 from openclaw-template.json + these values, so
  // the apiKey never sits in plain text under the install directory
  // longer than the install window.
  // NOTE: line comments (//) are used here on purpose. Inno Setup's
  // Pascal Script supports {curly} and (*starstar*) block comments but
  // neither form nests, and embedding any closer (such as a }-terminated
  // app-dir constant or a *) glyph) inside the comment body silently
  // ends the comment and turns the rest into broken code.
  CloudPage: TWizardPage;
  ProviderCombo: TNewComboBox;
  ApiKeyEdit: TNewEdit;
  ModelEdit: TNewEdit;

{ --- Provider metadata table -----------------------------------------
  Five providers, each with: id (used as JSON key under
  models.providers), baseUrl, api shape (drives provider plugin
  dispatch inside the gateway), and a sensible default model id as of
  2026-04. Update both the dropdown labels and these tables together
  if adding/removing a provider. }

function GetProviderId(Idx: Integer): String;
begin
  case Idx of
    0: Result := 'openrouter';
    1: Result := 'google';
    2: Result := 'anthropic';
    3: Result := 'openai';
    4: Result := 'together';
  else
    Result := 'openrouter';
  end;
end;

function GetProviderBaseUrl(Idx: Integer): String;
begin
  case Idx of
    0: Result := 'https://openrouter.ai/api/v1';
    1: Result := 'https://generativelanguage.googleapis.com/v1beta';
    2: Result := 'https://api.anthropic.com';
    3: Result := 'https://api.openai.com/v1';
    4: Result := 'https://api.together.xyz/v1';
  else
    Result := 'https://openrouter.ai/api/v1';
  end;
end;

function GetProviderApi(Idx: Integer): String;
begin
  case Idx of
    0: Result := 'openai-completions';
    1: Result := 'google-generative-ai';
    2: Result := 'anthropic-messages';
    3: Result := 'openai-completions';
    4: Result := 'openai-completions';
  else
    Result := 'openai-completions';
  end;
end;

function GetProviderDefaultModel(Idx: Integer): String;
begin
  { Defaults reflect the 2026-04 frontier-tier "fast / cheap" model
    of each provider -- picked to match what most users hitting Next
    twice on the wizard would actually want to run. }
  case Idx of
    0: Result := 'google/gemini-3.1-flash-lite-preview';
    1: Result := 'gemini-3-flash-preview';
    2: Result := 'claude-sonnet-4-6';
    3: Result := 'gpt-5.4-mini';
    4: Result := 'meta-llama/Llama-4-Maverick-17B-128E-Instruct-FP8';
  else
    Result := 'google/gemini-3.1-flash-lite-preview';
  end;
end;

{ --- Cloud page event: refresh model default when provider changes --- }

procedure ProviderComboChange(Sender: TObject);
begin
  ModelEdit.Text := GetProviderDefaultModel(ProviderCombo.ItemIndex);
end;

{ --- Windows-integration mode helper -----------------------------------
  Returns '1' when the user checked the windowsbridge task, '0'
  otherwise. Read by WriteInstallOptions and persisted into
  install-options.ini's [mode] permissive=. post-install.ps1 Phase 2
  consumes the flag and (if 1) sed-flips wsl.conf [automount]/[interop]
  to enabled=true before staging it into the distro at /etc/wsl.conf.
  See the [Tasks] section header for the full security trade-off. }

function GetWindowsBridgeFlag: String;
begin
  if WizardIsTaskSelected('windowsbridge') then
    Result := '1'
  else
    Result := '0';
end;

{ --- Wizard initialisation: insert CloudPage after wpSelectTasks --- }

procedure InitializeWizard;
var
  LblIntro, LblProvider, LblApiKey, LblModel, LblSkip: TNewStaticText;
begin
  CloudPage := CreateCustomPage(wpSelectTasks,
    'Cloud Model Provider',
    'Configure the cloud model provider used by hybrid-gateway (optional).');

  LblIntro := TNewStaticText.Create(CloudPage);
  LblIntro.Parent := CloudPage.Surface;
  LblIntro.Width := CloudPage.SurfaceWidth;
  LblIntro.AutoSize := False;
  LblIntro.Height := ScaleY(32);
  LblIntro.WordWrap := True;
  LblIntro.Caption :=
    'Pick a cloud LLM provider and paste its API key. You can leave the' + #13#10 +
    'API key blank now and configure it later from the OpenClaw UI.';
  LblIntro.Top := 0;
  LblIntro.Left := 0;

  LblProvider := TNewStaticText.Create(CloudPage);
  LblProvider.Parent := CloudPage.Surface;
  LblProvider.Caption := 'Cloud Provider:';
  LblProvider.Top := ScaleY(40);
  LblProvider.Left := 0;

  ProviderCombo := TNewComboBox.Create(CloudPage);
  ProviderCombo.Parent := CloudPage.Surface;
  ProviderCombo.Top := ScaleY(62);
  ProviderCombo.Left := 0;
  ProviderCombo.Width := CloudPage.SurfaceWidth;
  ProviderCombo.Style := csDropDownList;
  ProviderCombo.Items.Add('OpenRouter');
  ProviderCombo.Items.Add('Google Gemini');
  ProviderCombo.Items.Add('Anthropic (Claude)');
  ProviderCombo.Items.Add('OpenAI');
  ProviderCombo.Items.Add('Together AI');
  ProviderCombo.ItemIndex := 0;
  ProviderCombo.OnChange := @ProviderComboChange;

  LblApiKey := TNewStaticText.Create(CloudPage);
  LblApiKey.Parent := CloudPage.Surface;
  LblApiKey.Caption := 'API Key:';
  LblApiKey.Top := ScaleY(102);
  LblApiKey.Left := 0;

  ApiKeyEdit := TNewEdit.Create(CloudPage);
  ApiKeyEdit.Parent := CloudPage.Surface;
  ApiKeyEdit.Top := ScaleY(124);
  ApiKeyEdit.Left := 0;
  ApiKeyEdit.Width := CloudPage.SurfaceWidth;
  { Mask the key on screen -- it still travels through install-options.ini
    in plain text (consumed and removed by Phase 2), but no shoulder-surf. }
  ApiKeyEdit.PasswordChar := '*';
  ApiKeyEdit.Text := '';

  LblModel := TNewStaticText.Create(CloudPage);
  LblModel.Parent := CloudPage.Surface;
  LblModel.Caption := 'Model:';
  LblModel.Top := ScaleY(164);
  LblModel.Left := 0;

  ModelEdit := TNewEdit.Create(CloudPage);
  ModelEdit.Parent := CloudPage.Surface;
  ModelEdit.Top := ScaleY(186);
  ModelEdit.Left := 0;
  ModelEdit.Width := CloudPage.SurfaceWidth;
  ModelEdit.Text := GetProviderDefaultModel(0);

  LblSkip := TNewStaticText.Create(CloudPage);
  LblSkip.Parent := CloudPage.Surface;
  LblSkip.Width := CloudPage.SurfaceWidth;
  LblSkip.AutoSize := False;
  LblSkip.Height := ScaleY(32);
  LblSkip.WordWrap := True;
  LblSkip.Caption :=
    'Tip: Phison Hybrid Router with aiDAPTIV for OpenClaw will install regardless of what you enter here.' + #13#10 +
    'The key is stored only in the WSL sandbox config, not in the registry.';
  LblSkip.Top := ScaleY(226);
  LblSkip.Left := 0;
end;

{ --- Create launcher .lnk shortcuts via WScript.Shell COM ---
  Run from CurPageChanged on inline-success path. NeedsReboot path
  defers shortcut creation to post-install.ps1 Phase 2 (post-reboot)
  so that "shortcut on disk = Phison Hybrid Router with aiDAPTIV for OpenClaw is fully installed" stays
  true regardless of when Phase 2 actually completes. }

procedure CreateLnk(LnkPath, TargetPath, IconPath, WorkDir, Description: String);
var
  Shell, Lnk: Variant;
begin
  Shell := CreateOleObject('WScript.Shell');
  Lnk := Shell.CreateShortcut(LnkPath);
  Lnk.TargetPath := TargetPath;
  Lnk.IconLocation := IconPath;
  Lnk.WorkingDirectory := WorkDir;
  Lnk.Description := Description;
  Lnk.Save;
end;

procedure CreateLauncherShortcuts;
var
  AppDir, LauncherPath, IconPath, GroupDir: String;
begin
  AppDir := ExpandConstant('{app}');
  LauncherPath := AppDir + '\openclaw-launcher.vbs';
  IconPath := AppDir + '\Gemini_Generated_Image_aiDAPTIV.ico';

  if WizardIsTaskSelected('desktopicon') then
  begin
    try
      CreateLnk(ExpandConstant('{userdesktop}\Phison Hybrid OpenClaw.lnk'),
                LauncherPath, IconPath, AppDir, 'Launch Phison Hybrid Router with aiDAPTIV for OpenClaw');
      Log('Created desktop shortcut');
    except
      Log('Failed to create desktop shortcut: ' + GetExceptionMessage);
    end;
  end;

  if WizardIsTaskSelected('startmenuicon') then
  begin
    GroupDir := ExpandConstant('{group}');
    if not DirExists(GroupDir) then
      ForceDirectories(GroupDir);
    try
      CreateLnk(GroupDir + '\Phison Hybrid OpenClaw.lnk',
                LauncherPath, IconPath, AppDir, 'Launch Phison Hybrid Router with aiDAPTIV for OpenClaw');
      Log('Created Start Menu shortcut');
    except
      Log('Failed to create Start Menu shortcut: ' + GetExceptionMessage);
    end;
  end;
end;

{ --- Write install-options.ini for post-install.ps1 Phase 2 to read ---
  Phase 2 runs OUT of the Inno Setup process (via scheduled task after
  reboot), so it cannot call WizardIsTaskSelected directly. We persist
  the user's task choices to disk before launching PowerShell so that
  the post-reboot Phase 2 can recreate the same shortcut set the user
  asked for during the wizard. }

procedure WriteInstallOptions;
var
  OptionsFile, Content, AppDir, DesktopFlag, StartMenuFlag: String;
  Idx: Integer;
  ProviderId, BaseUrl, Api, ApiKey, Model: String;
begin
  AppDir := ExpandConstant('{app}');
  OptionsFile := AppDir + '\install-options.ini';
  if WizardIsTaskSelected('desktopicon') then DesktopFlag := '1' else DesktopFlag := '0';
  if WizardIsTaskSelected('startmenuicon') then StartMenuFlag := '1' else StartMenuFlag := '0';

  { Snapshot CloudPage values. Empty ApiKey -> Phase 2 falls through to a
    "no key" path that still writes a clean openclaw.json from the
    template (just without injecting credentials). }
  Idx := ProviderCombo.ItemIndex;
  ProviderId := GetProviderId(Idx);
  BaseUrl := GetProviderBaseUrl(Idx);
  Api := GetProviderApi(Idx);
  ApiKey := Trim(ApiKeyEdit.Text);
  Model := Trim(ModelEdit.Text);
  if Model = '' then
    Model := GetProviderDefaultModel(Idx);

  Content :=
    '; Read by post-install.ps1 Phase 2 to know which user-facing' + #13#10 +
    '; shortcuts to create and which cloud LLM provider to seed into' + #13#10 +
    '; openclaw.json after Phase 2 succeeds. Generated by openclaw.iss' + #13#10 +
    '; [Code] before Phase 1 invocation. The [provider] section is' + #13#10 +
    '; deleted by Phase 2 right after consumption so the apiKey does' + #13#10 +
    '; not stay on disk in plain text any longer than necessary.' + #13#10 +
    '[install]' + #13#10 +
    { appName drives the .lnk filename in post-install.ps1 (Phase 2:
      "$AppName.lnk"). MUST stay short to match the hard-coded sweep
      names in CurUninstallStepChanged below and to avoid MAX_PATH when
      nested under deep desktop paths. The long ARP / wizard display
      name lives in [Setup] AppName= and is independent of this field. }
    'appName=Phison Hybrid OpenClaw' + #13#10 +
    'appDir=' + AppDir + #13#10 +
    'launcherPath=' + AppDir + '\openclaw-launcher.vbs' + #13#10 +
    'iconPath=' + AppDir + '\Gemini_Generated_Image_aiDAPTIV.ico' + #13#10 +
    'startMenuGroup=' + ExpandConstant('{group}') + #13#10 +
    'userDesktop=' + ExpandConstant('{userdesktop}') + #13#10 +
    '[shortcuts]' + #13#10 +
    'desktop=' + DesktopFlag + #13#10 +
    'startMenu=' + StartMenuFlag + #13#10 +
    '[provider]' + #13#10 +
    'id=' + ProviderId + #13#10 +
    'baseUrl=' + BaseUrl + #13#10 +
    'api=' + Api + #13#10 +
    'model=' + Model + #13#10 +
    'apiKey=' + ApiKey + #13#10 +
    '[mode]' + #13#10 +
    'permissive=' + GetWindowsBridgeFlag + #13#10;

  SaveStringToFile(OptionsFile, Content, False);
  Log('Wrote install-options.ini (desktop=' + DesktopFlag +
      ', startMenu=' + StartMenuFlag +
      ', provider=' + ProviderId +
      ', permissive=' + GetWindowsBridgeFlag +
      ', apiKey=' + IntToStr(Length(ApiKey)) + ' chars)');
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

  { Persist user's shortcut preferences before Phase 1 -- Phase 2 (which
    may run post-reboot, out-of-process) reads this to know which
    shortcuts to create on success. }
  WriteInstallOptions;

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
    // openclaw.json (both the host backward-compat copy under
    // %USERPROFILE%\.openclaw\ and the WSL guest copy under
    // /home/openclaw/.openclaw/) is now written by post-install.ps1
    // Phase 2, populated from openclaw-template.json plus the
    // provider section of install-options.ini. Doing it in Phase 2
    // means we never write a half-configured config to disk if the
    // install fails partway, and the apiKey stays inside the WSL
    // sandbox rather than the Windows user profile.
    // Comments here are line comments on purpose -- see the comment
    // near the var block above for the rationale.
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
        'Phison Hybrid Router with aiDAPTIV for OpenClaw files have been extracted, but the WSL sandbox could not be provisioned.' + #13#10 + #13#10 +
        'No desktop / Start Menu launcher shortcut was created. The shortcut is added' + #13#10 +
        'only after a successful install -- if you see one, the install is complete.' + #13#10 + #13#10 +
        'Check the log file for details:' + #13#10 +
        ExpandConstant('{app}\install.log') + #13#10 + #13#10 +
        'You can monitor or tail it live with:' + #13#10 +
        ExpandConstant('  Get-Content "{app}\install.log" -Wait -Tail 50') + #13#10 + #13#10 +
        'You can retry the install from PowerShell:' + #13#10 +
        ExpandConstant('  powershell -File "{app}\post-install.ps1" -AppDir "{app}" -Phase 1') + #13#10 + #13#10 +
        'Or use Programs and Features > Phison Hybrid Router with aiDAPTIV for OpenClaw to fully remove and start over.';
      WizardForm.RunList.Visible := False;
    end
    else if NeedsReboot then
    begin
      WizardForm.FinishedHeadingLabel.Caption := 'Phase 1 of 2 complete -- reboot required';
      WizardForm.FinishedLabel.Caption :=
        'Phison Hybrid Router with aiDAPTIV for OpenClaw has finished extracting files and configuring WSL.' + #13#10 + #13#10 +
        'IMPORTANT: This is only Phase 1. Phase 2 (download Ubuntu base, ' +
        'install Node.js, build OpenClaw -- approximately 15 to 30 minutes) ' +
        'will start AUTOMATICALLY after you reboot Windows and log back in.' + #13#10 + #13#10 +
        'A PowerShell window will pop up running the build. Do not close it.' + #13#10 + #13#10 +
        'To monitor live progress, open a separate PowerShell and run:' + #13#10 +
        ExpandConstant('  Get-Content "{app}\install.log" -Wait -Tail 50') + #13#10 + #13#10 +
        'When build completes, your browser will open to the OpenClaw dashboard.' + #13#10 +
        'A desktop / Start Menu shortcut will appear at that point -- its presence' + #13#10 +
        'is your signal that Phison Hybrid Router with aiDAPTIV for OpenClaw is fully installed and usable.';
      WizardForm.RunList.Visible := False;
    end
    else
    begin
      { Inline-success path: Phase 1 ran through to Phase 2 in the same
        process and everything is ready. THIS is where the user-facing
        shortcuts are created -- by construction, "shortcut on disk"
        implies "Phase 2 succeeded". }
      CreateLauncherShortcuts;
      SaveStringToFile(ExpandConstant('{app}\.install-complete'),
                       'Installed at: ' + GetDateTimeString('yyyy/mm/dd hh:nn:ss', '-', ':') + #13#10, False);
      Log('Wrote .install-complete marker; shortcuts created.');
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

// Sweep a shortcut filename across all candidate locations Windows might
// have placed it. Defensive against two known issues:
//
//   1. PrivilegesRequired=admin: the uninstaller runs elevated. On
//      multi-account machines, the per-user desktop constant can resolve
//      to the elevated account's profile rather than the original
//      interactive user that Phase 2 (Scheduled Task) used to create the
//      .lnk. Without sweeping both per-user and all-users locations, the
//      .lnk would survive.
//
//   2. Historical: an interim build (2026-04-28 morning, fixed same day)
//      passed the long brand through $opts.AppName, producing a long-name
//      .lnk. The uninstaller hard-coded the short-name .lnk, leaving an
//      orphan. We now sweep BOTH the short and long names so customers
//      upgrading from that interim build get their desktop cleaned up too.
//
// Returns the number of .lnk files actually deleted (for log only).
// Block-comment delimiters intentionally avoided here: see line ~175.
function DeleteShortcutEverywhere(LnkName: String): Integer;
var
  Candidates: array of String;
  i: Integer;
  Path: String;
begin
  Result := 0;
  SetArrayLength(Candidates, 4);
  Candidates[0] := ExpandConstant('{userdesktop}')   + '\' + LnkName;
  Candidates[1] := ExpandConstant('{commondesktop}') + '\' + LnkName;
  Candidates[2] := ExpandConstant('{group}')         + '\' + LnkName;
  Candidates[3] := ExpandConstant('{commonprograms}') + '\Phison Hybrid OpenClaw\' + LnkName;
  for i := 0 to GetArrayLength(Candidates) - 1 do
  begin
    Path := Candidates[i];
    if FileExists(Path) then
    begin
      if DeleteFile(Path) then
      begin
        Result := Result + 1;
        Log('Uninstall: removed shortcut ' + Path);
      end
      else
        Log('Uninstall: FAILED to remove shortcut (in use or ACL?) ' + Path);
    end;
  end;
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
      everything under /home/openclaw -- which is the user's workspace.
      The uninstaller already prompts the user that this is irreversible. }
    Exec(ExpandConstant('{cmd}'),
         '/C wsl --unregister phison-hybrid-openclaw',
         AppDir, SW_HIDE, ewWaitUntilTerminated, ResultCode);

    { Tear down a pending Phase 2 resume task if a half-finished install
      left one behind -- otherwise the task would fire after uninstall and
      try to invoke a now-deleted post-install.ps1. }
    Exec(ExpandConstant('{cmd}'),
         '/C schtasks /Delete /TN PhisonHybridOpenClawPhase2Resume /F',
         AppDir, SW_HIDE, ewWaitUntilTerminated, ResultCode);

    { Backwards-compat: also wipe any HKCU RunOnce entry from older
      installer versions that used RunOnce instead of a scheduled task. }
    RegDeleteValue(HKEY_CURRENT_USER,
                   'Software\Microsoft\Windows\CurrentVersion\RunOnce',
                   'PhisonHybridOpenClawPostInstall');

    // Remove launcher shortcuts that were created dynamically by the
    // Pascal Code section / post-install.ps1 (NOT by the Icons section,
    // so Inno Setup does not track them and would leave them orphaned).
    // DeleteShortcutEverywhere also covers stale long-name .lnks from a
    // buggy 2026-04-28 interim build, and is robust against per-user
    // desktop constant mis-resolution under elevated uninstall context.
    DeleteShortcutEverywhere('Phison Hybrid OpenClaw.lnk');
    DeleteShortcutEverywhere('Phison Hybrid Router with aiDAPTIV for OpenClaw.lnk');
    DeleteShortcutEverywhere('aiDAPTIVClaw.lnk');
  end;

  if CurUninstallStep = usPostUninstall then
  begin
    AppDir := ExpandConstant('{app}');
    DistroDir := ExpandConstant('{commonappdata}') + '\Phison Hybrid OpenClaw\wsl';

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
      if MsgBox('Do you want to remove Phison Hybrid Router with aiDAPTIV for OpenClaw configuration files at:' + #13#10 +
                ConfigDir + #13#10 + #13#10 +
                'Workspace data inside the WSL sandbox has already been removed.',
                mbConfirmation, MB_YESNO) = IDYES then
      begin
        DelTree(ConfigDir, True, True, True);
      end;
    end;
  end;
end;
