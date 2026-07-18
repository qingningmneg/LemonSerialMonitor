#define ProductName "Lemon串口监控"
#define ProductVersion "0.1.1"
#define ProductAppId "{F5B0783F-74F4-4058-90D1-5A4ACC4254A7}"
#define PayloadRoot "..\artifacts\phase1"

[Setup]
AppId={{F5B0783F-74F4-4058-90D1-5A4ACC4254A7}
AppName=Lemon串口监控
AppVersion={#ProductVersion}
AppVerName={#ProductName} {#ProductVersion}
AppPublisher=qingningmneg
AppPublisherURL=https://github.com/qingningmneg/LemonSerialMonitor
AppSupportURL=https://github.com/qingningmneg/LemonSerialMonitor/issues
AppUpdatesURL=https://github.com/qingningmneg/LemonSerialMonitor/releases
DefaultDirName={autopf}\Lemon串口监控
DisableDirPage=no
UsePreviousAppDir=yes
DefaultGroupName=Lemon串口监控
DisableProgramGroupPage=yes
PrivilegesRequired=admin
PrivilegesRequiredOverridesAllowed=
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.10240
LicenseFile=TEST_CERTIFICATE_AGREEMENT.zh-CN.txt
OutputDir=..\artifacts\installer
OutputBaseFilename=Lemon串口监控-安装程序-x64
UninstallFilesDir={commonappdata}\LemonSerialMonitor\Installer
UninstallDisplayName=Lemon串口监控
UninstallDisplayIcon={app}\app\Lemon.SerialMonitor.exe
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
SetupLogging=yes
CloseApplications=yes
RestartApplications=no
ChangesEnvironment=no
ChangesAssociations=no
DisableWelcomePage=no
DisableReadyPage=no
DisableFinishedPage=no
AllowNoIcons=yes
VersionInfoVersion={#ProductVersion}.0
VersionInfoProductName=Lemon串口监控
VersionInfoProductVersion={#ProductVersion}
VersionInfoDescription=Lemon串口监控安装程序
VersionInfoCompany=qingningmneg
VersionInfoCopyright=Copyright (C) 2026 qingningmneg

[Languages]
Name: "chinesesimplified"; MessagesFile: "third-party\ChineseSimplified.isl"

[Tasks]
Name: "desktopicon"; Description: "创建桌面快捷方式"; GroupDescription: "附加快捷方式："; Flags: unchecked

[Files]
Source: "{#PayloadRoot}\app\*"; DestDir: "LemonPayload\app"; Flags: dontcopy noencryption recursesubdirs createallsubdirs
Source: "{#PayloadRoot}\service\*"; DestDir: "LemonPayload\service"; Flags: dontcopy noencryption recursesubdirs createallsubdirs
Source: "{#PayloadRoot}\ai\*"; DestDir: "LemonPayload\ai"; Flags: dontcopy noencryption recursesubdirs createallsubdirs
Source: "{#PayloadRoot}\helper\*"; DestDir: "LemonPayload\helper"; Flags: dontcopy noencryption recursesubdirs createallsubdirs
Source: "{#PayloadRoot}\driver\*"; DestDir: "LemonPayload\driver"; Flags: dontcopy noencryption recursesubdirs createallsubdirs
Source: "{#PayloadRoot}\scripts\*"; DestDir: "LemonPayload\scripts"; Flags: dontcopy noencryption recursesubdirs createallsubdirs
Source: "{#PayloadRoot}\docs\*"; DestDir: "LemonPayload\docs"; Flags: dontcopy noencryption recursesubdirs createallsubdirs
Source: "{#PayloadRoot}\examples\*"; DestDir: "LemonPayload\examples"; Flags: dontcopy noencryption recursesubdirs createallsubdirs
Source: "{#PayloadRoot}\manual\*"; DestDir: "LemonPayload\manual"; Flags: dontcopy noencryption recursesubdirs createallsubdirs
Source: "{#PayloadRoot}\README.md"; DestDir: "LemonPayload"; Flags: dontcopy noencryption
Source: "{#PayloadRoot}\README.en.md"; DestDir: "LemonPayload"; Flags: dontcopy noencryption
Source: "{#PayloadRoot}\LICENSE"; DestDir: "LemonPayload"; Flags: dontcopy noencryption
Source: "{#PayloadRoot}\SHA256SUMS.txt"; DestDir: "LemonPayload"; Flags: dontcopy noencryption

; These protected copies are tracked by Inno so its own final uninstall removes
; the bootstrap files after the PowerShell transaction has completed.
Source: "{#PayloadRoot}\helper\*"; DestDir: "{commonappdata}\LemonSerialMonitor\Installer\bin"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#PayloadRoot}\scripts\*"; DestDir: "{commonappdata}\LemonSerialMonitor\Installer\scripts"; Flags: ignoreversion recursesubdirs createallsubdirs

[Dirs]
Name: "{commonappdata}\LemonSerialMonitor\Installer\state\results"; Flags: uninsalwaysuninstall

[UninstallDelete]
Type: dirifempty; Name: "{commonappdata}\LemonSerialMonitor\Installer\bin"
Type: dirifempty; Name: "{commonappdata}\LemonSerialMonitor\Installer\scripts"
Type: dirifempty; Name: "{commonappdata}\LemonSerialMonitor\Installer"
Type: dirifempty; Name: "{commonappdata}\LemonSerialMonitor"

[Icons]
Name: "{commondesktop}\Lemon串口监控"; Filename: "{app}\app\Lemon.SerialMonitor.exe"; WorkingDir: "{app}\app"; Tasks: desktopicon; Check: ShouldCreateDesktopIcon
Name: "{commonprograms}\Lemon串口监控 完整操作手册"; Filename: "{app}\manual\Lemon串口监控-完整操作手册.pdf"; WorkingDir: "{app}\manual"; Check: ShouldCreateManualShortcut

[Code]
const
  InstallerRoot = '{commonappdata}\LemonSerialMonitor\Installer';
  TaskEnumHidden = 1;

var
  PayloadExtracted: Boolean;
  SystemInstallCompleted: Boolean;
  SetupFullyCompleted: Boolean;
  RestartAfterInstall: Boolean;
  InstalledId: String;
  AuthorizedUserSid: String;
  InstallMode: String;
  UninstallId: String;
  ResumeUninstall: Boolean;
  UninstallTransactionStarted: Boolean;
  UninstallRestartRequired: Boolean;

procedure ExitProcess(uExitCode: Integer);
  external 'ExitProcess@kernel32.dll stdcall';

function QuoteArgument(const Value: String): String;
begin
  Result := '"' + Value + '"';
end;

function PowerShellPath: String;
begin
  Result := ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe');
end;

function PayloadPath: String;
begin
  Result := ExpandConstant('{tmp}\LemonPayload');
end;

function ProtectedInstallerPath(const RelativePath: String): String;
begin
  Result := ExpandConstant(InstallerRoot + '\' + RelativePath);
end;

function LoadTextFile(const FileName: String; var Value: String): Boolean;
var
  Bytes: AnsiString;
begin
  Result := LoadStringFromFile(FileName, Bytes);
  if Result then
    Value := String(Bytes)
  else
    Value := '';
end;

function IsJsonSpace(Value: Char): Boolean;
begin
  Result := (Value = ' ') or (Value = #9) or
    (Value = #10) or (Value = #13);
end;

function JsonStringValue(const Json, PropertyName: String): String;
var
  KeyText: String;
  KeyPosition: Integer;
  Cursor: Integer;
  ValueStart: Integer;
begin
  Result := '';
  KeyText := '"' + PropertyName + '"';
  KeyPosition := Pos(KeyText, Json);
  if KeyPosition = 0 then
    Exit;

  Cursor := KeyPosition + Length(KeyText);
  while (Cursor <= Length(Json)) and IsJsonSpace(Json[Cursor]) do
    Cursor := Cursor + 1;
  if (Cursor > Length(Json)) or (Json[Cursor] <> ':') then
    Exit;
  Cursor := Cursor + 1;
  while (Cursor <= Length(Json)) and IsJsonSpace(Json[Cursor]) do
    Cursor := Cursor + 1;
  if (Cursor > Length(Json)) or (Json[Cursor] <> '"') then
    Exit;
  Cursor := Cursor + 1;
  ValueStart := Cursor;
  while (Cursor <= Length(Json)) and (Json[Cursor] <> '"') do
    Cursor := Cursor + 1;
  if Cursor > Length(Json) then
    Exit;
  Result := Copy(Json, ValueStart, Cursor - ValueStart);
end;

function IsCanonicalUserSid(const Value: String): Boolean;
var
  Index: Integer;
begin
  Result := False;
  if Pos('S-1-5-21-', Value) <> 1 then
    Exit;
  if Length(Value) < 20 then
    Exit;
  for Index := 10 to Length(Value) do
    if not (((Value[Index] >= '0') and (Value[Index] <= '9')) or
      (Value[Index] = '-')) then
      Exit;
  Result := True;
end;

function ExecutePowerShellFile(const ScriptPath, Arguments: String;
  var ResultCode: Integer): Boolean;
var
  Parameters: String;
begin
  Parameters := '-NoLogo -NoProfile -NonInteractive ' +
    '-ExecutionPolicy Bypass -File ' + QuoteArgument(ScriptPath);
  if Arguments <> '' then
    Parameters := Parameters + ' ' + Arguments;
  Log('Executing protected PowerShell file entrypoint: ' + ScriptPath);
  Result := Exec(PowerShellPath, Parameters, '', SW_HIDE,
    ewWaitUntilTerminated, ResultCode);
end;

function ResolveAuthorizedUser(var ErrorText: String): Boolean;
var
  ResultCode: Integer;
  SidPath: String;
  ResolverPath: String;
  Arguments: String;
begin
  Result := False;
  ErrorText := '';
  SidPath := ExpandConstant('{tmp}\lemon-authorized-user.sid');
  ResolverPath := PayloadPath + '\scripts\Resolve-LemonInteractiveUserSid.ps1';
  Arguments := '-AccountName ' + QuoteArgument(GetUserNameString) +
    ' -ResultPath ' + QuoteArgument(SidPath);
  if not ExecutePowerShellFile(ResolverPath, Arguments, ResultCode) then
  begin
    ErrorText := '无法启动 Windows 用户身份检查。错误代码：' +
      IntToStr(ResultCode);
    Exit;
  end;
  if ResultCode <> 0 then
  begin
    ErrorText := '无法确定要授权使用本机 AI 接口的 Windows 用户。';
    Exit;
  end;
  if not LoadTextFile(SidPath, AuthorizedUserSid) then
  begin
    ErrorText := 'Windows 用户身份检查没有生成结果。';
    Exit;
  end;
  AuthorizedUserSid := Trim(AuthorizedUserSid);
  if not IsCanonicalUserSid(AuthorizedUserSid) then
  begin
    ErrorText := 'Windows 用户身份检查返回了无效的 SID。';
    Exit;
  end;
  Result := True;
end;

function DetectInstallMode: String;
var
  LegacyMarkerPath: String;
  ProtectedStatePath: String;
begin
  ProtectedStatePath := ExpandConstant(
    '{commonappdata}\LemonSerialMonitor\Installer\state\install-state.v1.json');
  LegacyMarkerPath := ExpandConstant(
    '{autopf}\CommMonitor\.commmonitor-install.json');
  if FileExists(ProtectedStatePath) then
    Result := 'Fresh'
  else if FileExists(LegacyMarkerPath) then
    Result := 'Migrate'
  else
    Result := 'Fresh';
end;

function RunInstallTransaction(var NeedsRestart: Boolean;
  var ErrorText: String): Boolean;
var
  ResultCode: Integer;
  ResultPath: String;
  ResultJson: String;
  TransactionMessage: String;
  ScriptPath: String;
  Arguments: String;
begin
  Result := False;
  ErrorText := '';
  ResultPath := ExpandConstant('{tmp}\lemon-install-result.json');
  ScriptPath := PayloadPath + '\scripts\Install-CommMonitor.ps1';
  InstallMode := DetectInstallMode;
  Arguments := '-PackageRoot ' + QuoteArgument(PayloadPath) +
    ' -AppRoot ' + QuoteArgument(WizardDirValue) +
    ' -AuthorizedUserSid ' + QuoteArgument(AuthorizedUserSid) +
    ' -ResultPath ' + QuoteArgument(ResultPath) +
    ' -Mode ' + InstallMode + ' -AcceptTestCertificate';

  if FileExists(ResultPath) and (not DeleteFile(ResultPath)) then
  begin
    ErrorText := '无法清理上一次安装事务的结果文件。请关闭安装程序后重试。';
    Exit;
  end;

  if not ExecutePowerShellFile(ScriptPath, Arguments, ResultCode) then
  begin
    ErrorText := '无法启动安装事务。错误代码：' + IntToStr(ResultCode);
    Exit;
  end;
  if not LoadTextFile(ResultPath, ResultJson) then
  begin
    if (ResultCode <> 0) and (ResultCode <> 3010) then
      ErrorText := '底层安装事务失败。请查看安装日志后重试。'
    else
      ErrorText := '安装事务没有生成可验证的结果文件。';
    Exit;
  end;
  if (ResultCode <> 0) and (ResultCode <> 3010) then
  begin
    TransactionMessage := JsonStringValue(ResultJson, 'Message');
    if TransactionMessage <> '' then
      ErrorText := '底层安装事务失败：' + TransactionMessage
    else
      ErrorText := '底层安装事务失败。请查看安装日志后重试。';
    Exit;
  end;

  SystemInstallCompleted := True;
  InstalledId := JsonStringValue(ResultJson, 'InstallId');
  if InstalledId = '' then
  begin
    ErrorText := '安装事务结果缺少安装标识。';
    Exit;
  end;

  RestartAfterInstall := ResultCode = 3010;
  NeedsRestart := RestartAfterInstall;
  Result := True;
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  ExtractedCount: Integer;
  ErrorText: String;
begin
  Result := '';
  NeedsRestart := False;
  try
    if not PayloadExtracted then
    begin
      ExtractedCount := ExtractTemporaryFiles('LemonPayload\*');
      if ExtractedCount < 1 then
      begin
        Result := '安装包载荷为空，无法继续。';
        Exit;
      end;
      PayloadExtracted := True;
    end;

    if not ResolveAuthorizedUser(ErrorText) then
    begin
      Result := ErrorText;
      Exit;
    end;
    if not RunInstallTransaction(NeedsRestart, ErrorText) then
    begin
      Result := ErrorText;
      Exit;
    end;
  except
    Result := '准备安装时发生错误：' + GetExceptionMessage;
  end;
end;

function NeedRestart: Boolean;
begin
  Result := RestartAfterInstall;
end;

function ShouldCreateDesktopIcon: Boolean;
begin
  Result := FileExists(ExpandConstant('{app}\app\Lemon.SerialMonitor.exe'));
end;

function ShouldCreateManualShortcut: Boolean;
begin
  Result := FileExists(ExpandConstant(
    '{app}\manual\Lemon串口监控-完整操作手册.pdf'));
end;

function UpdateReadyMemo(Space, NewLine, MemoUserInfoInfo, MemoDirInfo,
  MemoTypeInfo, MemoComponentsInfo, MemoGroupInfo, MemoTasksInfo: String): String;
begin
  Result := MemoDirInfo + NewLine + NewLine +
    '授权用户：' + GetUserNameString + NewLine +
    '安装模式：' + DetectInstallMode + NewLine +
    '驱动签名：安装本地测试证书，并在需要时启用 TESTSIGNING' +
    NewLine + NewLine + MemoTasksInfo;
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssDone then
    SetupFullyCompleted := True;
end;

procedure RollBackSystemInstall;
var
  ResultCode: Integer;
  ScriptPath: String;
  ResultPath: String;
  Arguments: String;
begin
  if (not SystemInstallCompleted) or (InstalledId = '') then
    Exit;
  ScriptPath := PayloadPath + '\scripts\Uninstall-CommMonitor.ps1';
  ResultPath := ExpandConstant('{tmp}\lemon-install-rollback.json');
  Arguments := '-InstallId ' + QuoteArgument(InstalledId) +
    ' -ResultPath ' + QuoteArgument(ResultPath);
  if not ExecutePowerShellFile(ScriptPath, Arguments, ResultCode) then
    Log('Unable to start setup rollback, error ' + IntToStr(ResultCode))
  else
    Log('Setup rollback returned ' + IntToStr(ResultCode));
end;

procedure DeinitializeSetup;
begin
  if SystemInstallCompleted and (not SetupFullyCompleted) then
    RollBackSystemInstall;
end;

function CommandLineValue(const Name: String): String;
var
  Index: Integer;
  Prefix: String;
begin
  Result := '';
  Prefix := '/' + Name + '=';
  for Index := 1 to ParamCount do
    if CompareText(Copy(ParamStr(Index), 1, Length(Prefix)), Prefix) = 0 then
    begin
      Result := Copy(ParamStr(Index), Length(Prefix) + 1,
        Length(ParamStr(Index)) - Length(Prefix));
      Exit;
    end;
end;

function LoadProtectedInstallId(var Value: String): Boolean;
var
  StateJson: String;
begin
  Result := LoadTextFile(
    ProtectedInstallerPath('state\install-state.v1.json'), StateJson);
  if Result then
  begin
    Value := JsonStringValue(StateJson, 'InstallId');
    Result := Value <> '';
  end;
end;

function UninstallTaskName: String;
begin
  Result := 'LemonSerialMonitor\Finalize-' + UninstallId;
end;

function ScheduleUninstallContinuation: Boolean;
var
  ResultCode: Integer;
  TaskAction: String;
  Parameters: String;
begin
  TaskAction := '\"' + ExpandConstant('{uninstallexe}') + '\" ' +
    '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /resume=' + UninstallId;
  Parameters := '/Create /TN ' + QuoteArgument(UninstallTaskName) +
    ' /SC ONSTART /RU SYSTEM /RL HIGHEST /TR ' +
    QuoteArgument(TaskAction) + ' /F';
  Result := Exec(ExpandConstant('{sys}\schtasks.exe'), Parameters, '',
    SW_HIDE, ewWaitUntilTerminated, ResultCode) and (ResultCode = 0);
end;

procedure DeleteUninstallContinuation;
var
  ResultCode: Integer;
  Parameters: String;
begin
  Parameters := '/Delete /TN ' + QuoteArgument(UninstallTaskName) + ' /F';
  if Exec(ExpandConstant('{sys}\schtasks.exe'), Parameters, '', SW_HIDE,
    ewWaitUntilTerminated, ResultCode) then
    Log('Continuation task delete returned ' + IntToStr(ResultCode));
end;

function DeleteEmptyUninstallTaskFolder: Boolean;
var
  TaskService: Variant;
  RootFolder: Variant;
  RootFolders: Variant;
  ProductFolder: Variant;
  FolderTasks: Variant;
  FolderChildren: Variant;
  Index: Integer;
begin
  Result := False;
  try
    TaskService := CreateOleObject('Schedule.Service');
    TaskService.Connect;
    RootFolder := TaskService.GetFolder('\');
    RootFolders := RootFolder.GetFolders(0);
    for Index := 1 to RootFolders.Count do
    begin
      ProductFolder := RootFolders.Item(Index);
      if CompareText(ProductFolder.Name, 'LemonSerialMonitor') = 0 then
      begin
        FolderTasks := ProductFolder.GetTasks(TaskEnumHidden);
        FolderChildren := ProductFolder.GetFolders(0);
        if (FolderTasks.Count = 0) and (FolderChildren.Count = 0) then
        begin
          RootFolder.DeleteFolder('LemonSerialMonitor', 0);
          Result := True;
        end
        else
          Log('The uninstall task folder is not empty and was preserved.');
        Exit;
      end;
    end;
    Result := True;
  except
    Log('Unable to verify the empty uninstall task folder: ' +
      GetExceptionMessage);
  end;
end;

function InitializeUninstall: Boolean;
var
  ResumeId: String;
begin
  Result := False;
  if not LoadProtectedInstallId(UninstallId) then
  begin
    MsgBox('受保护的安装记录不存在或无法读取，卸载已停止。',
      mbError, MB_OK);
    Exit;
  end;

  ResumeId := CommandLineValue('resume');
  ResumeUninstall := ResumeId <> '';
  if ResumeUninstall then
  begin
    if CompareText(ResumeId, UninstallId) <> 0 then
      Exit;
    Result := True;
    Exit;
  end;

  Result := MsgBox(
    '警告：完整卸载会永久删除 Lemon串口监控 的全部会话数据、' +
    '导出文件、设置、日志和 AI 状态，同时删除本软件的服务、驱动和证书。' +
    Chr(13) + Chr(10) + Chr(13) + Chr(10) +
    '该操作不可恢复。确定继续吗？',
    mbError, MB_YESNO) = IDYES;
end;

procedure DeleteFinalProtectedState(const ResultPath: String);
var
  CompletionPath: String;
begin
  CompletionPath := ProtectedInstallerPath(
    'state\results\' + UninstallId + '.completion.v1.json');
  DeleteFile(ResultPath);
  DeleteFile(CompletionPath);
  DeleteFile(ProtectedInstallerPath('state\uninstall-work.v1.json'));
  DeleteFile(ProtectedInstallerPath('state\install-state.v1.json'));
  RemoveDir(ProtectedInstallerPath('state\results'));
  RemoveDir(ProtectedInstallerPath('state'));
end;

procedure RunUninstallTransaction;
var
  ResultCode: Integer;
  ResultPath: String;
  ResultJson: String;
  ResultStatus: String;
  ScriptPath: String;
  Arguments: String;
begin
  ResultPath := ProtectedInstallerPath(
    'state\results\' + UninstallId + '.inno-uninstall.v1.json');
  ScriptPath := ProtectedInstallerPath('scripts\Uninstall-CommMonitor.ps1');
  Arguments := '-InstallId ' + QuoteArgument(UninstallId) +
    ' -ResultPath ' + QuoteArgument(ResultPath);
  if ResumeUninstall then
    Arguments := Arguments + ' -Resume';

  if not ExecutePowerShellFile(ScriptPath, Arguments, ResultCode) then
    RaiseException('无法启动完整卸载事务。错误代码：' +
      IntToStr(ResultCode));

  if not LoadTextFile(ResultPath, ResultJson) then
    RaiseException('完整卸载事务没有生成可验证的结果文件。');
  ResultStatus := JsonStringValue(ResultJson, 'Status');

  if ResultCode = 3010 then
  begin
    if ResultStatus <> 'PendingReboot' then
      RaiseException('卸载退出状态与结果文件不一致。');
    UninstallRestartRequired := True;
    if not ScheduleUninstallContinuation then
      RaiseException('卸载需要重启，但无法创建安全的重启续办任务。');
    if not UninstallSilent then
      MsgBox('Windows 正在完成驱动或设备栈的安全清理。请重新启动计算机，卸载会自动继续。',
        mbInformation, MB_OK);
    ExitProcess(3010);
  end;
  if ResultCode <> 0 then
    RaiseException('完整卸载失败。请保留安装目录并查看卸载日志。');
  if ResultStatus <> 'Completed' then
    RaiseException('卸载完成状态与结果文件不一致。');

  DeleteUninstallContinuation;
  if not DeleteEmptyUninstallTaskFolder then
    RaiseException(
      'Unable to remove the empty uninstall continuation task folder safely.');
  DeleteFinalProtectedState(ResultPath);
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if (CurUninstallStep = usUninstall) and
    (not UninstallTransactionStarted) then
  begin
    UninstallTransactionStarted := True;
    RunUninstallTransaction;
  end;
end;

function UninstallNeedRestart: Boolean;
begin
  Result := UninstallRestartRequired;
end;
