; AppVersion / AppArch / StageDir / OutputDir 由 build-windows.ps1 传入

#ifndef AppVersion
  #define AppVersion "1.0.1"
#endif
#ifndef AppArch
  #define AppArch "x64"
#endif
#ifndef StageDir
  #define StageDir "..\..\build\windows\x64"
#endif
#ifndef OutputDir
  #define OutputDir "..\..\build\installer"
#endif

#define AppName "ECY Cloud"
#define AppExeName "ECYCloud.exe"
#define ServiceExeName "ecycloud-service.exe"
#define IconFile "..\..\app\windows\runner\resources\app_icon.ico"

[Setup]
AppId={{8F3C4A21-7B65-4D0E-9C2A-1E6B5D4F3A80}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher=ECY Cloud
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
UninstallDisplayName={#AppName}
; 运行中的 GUI 占着 exe 与 dll，安装与卸载都得先让它退出。认客户端的单实例互斥体
; （app/windows/runner/main.cpp 的 kInstanceMutexName）而不是窗口标题：标题带版本号，
; 装新版时匹配不到旧版窗口
AppMutex=Local\ECYCloud.SingleInstance
UninstallDisplayIcon={app}\{#AppExeName}
OutputDir={#OutputDir}
OutputBaseFilename=ECYCloud-{#AppVersion}-windows-{#AppArch}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
SetupIconFile={#IconFile}
; 逗号分隔的多尺寸供 Inno 按显示缩放挑选，缺档位会被拉伸糊掉
WizardSmallImageFile=wizard\shield-55.bmp,wizard\shield-83.bmp,wizard\shield-110.bmp,wizard\shield-138.bmp,wizard\shield-165.bmp,wizard\shield-192.bmp
; 注册系统服务必须提权；安装与卸载各弹一次
PrivilegesRequired=admin
; Windows 10 1809 是最低支持版本
MinVersion=10.0.17763
#if AppArch == "arm64"
ArchitecturesAllowed=arm64
ArchitecturesInstallIn64BitMode=arm64
#else
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
#endif
LicenseFile={#StageDir}\LICENSE.txt

[Languages]
; Inno Setup 6 未随包分发简体中文，语言文件随仓库落地，不依赖构建机安装了哪些语言
Name: "chinese"; MessagesFile: "lang\ChineseSimplified.isl"

[Messages]
; 只有 CloseRunningApp 连强杀都没关掉客户端时才会看到；关窗口只是缩到托盘，必须点明从托盘退出
SetupAppRunningError=%1 正在运行。请在系统托盘图标上右键选择「退出」，然后单击「确定」继续，或单击「取消」退出安装程序。
UninstallAppRunningError=%1 正在运行。请在系统托盘图标上右键选择「退出」，然后单击「确定」继续，或单击「取消」退出卸载程序。

[LangOptions]
; 语言文件本身不指定字体，默认会退到 Tahoma 再逐字回退，中文字形发虚
DialogFontName=Microsoft YaHei UI
DialogFontSize=9
WelcomeFontName=Microsoft YaHei UI
WelcomeFontSize=12

[Files]
Source: "{#StageDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\{#AppExeName}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExeName}"; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "创建桌面快捷方式"; GroupDescription: "附加任务:"

[Run]
Filename: "{app}\service\{#ServiceExeName}"; Parameters: "install"; StatusMsg: "正在注册后台服务..."; Flags: runhidden waituntilterminated
Filename: "{app}\{#AppExeName}"; Description: "立即运行 {#AppName}"; Flags: nowait postinstall skipifsilent

[UninstallRun]
; 服务停止时会还原系统代理并清理 TUN 网卡，必须等它执行完再删文件
Filename: "{app}\service\{#ServiceExeName}"; Parameters: "uninstall"; RunOnceId: "RemoveService"; Flags: runhidden waituntilterminated

[Code]
const
  MB_TOPMOST = $00040000;
  HWND_TOPMOST = -1;
  HWND_NOTOPMOST = -2;
  SWP_NOSIZE = $0001;
  SWP_NOMOVE = $0002;
  UninstallRegKey = 'Software\Microsoft\Windows\CurrentVersion\Uninstall\{8F3C4A21-7B65-4D0E-9C2A-1E6B5D4F3A80}_is1';

function SetWindowPos(Wnd, WndInsertAfter, X, Y, cx, cy, Flags: Integer): Boolean;
  external 'SetWindowPos@user32.dll stdcall';
function SetForegroundWindow(Wnd: Integer): Boolean;
  external 'SetForegroundWindow@user32.dll stdcall';
function RegisterWindowMessage(Name: String): Cardinal;
  external 'RegisterWindowMessageW@user32.dll stdcall';

var
  WizardFronted: Boolean;
  RemoveUserData: Boolean;

// 客户端占着 exe 与 dll。广播客户端注册的退出消息（摘掉托盘后自行退出），旧版本不认则超时强杀。
// 等的是互斥体而不是进程：Inno 后面的检查同样只看互斥体
procedure CloseRunningApp;
var
  Waited, ResultCode: Integer;
begin
  if not CheckForMutexes('{#SetupSetting("AppMutex")}') then
    Exit;

  PostBroadcastMessage(RegisterWindowMessage('ECYCloud.Quit'), 0, 0);
  Waited := 0;
  while (Waited < 5000) and CheckForMutexes('{#SetupSetting("AppMutex")}') do
  begin
    Sleep(200);
    Waited := Waited + 200;
  end;
  if not CheckForMutexes('{#SetupSetting("AppMutex")}') then
    Exit;

  Exec(ExpandConstant('{sys}\taskkill.exe'), '/F /IM {#AppExeName}', '', SW_HIDE,
    ewWaitUntilTerminated, ResultCode);
  Waited := 0;
  while (Waited < 3000) and CheckForMutexes('{#SetupSetting("AppMutex")}') do
  begin
    Sleep(200);
    Waited := Waited + 200;
  end;
end;

// 安装侧的互斥体检查紧跟在 InitializeSetup 之后、向导显示之前，只能在这里关
function InitializeSetup(): Boolean;
begin
  if CheckForMutexes('{#SetupSetting("AppMutex")}') and not WizardSilent then
  begin
    if MsgBox(
      '{#AppName} 正在运行。' + #13#10#13#10 +
      '点击「确定」关闭客户端并继续安装，或点击「取消」退出安装程序。',
      mbConfirmation, MB_OKCANCEL or MB_TOPMOST) <> IDOK then
    begin
      Result := False;
      Exit;
    end;
  end;
  CloseRunningApp;
  Result := True;
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  UninstallCmd: String;
begin
  if CurStep = ssPostInstall then
  begin
    // 设置里的「卸载」走 QuietUninstallString；只改 UninstallString 仍会弹 ConfirmUninstall
    UninstallCmd := '"' + ExpandConstant('{uninstallexe}') + '" /SILENT /SUPPRESSMSGBOXES';
    RegWriteStringValue(HKLM64, UninstallRegKey, 'UninstallString', UninstallCmd);
    RegWriteStringValue(HKLM64, UninstallRegKey, 'QuietUninstallString', UninstallCmd);
  end;
end;

// 提权后前台权归 UAC 发起方，向导窗口会开在其它窗口之下；
// 只能自己置顶再取消置顶把它抬到最上层，SetForegroundWindow 单独调用会被系统降级。
procedure CurPageChanged(CurPageID: Integer);
begin
  if WizardFronted then
    Exit;
  WizardFronted := True;
  SetWindowPos(WizardForm.Handle, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE or SWP_NOSIZE);
  SetWindowPos(WizardForm.Handle, HWND_NOTOPMOST, 0, 0, 0, 0, SWP_NOMOVE or SWP_NOSIZE);
  SetForegroundWindow(WizardForm.Handle);
end;

// 覆盖安装时旧服务还占着 ecycloud-service.exe 与内核，且 install 子命令
// 遇到已注册的服务会直接报错，必须先让旧版自己注销：它会停内核并还原系统代理。
// 未注册时 uninstall 会返回非零，忽略即可
function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  Service: String;
  Code: Integer;
begin
  Result := '';
  Service := ExpandConstant('{app}\service\{#ServiceExeName}');
  if FileExists(Service) then
    Exec(Service, 'uninstall', '', SW_HIDE, ewWaitUntilTerminated, Code);
end;

function HasUninstallParam(const Name: String): Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 1 to ParamCount do
    if CompareText(ParamStr(I), Name) = 0 then
    begin
      Result := True;
      Exit;
    end;
end;

// 卸载器没有向导页，只能自己拼一个窗体来问是否连数据一起删。
// 默认不勾：重装后用户还能保留登录状态、节点选择与内核缓存。
// ConfirmUninstall 只在非 Silent 时出现；设置常丢掉 /SILENT，所以点「开始卸载」后
// 若当前不是 Silent，先退出释放 unins000.dat 独占锁，再延迟以 Silent 重入完成卸载。
function InitializeUninstall(): Boolean;
var
  Form: TSetupForm;
  Prompt, Detail: TNewStaticText;
  DataCheck: TNewCheckBox;
  OkButton, CancelButton: TNewButton;
  ButtonWidth, ResultCode: Integer;
  Params: String;
begin
  if UninstallSilent and HasUninstallParam('/ECYCFM') then
  begin
    RemoveUserData := HasUninstallParam('/ECYDATA');
    Result := True;
    Exit;
  end;

  RemoveUserData := False;

  // 6.6.0 起窗体尺寸只能在构造时给，之后是只读属性。这两个值必须是未缩放的原始尺寸：
  // CreateCustomForm 内部的 InitializeFont 会按对话框字体与系统 DPI 再缩放一次，
  // 传 ScaleX / ScaleY 的结果会被平方放大（200% 缩放下宽度从 1117 涨到 2281 像素）
  Form := CreateCustomForm(440, 165, False, True);
  try
    Form.Caption := '卸载 {#AppName}';

    Prompt := TNewStaticText.Create(Form);
    Prompt.Parent := Form;
    Prompt.Left := ScaleX(16);
    Prompt.Top := ScaleY(16);
    Prompt.Width := Form.ClientWidth - ScaleX(32);
    Prompt.WordWrap := True;
    Prompt.AutoSize := True;
    Prompt.Caption := '即将卸载 {#AppName}，后台服务会一并注销，系统代理与 TUN 网卡会自动还原。';

    DataCheck := TNewCheckBox.Create(Form);
    DataCheck.Parent := Form;
    DataCheck.Left := ScaleX(16);
    DataCheck.Top := Prompt.Top + Prompt.Height + ScaleY(14);
    DataCheck.Width := Form.ClientWidth - ScaleX(32);
    DataCheck.Height := ScaleY(20);
    DataCheck.Checked := False;
    DataCheck.Caption := '删除应用数据';

    Detail := TNewStaticText.Create(Form);
    Detail.Parent := Form;
    Detail.Left := DataCheck.Left + ScaleX(18);
    Detail.Top := DataCheck.Top + DataCheck.Height + ScaleY(2);
    Detail.Width := Form.ClientWidth - Detail.Left - ScaleX(16);
    Detail.WordWrap := True;
    Detail.AutoSize := True;
    Detail.Caption := '含登录凭据、偏好设置、日志与内核缓存，删除后不可恢复；不勾选则全部保留，重装后可直接继续使用。';

    OkButton := TNewButton.Create(Form);
    OkButton.Parent := Form;
    OkButton.Height := ScaleY(26);
    OkButton.Top := Form.ClientHeight - ScaleY(16) - OkButton.Height;
    OkButton.Caption := '开始卸载';
    OkButton.ModalResult := mrOk;
    OkButton.Default := True;

    CancelButton := TNewButton.Create(Form);
    CancelButton.Parent := Form;
    CancelButton.Height := OkButton.Height;
    CancelButton.Top := OkButton.Top;
    CancelButton.Caption := '取消';
    CancelButton.ModalResult := mrCancel;
    CancelButton.Cancel := True;

    ButtonWidth := Form.CalculateButtonWidth([OkButton.Caption, CancelButton.Caption]);
    OkButton.Width := ButtonWidth;
    CancelButton.Width := ButtonWidth;
    CancelButton.Left := Form.ClientWidth - ScaleX(16) - ButtonWidth;
    OkButton.Left := CancelButton.Left - ScaleX(8) - ButtonWidth;

    Result := Form.ShowModal() = mrOk;
    RemoveUserData := Result and DataCheck.Checked;
  finally
    Form.Free();
  end;

  if not Result then
    Exit;

  // 已带 /SILENT：点「开始卸载」后直接卸，不会再出 ConfirmUninstall
  if UninstallSilent then
    Exit;

  Params := '/SILENT /SUPPRESSMSGBOXES /ECYCFM';
  if RemoveUserData then
    Params := Params + ' /ECYDATA';
  // timeout 让本实例先 Abort 并释放 .dat，避免重入抢锁失败
  Exec(ExpandConstant('{sys}\cmd.exe'),
    '/c timeout /t 1 /nobreak >nul & start "" "' + ExpandConstant('{uninstallexe}') + '" ' + Params,
    '', SW_HIDE, ewNoWait, ResultCode);
  Result := False;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  // 客户端要赶在 Inno 检查互斥体之前关掉，否则会弹那句「请从托盘退出」
  if CurUninstallStep = usAppMutexCheck then
  begin
    CloseRunningApp;
    Exit;
  end;

  if CurUninstallStep = usPostUninstall then
  begin
    // cache.db 与日志在服务停下前还被占用
    if RemoveUserData then
    begin
      DelTree(ExpandConstant('{commonappdata}\ECYCloud'), True, True, True);
      DelTree(ExpandConstant('{userappdata}\ECYCloud'), True, True, True);
    end;
    Exit;
  end;

  if (CurUninstallStep = usDone) and UninstallSilent then
    MsgBox('{#AppName} 卸载完成。', mbInformation, MB_OK or MB_TOPMOST);
end;
