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
PrivilegesRequired=admin
MinVersion=10.0.17763
; esigner 与 build-windows.ps1 传入的 /Sesigner 同名；重试由 sign-windows.ps1 负责，这里不再叠加
#ifdef SignInstaller
SignTool=esigner
SignedUninstaller=yes
SignToolRetryCount=0
#endif
#if AppArch == "arm64"
ArchitecturesAllowed=arm64
ArchitecturesInstallIn64BitMode=arm64
#else
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
#endif
[Languages]
; Inno Setup 6 未随包分发简体/繁体中文，语言文件随仓库落地，不依赖构建机安装了哪些语言
; 许可协议按安装语言切换；中文为 FSF 认可链路上的非官方译本，英文原文仍有法律效力
Name: "english"; MessagesFile: "compiler:Default.isl"; LicenseFile: "{#StageDir}\LICENSE.txt"
Name: "chinese"; MessagesFile: "lang\ChineseSimplified.isl"; LicenseFile: "lang\LICENSE.zh-CN.txt"
Name: "chinesetraditional"; MessagesFile: "lang\ChineseTraditional.isl"; LicenseFile: "lang\LICENSE.zh-TW.txt"

[LangOptions]
chinese.DialogFontName=Microsoft YaHei UI
chinesetraditional.DialogFontName=Microsoft JhengHei UI

[Messages]
; 只有 CloseRunningApp 连强杀都没关掉客户端时才会看到；关窗口只是缩到托盘，必须点明从托盘退出
chinese.SetupAppRunningError=%1 正在运行。请在系统托盘图标上右键选择「退出」，然后单击「确定」继续，或单击「取消」退出安装程序。
chinese.UninstallAppRunningError=%1 正在运行。请在系统托盘图标上右键选择「退出」，然后单击「确定」继续，或单击「取消」退出卸载程序。
chinesetraditional.SetupAppRunningError=%1 正在執行。請在系統匣圖示上按右鍵選擇「結束」，然後按「確定」繼續，或按「取消」結束安裝程式。
chinesetraditional.UninstallAppRunningError=%1 正在執行。請在系統匣圖示上按右鍵選擇「結束」，然後按「確定」繼續，或按「取消」結束解除安裝程式。
english.SetupAppRunningError=%1 is running. Right-click the tray icon and choose Quit, then click OK to continue or Cancel to exit Setup.
english.UninstallAppRunningError=%1 is running. Right-click the tray icon and choose Quit, then click OK to continue or Cancel to exit Uninstall.

[CustomMessages]
chinese.CloseRunningPrompt=%1 正在运行。%n%n点击「确定」关闭客户端并继续安装，或点击「取消」退出安装程序。
chinesetraditional.CloseRunningPrompt=%1 正在執行。%n%n按「確定」關閉用戶端並繼續安裝，或按「取消」結束安裝程式。
english.CloseRunningPrompt=%1 is running.%n%nClick OK to close the app and continue, or Cancel to exit Setup.
chinese.UninstallCaption=卸载 %1
chinesetraditional.UninstallCaption=解除安裝 %1
english.UninstallCaption=Uninstall %1
chinese.UninstallPrompt=即将卸载 %1，后台服务会一并注销，系统代理与 TUN 网卡会自动还原。
chinesetraditional.UninstallPrompt=即將解除安裝 %1，背景服務會一併註銷，系統代理與 TUN 網路介面卡會自動還原。
english.UninstallPrompt=%1 will be uninstalled. The background service will be removed, and the system proxy and TUN adapter will be restored.
chinese.RemoveUserData=删除应用数据
chinesetraditional.RemoveUserData=刪除應用程式資料
english.RemoveUserData=Delete application data
chinese.RemoveUserDataDetail=含登录凭据、偏好设置、日志与内核缓存，删除后不可恢复；不勾选则全部保留，重装后可直接继续使用。
chinesetraditional.RemoveUserDataDetail=含登入憑證、偏好設定、記錄與核心快取，刪除後無法復原；不勾選則全部保留，重裝後可直接繼續使用。
english.RemoveUserDataDetail=Includes sign-in credentials, preferences, logs, and kernel cache. This cannot be undone. Leave unchecked to keep them for the next install.
chinese.StartUninstall=开始卸载
chinesetraditional.StartUninstall=開始解除安裝
english.StartUninstall=Uninstall
chinese.UninstallDone=%1 卸载完成。
chinesetraditional.UninstallDone=%1 已解除安裝。
english.UninstallDone=%1 has been uninstalled.
chinese.RegisterService=正在注册后台服务...
chinesetraditional.RegisterService=正在註冊背景服務...
english.RegisterService=Registering the background service...
chinese.StopService=正在停止旧后台服务并还原网络设置...
chinesetraditional.StopService=正在停止舊背景服務並還原網路設定...
english.StopService=Stopping the old background service and restoring network settings...
chinese.ServiceStopFailed=旧后台服务停止或注销失败，安装已中止。请排除服务故障后重试。
chinesetraditional.ServiceStopFailed=舊背景服務停止或註銷失敗，安裝已中止。請排除服務故障後重試。
english.ServiceStopFailed=The old background service could not be stopped or removed. Installation has been cancelled. Resolve the service error and retry.
chinese.ServiceInstallFailed=后台服务安装失败，客户端未启动。请排除服务故障后重新运行安装器。
chinesetraditional.ServiceInstallFailed=背景服務安裝失敗，用戶端未啟動。請排除服務故障後重新執行安裝程式。
english.ServiceInstallFailed=The background service could not be installed. The client was not started. Resolve the service error and run the installer again.
chinese.ServiceInstallFailedTitle=安装未完成
chinesetraditional.ServiceInstallFailedTitle=安裝未完成
english.ServiceInstallFailedTitle=Installation incomplete
chinese.ServiceUninstallFailed=后台服务停止或注销失败，卸载已中止，应用文件及数据已保留。请排除服务故障后重试。
chinesetraditional.ServiceUninstallFailed=背景服務停止或註銷失敗，解除安裝已中止，應用程式檔案及資料已保留。請排除服務故障後重試。
english.ServiceUninstallFailed=The background service could not be stopped or removed. Uninstallation was cancelled; application files and data have been kept. Resolve the service error and retry.
chinese.LaunchNow=立即运行 %1
chinesetraditional.LaunchNow=立即執行 %1
english.LaunchNow=Launch %1 now

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
; 服务 exe 不能延到重启替换：ssPostInstall 立即用它注册服务，延后就会注册旧版
Source: "{#StageDir}\service\{#ServiceExeName}"; DestDir: "{app}\service"; Flags: ignoreversion
Source: "{#StageDir}\*"; DestDir: "{app}"; Excludes: "service\{#ServiceExeName}"; Flags: ignoreversion recursesubdirs createallsubdirs restartreplace

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\{#AppExeName}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExeName}"; Description: "{cm:LaunchNow,{#AppName}}"; Flags: nowait postinstall skipifsilent runasoriginaluser; Check: ServiceInstalled

[UninstallDelete]
Type: files; Name: "{app}\installer-locale"

[Code]
const
  MB_TOPMOST = $00040000;
  HWND_TOPMOST = -1;
  HWND_NOTOPMOST = -2;
  SWP_NOSIZE = $0001;
  SWP_NOMOVE = $0002;
  OBM_CHECKBOXES = 32759;
  BP_CHECKBOX = 3;
  CBS_CHECKEDNORMAL = 5;
  TS_TRUE = 1;
  UninstallRegKey = 'Software\Microsoft\Windows\CurrentVersion\Uninstall\{8F3C4A21-7B65-4D0E-9C2A-1E6B5D4F3A80}_is1';

type
  TCheckSize = record
    cx, cy: Integer;
  end;

function SetWindowPos(Wnd, WndInsertAfter, X, Y, cx, cy, Flags: Integer): Boolean;
  external 'SetWindowPos@user32.dll stdcall';
function SetForegroundWindow(Wnd: Integer): Boolean;
  external 'SetForegroundWindow@user32.dll stdcall';
function RegisterWindowMessage(Name: String): Cardinal;
  external 'RegisterWindowMessageW@user32.dll stdcall';
function LoadBitmap(Instance, Name: Integer): Integer;
  external 'LoadBitmapW@user32.dll stdcall';
function OpenThemeData(Wnd: HWND; ClassList: String): Integer;
  external 'OpenThemeData@uxtheme.dll stdcall';
function GetThemePartSize(Theme, DC, Part, State, Rect, Sizing: Integer;
  var Size: TCheckSize): Integer;
  external 'GetThemePartSize@uxtheme.dll stdcall';
function CloseThemeData(Theme: Integer): Integer;
  external 'CloseThemeData@uxtheme.dll stdcall';

var
  WizardFronted: Boolean;
  RemoveUserData: Boolean;
  ServiceInstallSucceeded: Boolean;

function ServiceInstalled: Boolean;
begin
  Result := ServiceInstallSucceeded;
end;

function GetCustomSetupExitCode: Integer;
begin
  if ServiceInstallSucceeded then
    Result := 0
  else
    Result := 1;
end;

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

procedure WriteInstallerLocale;
var
  Locale, Dir: String;
begin
  if CompareText(ActiveLanguage(), 'chinesetraditional') = 0 then
    Locale := 'zh_TW'
  else if CompareText(ActiveLanguage(), 'english') = 0 then
    Locale := 'en-US'
  else
    Locale := 'zh_CN';
  Dir := ExpandConstant('{app}');
  SaveStringToFile(Dir + '\installer-locale', Locale, False);
end;

procedure InitializeWizard;
var
  Bitmap: TBitmap;
  Theme: Integer;
  Size: TCheckSize;
begin
  WizardForm.LicenseAcceptedRadio.Checked := True;
  WizardForm.TasksList.Offset := 0;
  Theme := OpenThemeData(WizardForm.TasksList.Handle, 'Button');
  if Theme <> 0 then
  begin
    try
      if GetThemePartSize(Theme, 0, BP_CHECKBOX, CBS_CHECKEDNORMAL, 0, TS_TRUE, Size) = 0 then
      begin
        Bitmap := TBitmap.Create;
        try
          Bitmap.Handle := LoadBitmap(0, OBM_CHECKBOXES);
          WizardForm.TasksList.Offset := Size.cx - Bitmap.Width div 4;
        finally
          Bitmap.Free;
        end;
      end;
    finally
      CloseThemeData(Theme);
    end;
  end;
  WizardForm.RunList.Offset := WizardForm.TasksList.Offset;
end;

function InitializeSetup(): Boolean;
begin
  if CheckForMutexes('{#SetupSetting("AppMutex")}') and not WizardSilent then
  begin
    if MsgBox(
      FmtMessage(CustomMessage('CloseRunningPrompt'), ['{#AppName}']),
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
  Code: Integer;
begin
  if CurStep = ssPostInstall then
  begin
    WizardForm.StatusLabel.Caption := CustomMessage('RegisterService');
    ServiceInstallSucceeded := Exec(ExpandConstant('{app}\service\{#ServiceExeName}'), 'install', '',
      SW_HIDE, ewWaitUntilTerminated, Code);
    ServiceInstallSucceeded := ServiceInstallSucceeded and (Code = 0);
    if not ServiceInstallSucceeded then
    begin
      Log(CustomMessage('ServiceInstallFailed') + ' (' + IntToStr(Code) + ')');
      SuppressibleMsgBox(CustomMessage('ServiceInstallFailed'), mbError, MB_OK, IDOK);
    end;
    // 设置里的「卸载」走 QuietUninstallString；只改 UninstallString 仍会弹 ConfirmUninstall
    UninstallCmd := '"' + ExpandConstant('{uninstallexe}') + '" /SILENT /SUPPRESSMSGBOXES';
    RegWriteStringValue(HKLM64, UninstallRegKey, 'UninstallString', UninstallCmd);
    RegWriteStringValue(HKLM64, UninstallRegKey, 'QuietUninstallString', UninstallCmd);
    WriteInstallerLocale;
  end;
end;

// 提权后前台权归 UAC 发起方，向导窗口会开在其它窗口之下；
// 只能自己置顶再取消置顶把它抬到最上层，SetForegroundWindow 单独调用会被系统降级。
procedure CurPageChanged(CurPageID: Integer);
begin
  if (CurPageID = wpFinished) and not ServiceInstallSucceeded then
  begin
    WizardForm.FinishedHeadingLabel.Caption := CustomMessage('ServiceInstallFailedTitle');
    WizardForm.FinishedLabel.Caption := CustomMessage('ServiceInstallFailed');
  end;
  if WizardFronted then
    Exit;
  WizardFronted := True;
  SetWindowPos(WizardForm.Handle, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE or SWP_NOSIZE);
  SetWindowPos(WizardForm.Handle, HWND_NOTOPMOST, 0, 0, 0, 0, SWP_NOMOVE or SWP_NOSIZE);
  SetForegroundWindow(WizardForm.Handle);
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  Service: String;
  Code: Integer;
begin
  Result := '';
  if not RegKeyExists(HKLM, 'SYSTEM\CurrentControlSet\Services\ECYCloudService') then
    Exit;
  WizardForm.PreparingLabel.Caption := CustomMessage('StopService');
  WizardForm.PreparingLabel.Visible := True;
  WizardForm.PreparingLabel.Update;
  Log(CustomMessage('StopService'));
  ExtractTemporaryFile('{#ServiceExeName}');
  Service := ExpandConstant('{tmp}\{#ServiceExeName}');
  if not Exec(Service, 'uninstall', '', SW_HIDE, ewWaitUntilTerminated, Code) then
    Result := CustomMessage('ServiceStopFailed')
  else if Code <> 0 then
    Result := CustomMessage('ServiceStopFailed');
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

// ConfirmUninstall 只在非 Silent 时出现；设置常丢掉 /SILENT，
// 须先退出释放 unins000.dat 独占锁，再以 Silent 重入完成卸载
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
    Form.Caption := FmtMessage(CustomMessage('UninstallCaption'), ['{#AppName}']);

    Prompt := TNewStaticText.Create(Form);
    Prompt.Parent := Form;
    Prompt.Left := ScaleX(16);
    Prompt.Top := ScaleY(16);
    Prompt.Width := Form.ClientWidth - ScaleX(32);
    Prompt.WordWrap := True;
    Prompt.AutoSize := True;
    Prompt.Caption := FmtMessage(CustomMessage('UninstallPrompt'), ['{#AppName}']);

    DataCheck := TNewCheckBox.Create(Form);
    DataCheck.Parent := Form;
    DataCheck.Left := ScaleX(16);
    DataCheck.Top := Prompt.Top + Prompt.Height + ScaleY(14);
    DataCheck.Width := Form.ClientWidth - ScaleX(32);
    DataCheck.Height := ScaleY(20);
    DataCheck.Checked := False;
    DataCheck.Caption := CustomMessage('RemoveUserData');

    Detail := TNewStaticText.Create(Form);
    Detail.Parent := Form;
    Detail.Left := DataCheck.Left + ScaleX(18);
    Detail.Top := DataCheck.Top + DataCheck.Height + ScaleY(2);
    Detail.Width := Form.ClientWidth - Detail.Left - ScaleX(16);
    Detail.WordWrap := True;
    Detail.AutoSize := True;
    Detail.Caption := CustomMessage('RemoveUserDataDetail');

    OkButton := TNewButton.Create(Form);
    OkButton.Parent := Form;
    OkButton.Height := ScaleY(26);
    OkButton.Top := Form.ClientHeight - ScaleY(16) - OkButton.Height;
    OkButton.Caption := CustomMessage('StartUninstall');
    OkButton.ModalResult := mrOk;
    OkButton.Default := True;

    CancelButton := TNewButton.Create(Form);
    CancelButton.Parent := Form;
    CancelButton.Height := OkButton.Height;
    CancelButton.Top := OkButton.Top;
    CancelButton.Caption := SetupMessage(msgButtonCancel);
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
var
  Code: Integer;
  ServiceRemoved: Boolean;
begin
  // 客户端要赶在 Inno 检查互斥体之前关掉，否则会弹那句「请从托盘退出」
  if CurUninstallStep = usAppMutexCheck then
  begin
    CloseRunningApp;
    Exit;
  end;

  if (CurUninstallStep = usUninstall) and
    RegKeyExists(HKLM, 'SYSTEM\CurrentControlSet\Services\ECYCloudService') then
  begin
    ServiceRemoved := Exec(ExpandConstant('{app}\service\{#ServiceExeName}'), 'uninstall', '',
      SW_HIDE, ewWaitUntilTerminated, Code);
    if not ServiceRemoved or (Code <> 0) then
    begin
      Log(CustomMessage('ServiceUninstallFailed') + ' (' + IntToStr(Code) + ')');
      SuppressibleMsgBox(CustomMessage('ServiceUninstallFailed'), mbError, MB_OK, IDOK);
      Abort;
    end;
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
    MsgBox(FmtMessage(CustomMessage('UninstallDone'), ['{#AppName}']), mbInformation, MB_OK or MB_TOPMOST);
end;
