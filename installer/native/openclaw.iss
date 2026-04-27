; aiDAPTIVClaw Windows Installer - Inno Setup Script (NATIVE flavor, Online Install)
; The installer extracts source code + Node.js, then runs build steps
; on the customer's machine. Native flavor builds OpenClaw on Windows
; directly (no WSL); see installer/wsl/openclaw.iss for the WSL2-sandbox
; flavor that ships in parallel.
;
; Layout (post-2026-04 split):
;   installer/native/  this script + native-only assets (post-install.cmd, etc.)
;   installer/shared/  assets common to both flavors (icon, license, .vbs)
;   installer/wsl/     WSL flavor (separate AppId, can coexist on same box)
;
; Build with: pwsh scripts\build-installer.ps1 -Variant native

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
DefaultDirName={localappdata}\aiDAPTIVClaw
DefaultGroupName=aiDAPTIVClaw
OutputDir=..\output
OutputBaseFilename=aidaptiv-claw-setup-native-{#AppVersion}
Compression=lzma2/ultra64
SolidCompression=yes
PrivilegesRequired=lowest
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
Name: "installdaemon"; Description: "Start gateway automatically on login"; GroupDescription: "Additional options:"; Flags: checkedonce

[Files]
; Source code + Node.js (staged by build-installer-native.ps1 into installer\native\build\)
Source: "build\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
; Shared assets (icons, launcher.vbs) live one level up under installer\shared\
Source: "..\shared\openclaw-launcher.vbs"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\shared\Gemini_Generated_Image_aiDAPTIV.ico"; DestDir: "{app}"; Flags: ignoreversion
; Native-flavor specific files live alongside this .iss
Source: "openclaw-launcher.cmd"; DestDir: "{app}"; Flags: ignoreversion
Source: "post-install.cmd"; DestDir: "{app}"; Flags: ignoreversion
Source: "openclaw-template.json"; DestDir: "{app}"; Flags: ignoreversion
Source: "configure-cloud.cjs"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{userdesktop}\aiDAPTIVClaw"; Filename: "{app}\openclaw-launcher.vbs"; IconFilename: "{app}\Gemini_Generated_Image_aiDAPTIV.ico"; Tasks: desktopicon
Name: "{group}\aiDAPTIVClaw"; Filename: "{app}\openclaw-launcher.vbs"; IconFilename: "{app}\Gemini_Generated_Image_aiDAPTIV.ico"; Tasks: startmenuicon
Name: "{group}\Uninstall aiDAPTIVClaw"; Filename: "{uninstallexe}"; Tasks: startmenuicon

[Run]
; Post-install build and daemon install are handled in [Code] section (CurStepChanged)
; so we can check exit codes and abort on failure.
; Only the optional post-install launch remains here.
Filename: "{app}\openclaw-launcher.vbs"; Description: "Launch aiDAPTIVClaw"; Flags: nowait postinstall skipifsilent shellexec

[UninstallRun]
; Remove daemon scheduled task on uninstall
Filename: "{app}\node.exe"; Parameters: """{app}\openclaw.mjs"" gateway daemon uninstall"; WorkingDir: "{app}"; Flags: waituntilterminated runhidden

[UninstallDelete]
; Remove build artifacts and dependencies not tracked by installer
Type: filesandordirs; Name: "{app}\node_modules"
Type: filesandordirs; Name: "{app}\dist"
Type: filesandordirs; Name: "{app}\.pnpm-store"
Type: files; Name: "{app}\install.log"

[Code]
var
  BuildSucceeded: Boolean;
  CloudPage: TWizardPage;
  ProviderCombo: TNewComboBox;
  ApiKeyEdit: TNewEdit;
  ModelEdit: TNewEdit;

{ --- Provider data helpers --- }

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
  case Idx of
    0: Result := 'google/gemini-2.5-flash';
    1: Result := 'gemini-2.5-flash';
    2: Result := 'claude-sonnet-4-20250514';
    3: Result := 'gpt-4o';
    4: Result := 'meta-llama/Llama-4-Maverick-17B-128E-Instruct-FP8';
  else
    Result := 'google/gemini-2.5-flash';
  end;
end;

{ --- Cloud config page events --- }

procedure ProviderComboChange(Sender: TObject);
begin
  ModelEdit.Text := GetProviderDefaultModel(ProviderCombo.ItemIndex);
end;

{ --- Wizard initialization: create the cloud config page --- }

procedure InitializeWizard;
var
  LblProvider, LblApiKey, LblModel, LblSkip: TNewStaticText;
begin
  CloudPage := CreateCustomPage(wpSelectTasks,
    'Cloud Model Provider',
    'Configure the cloud model provider for hybrid-gateway (optional).');

  LblSkip := TNewStaticText.Create(CloudPage);
  LblSkip.Parent := CloudPage.Surface;
  LblSkip.Caption := 'Leave API Key empty to skip. You can configure this later via the Control UI.';
  LblSkip.Top := 0;
  LblSkip.Left := 0;
  LblSkip.Width := CloudPage.SurfaceWidth;
  LblSkip.AutoSize := True;

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
  ApiKeyEdit.Text := '';

  LblModel := TNewStaticText.Create(CloudPage);
  LblModel.Parent := CloudPage.Surface;
  LblModel.Caption := 'Default Model:';
  LblModel.Top := ScaleY(164);
  LblModel.Left := 0;

  ModelEdit := TNewEdit.Create(CloudPage);
  ModelEdit.Parent := CloudPage.Surface;
  ModelEdit.Top := ScaleY(186);
  ModelEdit.Left := 0;
  ModelEdit.Width := CloudPage.SurfaceWidth;
  ModelEdit.Text := GetProviderDefaultModel(0);
end;

{ --- String replace utility --- }

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

{ --- Write config file from template --- }

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

  if not DirExists(ConfigDir + '\workspace') then
    ForceDirectories(ConfigDir + '\workspace');

  if LoadStringsFromFile(TemplateFile, Lines) then
  begin
    Content := '';
    for I := 0 to GetArrayLength(Lines) - 1 do
    begin
      if I > 0 then
        Content := Content + #13#10;
      Content := Content + Lines[I];
    end;

    Content := ReplaceSubstring(Content, 'C:\\Users\\user\\', ReplaceSubstring(UserProfile, '\', '\\') + '\\');
    Content := ReplaceSubstring(Content, '"lastTouchedVersion": "2026.3.12"', '"lastTouchedVersion": "' + '{#AppVersion}' + '"');
    Content := ReplaceSubstring(Content, '"lastRunVersion": "2026.3.12"', '"lastRunVersion": "' + '{#AppVersion}' + '"');

    SaveStringToFile(ConfigFile, Content, False);
    Log('Config file written: ' + ConfigFile);
  end else
  begin
    Log('Failed to load template: ' + TemplateFile);
  end;
end;

{ --- Post-install build --- }

procedure RunPostInstallBuild;
var
  ResultCode: Integer;
  AppDir, LogFile, CmdExe, Params: String;
  ExecResult: Boolean;
begin
  BuildSucceeded := False;
  AppDir := ExpandConstant('{app}');
  LogFile := AppDir + '\install.log';
  CmdExe := ExpandConstant('{cmd}');

  Params := '/C ""' + AppDir + '\post-install.cmd" "' + AppDir + '" --from-installer"';

  SaveStringToFile(LogFile, '=== Installer [Code] diagnostic ===' + #13#10, False);
  SaveStringToFile(LogFile, 'cmd: ' + CmdExe + #13#10, True);
  SaveStringToFile(LogFile, 'params: ' + Params + #13#10, True);
  SaveStringToFile(LogFile, 'workdir: ' + AppDir + #13#10, True);

  WizardForm.StatusLabel.Caption := 'Building aiDAPTIVClaw (see the console window for progress)...';
  WizardForm.Refresh;

  ExecResult := Exec(CmdExe, Params, AppDir,
                     SW_SHOWNORMAL, ewWaitUntilTerminated, ResultCode);

  SaveStringToFile(LogFile, 'exec_result: ' + IntToStr(Ord(ExecResult)) + ', exit_code: ' + IntToStr(ResultCode) + #13#10, True);

  if ExecResult then
  begin
    if ResultCode = 0 then
    begin
      BuildSucceeded := True;
      Log('Post-install build succeeded');
    end
    else
    begin
      Log('Post-install build failed with exit code: ' + IntToStr(ResultCode));
      MsgBox('Build failed (exit code: ' + IntToStr(ResultCode) + ').' + #13#10 + #13#10 +
             'Check the log file for details:' + #13#10 +
             LogFile + #13#10 + #13#10 +
             'You can retry later by running:' + #13#10 +
             AppDir + '\post-install.cmd "' + AppDir + '"',
             mbError, MB_OK);
    end;
  end
  else
  begin
    Log('Exec() returned False - failed to start cmd.exe');
    SaveStringToFile(LogFile, 'ERROR: Exec() returned False' + #13#10, True);
    MsgBox('Failed to start the build process.' + #13#10 + #13#10 +
           'cmd.exe: ' + CmdExe + #13#10 +
           'params: ' + Params + #13#10 + #13#10 +
           'You can retry manually by running:' + #13#10 +
           AppDir + '\post-install.cmd "' + AppDir + '"',
           mbError, MB_OK);
  end;
end;

{ --- Daemon install --- }

procedure InstallDaemon;
var
  ResultCode: Integer;
begin
  if not BuildSucceeded then
  begin
    Log('Skipping daemon install because build failed');
    Exit;
  end;

  if not WizardIsTaskSelected('installdaemon') then
    Exit;

  WizardForm.StatusLabel.Caption := 'Installing gateway daemon...';

  if Exec(ExpandConstant('{app}\node.exe'),
          ExpandConstant('"{app}\openclaw.mjs" gateway daemon install'),
          ExpandConstant('{app}'),
          SW_SHOW, ewWaitUntilTerminated, ResultCode) then
  begin
    if ResultCode <> 0 then
      Log('Daemon install exited with code: ' + IntToStr(ResultCode));
  end;
end;

{ --- Cloud provider config: read values from GUI, call node non-interactively --- }

procedure ConfigureCloudProvider;
var
  ResultCode: Integer;
  AppDir, NodeExe, ScriptPath, Params, LogFile: String;
  Idx: Integer;
  ApiKey, Model, ProviderId, ProviderBaseUrl, ProviderApi: String;
begin
  AppDir := ExpandConstant('{app}');
  LogFile := AppDir + '\install.log';

  SaveStringToFile(LogFile, '=== ConfigureCloudProvider ===' + #13#10, True);

  ApiKey := Trim(ApiKeyEdit.Text);
  if ApiKey = '' then
  begin
    SaveStringToFile(LogFile, 'SKIP: no API key entered' + #13#10, True);
    Exit;
  end;

  if not BuildSucceeded then
  begin
    SaveStringToFile(LogFile, 'SKIP: BuildSucceeded=False' + #13#10, True);
    Exit;
  end;

  NodeExe := AppDir + '\node.exe';
  ScriptPath := AppDir + '\configure-cloud.cjs';

  if not FileExists(ScriptPath) then
  begin
    SaveStringToFile(LogFile, 'SKIP: configure-cloud.cjs not found' + #13#10, True);
    Exit;
  end;

  Idx := ProviderCombo.ItemIndex;
  ProviderId := GetProviderId(Idx);
  ProviderBaseUrl := GetProviderBaseUrl(Idx);
  ProviderApi := GetProviderApi(Idx);
  Model := Trim(ModelEdit.Text);
  if Model = '' then
    Model := GetProviderDefaultModel(Idx);

  { Pass values as positional args for non-interactive mode }
  Params := '"' + ScriptPath + '" "' + ProviderId + '" "' + ProviderBaseUrl + '" "' + ProviderApi + '" "' + ApiKey + '" "' + Model + '"';

  SaveStringToFile(LogFile, 'cloud_provider: ' + ProviderId + #13#10, True);
  SaveStringToFile(LogFile, 'cloud_model: ' + Model + #13#10, True);

  WizardForm.StatusLabel.Caption := 'Applying cloud provider configuration...';
  WizardForm.Refresh;

  Exec(NodeExe, Params, AppDir, SW_HIDE, ewWaitUntilTerminated, ResultCode);

  SaveStringToFile(LogFile, 'cloud_exit_code: ' + IntToStr(ResultCode) + #13#10, True);
end;

{ --- Wizard step events --- }

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then
  begin
    WriteConfigFile;
    RunPostInstallBuild;
    InstallDaemon;
    ConfigureCloudProvider;
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
        'aiDAPTIVClaw files have been extracted, but the build process failed.' + #13#10 + #13#10 +
        'Check the log file for details:' + #13#10 +
        ExpandConstant('{app}\install.log') + #13#10 + #13#10 +
        'You can retry the build by running:' + #13#10 +
        ExpandConstant('{app}\post-install.cmd "{app}"');
      WizardForm.RunList.Visible := False;
    end;
  end;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  AppDir, ConfigDir: String;
  ResultCode: Integer;
begin
  if CurUninstallStep = usUninstall then
  begin
    AppDir := ExpandConstant('{app}');

    { Remove pnpm global CLI link (best effort) }
    Exec(ExpandConstant('{cmd}'),
         '/C cd /d "' + AppDir + '" && pnpm unlink --global',
         AppDir, SW_HIDE, ewWaitUntilTerminated, ResultCode);
  end;

  if CurUninstallStep = usPostUninstall then
  begin
    AppDir := ExpandConstant('{app}');

    { Remove any remaining files in the app directory }
    if DirExists(AppDir) then
      DelTree(AppDir, True, True, True);

    { Ask about removing config files }
    ConfigDir := ExpandConstant('{%USERPROFILE}') + '\.openclaw';
    if DirExists(ConfigDir) then
    begin
      if MsgBox('Do you want to remove aiDAPTIVClaw configuration and data files?' + #13#10 +
                ConfigDir + #13#10 + #13#10 +
                'Click Yes to remove all settings, or No to keep them for future use.',
                mbConfirmation, MB_YESNO) = IDYES then
      begin
        DelTree(ConfigDir, True, True, True);
      end;
    end;
  end;
end;
