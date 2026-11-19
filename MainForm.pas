unit MainForm;

{ 系统资源实时监控工具（Delphi 11.3）
  页签：总览 / CPU / 内存 / 磁盘 / 进程 / 设置
  功能：托盘最小化、气泡告警、日志 CSV、INI 设置持久化、开机自启动 }

interface

uses
  Winapi.Windows, Winapi.Messages,
  System.SysUtils, System.Classes, System.Types, System.Math, System.IniFiles,
  System.DateUtils, System.Generics.Collections, System.Generics.Defaults,
  System.UITypes, System.Win.Registry,
  Vcl.Graphics, Vcl.Controls, Vcl.Forms, Vcl.StdCtrls, Vcl.ExtCtrls,
  Vcl.ComCtrls, Vcl.Menus, Vcl.Clipbrd,
  Monitor.Core, ChartUtils, CpuTemp, Vcl.Dialogs;

type
  TMonitorForm = class(TForm)
    Timer1: TTimer;
    TrayIcon1: TTrayIcon;
    PageControl1: TPageControl;
    TabOverview: TTabSheet;
    TabCpu: TTabSheet;
    TabMem: TTabSheet;
    TabDisk: TTabSheet;
    TabProc: TTabSheet;
    TabSet: TTabSheet;
    StatusBar1: TStatusBar;
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure FormResize(Sender: TObject);
    procedure FormCloseQuery(Sender: TObject; var CanClose: Boolean);
    procedure Timer1Timer(Sender: TObject);
    procedure TrayIcon1Click(Sender: TObject);
  private
    FEngine: TMonitorEngine;
    FThermal: TThermalThread;
    FCpuTempC: Double;
    FCpuTempOk: Boolean;
    FCpuTempStatus: string;
    FLastSample: TMonitorSample;
    FHasSample: Boolean;
    FPrevTime: TDateTime;
    FCpuHist: TList<Double>;
    FMemHist: TList<Double>;
    FReadHist: TList<Double>;
    FWriteHist: TList<Double>;
    FLastReadBPS: Double;
    FLastWriteBPS: Double;

    // 设置
    FIntervalMs: Integer;
    FMaxPoints: Integer;
    FCpuAlert: Double;
    FMemAlert: Double;
    FDiskFreeAlertGB: Double;
    FSoundAlert: Boolean;
    FTopMost: Boolean;
    FStartMinimized: Boolean;
    FCloseToTray: Boolean;
    FLogAlerts: Boolean;
    FLogSnapshot: Boolean;
    FExitConfirmed: Boolean;
    FAlertCooldown: TDateTime;
    FLastSnapLog: TDateTime;
    FProcRefreshTick: Integer;

    // 界面
    PbOverview: TPaintBox;
    PbCpuChart: TPaintBox;
    PbCpuCores: TPaintBox;
    PbMemChart: TPaintBox;
    PbMemBar: TPaintBox;
    PbDisk: TPaintBox;
    LvProcs: TListView;
    FProcsView: TArray<TProcessCpuInfo>;
    FProcSortCol: Integer;
    FProcSortDesc: Boolean;
    TrayMenu: TPopupMenu;
    MiShow: TMenuItem;
    MiCopy: TMenuItem;
    MiTop: TMenuItem;
    MiAuto: TMenuItem;
    MiExit: TMenuItem;
    EdInterval: TEdit;
    EdMaxPoints: TEdit;
    EdCpuAlert: TEdit;
    EdMemAlert: TEdit;
    EdDiskFree: TEdit;
    ChkSound: TCheckBox;
    ChkTop: TCheckBox;
    ChkStartMin: TCheckBox;
    ChkCloseTray: TCheckBox;
    ChkAutoStart: TCheckBox;
    ChkLogAlerts: TCheckBox;
    ChkLogSnap: TCheckBox;

    procedure WMSysCommand(var Msg: TWMSysCommand); message WM_SYSCOMMAND;

    procedure BuildTrayMenu;
    procedure BuildOverview;
    procedure BuildCpuTab;
    procedure BuildMemTab;
    procedure BuildDiskTab;
    procedure BuildProcTab;
    procedure BuildSettingsTab;
    procedure LoadSettings;
    procedure SaveSettings;
    procedure FillSettingsControls;
    procedure ApplySettings;

    procedure DoSample(const ElapsedSec: Double);
    procedure PushHist(AList: TList<Double>; const V: Double);
    procedure CheckAlerts;
    procedure LogLine(const AType, ADetail: string);
    procedure LogSnapshotLine;
    procedure SetTopMost(Value: Boolean);
    procedure SetAutoStart(Enable: Boolean);
    function AutoStartEnabled: Boolean;
    procedure UpdateStatusBar;
    function CpuTempText: string;
    procedure RefreshProcView;
    procedure SortProcView(var A: TArray<TProcessCpuInfo>);
    function TopCpuProcsText(const Count: Integer): string;

    procedure PbOverviewPaint(Sender: TObject);
    procedure PbCpuChartPaint(Sender: TObject);
    procedure PbCpuCoresPaint(Sender: TObject);
    procedure PbMemChartPaint(Sender: TObject);
    procedure PbMemBarPaint(Sender: TObject);
    procedure PbDiskPaint(Sender: TObject);
    procedure LvProcsData(Sender: TObject; Item: TListItem);
    procedure LvProcsColumnClick(Sender: TObject; Column: TListColumn);
    procedure BtnSaveClick(Sender: TObject);
    procedure BtnDefaultsClick(Sender: TObject);
    procedure BtnTestAlertClick(Sender: TObject);
    procedure MiShowClick(Sender: TObject);
    procedure MiCopyClick(Sender: TObject);
    procedure MiTopClick(Sender: TObject);
    procedure MiAutoClick(Sender: TObject);
    procedure MiExitClick(Sender: TObject);
  end;

var
  MonitorForm: TMonitorForm;

implementation

{$R *.dfm}

const
  INI_NAME = 'ResourceMonitor.ini';
  LOG_NAME = 'monitor_log.csv';

{ ---------------- 创建 / 销毁 ---------------- }

procedure TMonitorForm.FormCreate(Sender: TObject);
begin
  Caption := '系统资源监控 v1.0';
  Application.Title := '系统资源监控';
  Scaled := False;
  DoubleBuffered := True;

  FCpuHist := TList<Double>.Create;
  FMemHist := TList<Double>.Create;
  FReadHist := TList<Double>.Create;
  FWriteHist := TList<Double>.Create;
  FEngine := TMonitorEngine.Create;
  // 后台线程每 5 秒读取一次 CPU 温度（WMI 查询较慢，不能放主线程）
  FCpuTempOk := False;
  FCpuTempC := 0;
  FCpuTempStatus := '正在读取 CPU 温度…';
  FThermal := TThermalThread.Create(5000);
  FThermal.Start;
  FProcSortCol := 2;
  FProcSortDesc := True;
  FLastSnapLog := Now;

  LoadSettings;

  TabOverview.Caption := '总览';
  TabCpu.Caption := 'CPU';
  TabMem.Caption := '内存';
  TabDisk.Caption := '磁盘';
  TabProc.Caption := '进程';
  TabSet.Caption := '设置';

  BuildTrayMenu;
  BuildOverview;
  BuildCpuTab;
  BuildMemTab;
  BuildDiskTab;
  BuildProcTab;
  BuildSettingsTab;
  FillSettingsControls;

  TrayIcon1.Icon := Application.Icon;
  TrayIcon1.Hint := '系统资源监控';
  TrayIcon1.Visible := True;

  ApplySettings;

  // 立即执行第一次采样
  Timer1Timer(nil);

  if FStartMinimized then begin
    Application.ShowMainForm := False;
    Visible := False;
  end;
end;

procedure TMonitorForm.FormDestroy(Sender: TObject);
begin
  FreeAndNil(FThermal);
  FreeAndNil(FCpuHist);
  FreeAndNil(FMemHist);
  FreeAndNil(FReadHist);
  FreeAndNil(FWriteHist);
  FreeAndNil(FEngine);
end;

procedure TMonitorForm.FormResize(Sender: TObject);
begin
  if PbOverview <> nil then PbOverview.Invalidate;
  if PbCpuChart <> nil then PbCpuChart.Invalidate;
  if PbCpuCores <> nil then PbCpuCores.Invalidate;
  if PbMemChart <> nil then PbMemChart.Invalidate;
  if PbMemBar <> nil then PbMemBar.Invalidate;
  if PbDisk <> nil then PbDisk.Invalidate;
end;

procedure TMonitorForm.FormCloseQuery(Sender: TObject; var CanClose: Boolean);
begin
  if (not FExitConfirmed) and FCloseToTray then begin
    CanClose := False;
    Hide;
    TrayIcon1.BalloonTitle := '系统资源监控';
    TrayIcon1.BalloonFlags := bfInfo;
    TrayIcon1.BalloonHint := '程序仍在后台运行，双击托盘图标可重新打开窗口。';
    TrayIcon1.ShowBalloonHint;
    Exit;
  end;
  SaveSettings;
end;

{ ---------------- 界面构建 ---------------- }

procedure TMonitorForm.BuildTrayMenu;
var
  Sep: TMenuItem;
begin
  TrayMenu := TPopupMenu.Create(Self);

  MiShow := TMenuItem.Create(TrayMenu);
  MiShow.Caption := '显示主窗口';
  MiShow.OnClick := MiShowClick;
  TrayMenu.Items.Add(MiShow);

  MiCopy := TMenuItem.Create(TrayMenu);
  MiCopy.Caption := '复制状态到剪贴板';
  MiCopy.OnClick := MiCopyClick;
  TrayMenu.Items.Add(MiCopy);

  MiTop := TMenuItem.Create(TrayMenu);
  MiTop.Caption := '窗口总在最前';
  MiTop.OnClick := MiTopClick;
  TrayMenu.Items.Add(MiTop);

  MiAuto := TMenuItem.Create(TrayMenu);
  MiAuto.Caption := '开机自动启动';
  MiAuto.OnClick := MiAutoClick;
  TrayMenu.Items.Add(MiAuto);

  Sep := TMenuItem.Create(TrayMenu);
  Sep.Caption := '-';
  TrayMenu.Items.Add(Sep);

  MiExit := TMenuItem.Create(TrayMenu);
  MiExit.Caption := '退出';
  MiExit.OnClick := MiExitClick;
  TrayMenu.Items.Add(MiExit);

  TrayIcon1.PopupMenu := TrayMenu;
end;

procedure TMonitorForm.BuildOverview;
begin
  PbOverview := TPaintBox.Create(Self);
  PbOverview.Parent := TabOverview;
  PbOverview.Align := alClient;
  PbOverview.OnPaint := PbOverviewPaint;
end;

procedure TMonitorForm.BuildCpuTab;
begin
  PbCpuChart := TPaintBox.Create(Self);
  PbCpuChart.Parent := TabCpu;
  PbCpuChart.Height := 300;
  PbCpuChart.Top := 0;
  PbCpuChart.Align := alTop;
  PbCpuChart.OnPaint := PbCpuChartPaint;

  PbCpuCores := TPaintBox.Create(Self);
  PbCpuCores.Parent := TabCpu;
  PbCpuCores.Align := alClient;
  PbCpuCores.OnPaint := PbCpuCoresPaint;
end;

procedure TMonitorForm.BuildMemTab;
begin
  PbMemChart := TPaintBox.Create(Self);
  PbMemChart.Parent := TabMem;
  PbMemChart.Height := 300;
  PbMemChart.Top := 0;
  PbMemChart.Align := alTop;
  PbMemChart.OnPaint := PbMemChartPaint;

  PbMemBar := TPaintBox.Create(Self);
  PbMemBar.Parent := TabMem;
  PbMemBar.Align := alClient;
  PbMemBar.OnPaint := PbMemBarPaint;
end;

procedure TMonitorForm.BuildDiskTab;
begin
  PbDisk := TPaintBox.Create(Self);
  PbDisk.Parent := TabDisk;
  PbDisk.Align := alClient;
  PbDisk.OnPaint := PbDiskPaint;
end;

procedure TMonitorForm.BuildProcTab;
begin
  LvProcs := TListView.Create(Self);
  LvProcs.Parent := TabProc;
  LvProcs.Align := alClient;
  LvProcs.ViewStyle := vsReport;
  LvProcs.OwnerData := True;
  LvProcs.ReadOnly := True;
  LvProcs.RowSelect := True;
  LvProcs.GridLines := True;
  LvProcs.HideSelection := False;
  with LvProcs.Columns.Add do begin Caption := '进程名'; Width := 280; end;
  with LvProcs.Columns.Add do begin Caption := 'PID'; Width := 70; end;
  with LvProcs.Columns.Add do begin Caption := 'CPU %'; Width := 90; Alignment := taRightJustify; end;
  with LvProcs.Columns.Add do begin Caption := '内存'; Width := 110; Alignment := taRightJustify; end;
  LvProcs.OnData := LvProcsData;
  LvProcs.OnColumnClick := LvProcsColumnClick;
end;

procedure TMonitorForm.BuildSettingsTab;

  function MkLabel(Parent: TWinControl; X, Y: Integer; const Text: string): TLabel;
  begin
    Result := TLabel.Create(Self);
    Result.Parent := Parent;
    Result.Left := X;
    Result.Top := Y;
    Result.Caption := Text;
  end;

  function MkEdit(Parent: TWinControl; X, Y, W: Integer): TEdit;
  begin
    Result := TEdit.Create(Self);
    Result.Parent := Parent;
    Result.SetBounds(X, Y - 3, W, 24);
  end;

  function MkCheck(Parent: TWinControl; X, Y: Integer; const Text: string): TCheckBox;
  begin
    Result := TCheckBox.Create(Self);
    Result.Parent := Parent;
    Result.Left := X;
    Result.Top := Y;
    Result.Caption := Text;
  end;

var
  GB1, GB2, GB3, GB4: TGroupBox;
  BtnSave, BtnDefaults, BtnTest: TButton;
begin
  GB1 := TGroupBox.Create(Self);
  GB1.Parent := TabSet;
  GB1.SetBounds(16, 12, 380, 104);
  GB1.Caption := '  采样  ';
  MkLabel(GB1, 20, 32, '刷新间隔（毫秒，200-10000）：');
  EdInterval := MkEdit(GB1, 250, 29, 100);
  MkLabel(GB1, 20, 66, '历史曲线保留点数（100-3600）：');
  EdMaxPoints := MkEdit(GB1, 250, 63, 100);

  GB2 := TGroupBox.Create(Self);
  GB2.Parent := TabSet;
  GB2.SetBounds(16, 126, 380, 156);
  GB2.Caption := '  告警阈值  ';
  MkLabel(GB2, 20, 32, 'CPU 使用率 ≥（%）：');
  EdCpuAlert := MkEdit(GB2, 250, 29, 100);
  MkLabel(GB2, 20, 64, '内存使用率 ≥（%）：');
  EdMemAlert := MkEdit(GB2, 250, 61, 100);
  MkLabel(GB2, 20, 96, '磁盘剩余空间 ≤（GB）：');
  EdDiskFree := MkEdit(GB2, 250, 93, 100);
  ChkSound := MkCheck(GB2, 20, 122, '触发告警时播放提示音');

  GB3 := TGroupBox.Create(Self);
  GB3.Parent := TabSet;
  GB3.SetBounds(416, 12, 400, 156);
  GB3.Caption := '  行为  ';
  ChkTop := MkCheck(GB3, 20, 28, '窗口总在最前');
  ChkStartMin := MkCheck(GB3, 20, 56, '启动时最小化到托盘');
  ChkCloseTray := MkCheck(GB3, 20, 84, '关闭窗口时隐藏到托盘（不退出）');
  ChkAutoStart := MkCheck(GB3, 20, 112, '开机自动启动（当前用户）');

  GB4 := TGroupBox.Create(Self);
  GB4.Parent := TabSet;
  GB4.SetBounds(416, 178, 400, 104);
  GB4.Caption := '  日志  ';
  ChkLogAlerts := MkCheck(GB4, 20, 28, '记录告警日志');
  ChkLogSnap := MkCheck(GB4, 20, 56, '每 60 秒记录一条资源快照');
  MkLabel(GB4, 20, 80, '日志文件：' + LOG_NAME + '（程序目录，UTF-8 CSV）');

  BtnSave := TButton.Create(Self);
  BtnSave.Parent := TabSet;
  BtnSave.SetBounds(16, 296, 130, 30);
  BtnSave.Caption := '保存并应用设置';
  BtnSave.OnClick := BtnSaveClick;

  BtnDefaults := TButton.Create(Self);
  BtnDefaults.Parent := TabSet;
  BtnDefaults.SetBounds(156, 296, 110, 30);
  BtnDefaults.Caption := '恢复默认';
  BtnDefaults.OnClick := BtnDefaultsClick;

  BtnTest := TButton.Create(Self);
  BtnTest.Parent := TabSet;
  BtnTest.SetBounds(276, 296, 110, 30);
  BtnTest.Caption := '测试告警提示';
  BtnTest.OnClick := BtnTestAlertClick;
end;

{ ---------------- 设置 ---------------- }

procedure TMonitorForm.LoadSettings;
var
  Ini: TIniFile;
begin
  Ini := TIniFile.Create(ExtractFilePath(Application.ExeName) + INI_NAME);
  try
    FIntervalMs := Ini.ReadInteger('设置', '刷新间隔ms', 1000);
    FMaxPoints := Ini.ReadInteger('设置', '历史点数', 600);
    FCpuAlert := Ini.ReadFloat('设置', 'CPU告警阈值', 90);
    FMemAlert := Ini.ReadFloat('设置', '内存告警阈值', 90);
    FDiskFreeAlertGB := Ini.ReadFloat('设置', '磁盘剩余告警GB', 5);
    FSoundAlert := Ini.ReadBool('设置', '声音提醒', True);
    FTopMost := Ini.ReadBool('设置', '总在最前', False);
    FStartMinimized := Ini.ReadBool('设置', '启动最小化', False);
    FCloseToTray := Ini.ReadBool('设置', '关闭到托盘', True);
    FLogAlerts := Ini.ReadBool('设置', '记录告警', True);
    FLogSnapshot := Ini.ReadBool('设置', '记录快照', False);
  finally
    Ini.Free;
  end;
end;

procedure TMonitorForm.SaveSettings;
var
  Ini: TIniFile;
begin
  Ini := TIniFile.Create(ExtractFilePath(Application.ExeName) + INI_NAME);
  try
    Ini.WriteInteger('设置', '刷新间隔ms', FIntervalMs);
    Ini.WriteInteger('设置', '历史点数', FMaxPoints);
    Ini.WriteFloat('设置', 'CPU告警阈值', FCpuAlert);
    Ini.WriteFloat('设置', '内存告警阈值', FMemAlert);
    Ini.WriteFloat('设置', '磁盘剩余告警GB', FDiskFreeAlertGB);
    Ini.WriteBool('设置', '声音提醒', FSoundAlert);
    Ini.WriteBool('设置', '总在最前', FTopMost);
    Ini.WriteBool('设置', '启动最小化', FStartMinimized);
    Ini.WriteBool('设置', '关闭到托盘', FCloseToTray);
    Ini.WriteBool('设置', '记录告警', FLogAlerts);
    Ini.WriteBool('设置', '记录快照', FLogSnapshot);
  finally
    Ini.Free;
  end;
end;

procedure TMonitorForm.FillSettingsControls;
begin
  EdInterval.Text := IntToStr(FIntervalMs);
  EdMaxPoints.Text := IntToStr(FMaxPoints);
  EdCpuAlert.Text := FormatFloat('0.#', FCpuAlert);
  EdMemAlert.Text := FormatFloat('0.#', FMemAlert);
  EdDiskFree.Text := FormatFloat('0.#', FDiskFreeAlertGB);
  ChkSound.Checked := FSoundAlert;
  ChkTop.Checked := FTopMost;
  ChkStartMin.Checked := FStartMinimized;
  ChkCloseTray.Checked := FCloseToTray;
  ChkAutoStart.Checked := AutoStartEnabled;
  ChkLogAlerts.Checked := FLogAlerts;
  ChkLogSnap.Checked := FLogSnapshot;
end;

procedure TMonitorForm.ApplySettings;
begin
  Timer1.Enabled := False;
  Timer1.Interval := EnsureRange(FIntervalMs, 200, 10000);
  Timer1.Enabled := True;
  SetTopMost(FTopMost);
end;

procedure TMonitorForm.SetTopMost(Value: Boolean);
const
  Flags = SWP_NOMOVE or SWP_NOSIZE or SWP_NOACTIVATE;
begin
  FTopMost := Value;
  if Value then
    SetWindowPos(Handle, HWND_TOPMOST, 0, 0, 0, 0, Flags)
  else
    SetWindowPos(Handle, HWND_NOTOPMOST, 0, 0, 0, 0, Flags);
  if MiTop <> nil then MiTop.Checked := Value;
  if ChkTop <> nil then ChkTop.Checked := Value;
end;

procedure TMonitorForm.SetAutoStart(Enable: Boolean);
var
  Reg: TRegistry;
begin
  Reg := TRegistry.Create(KEY_READ or KEY_WRITE);
  try
    Reg.RootKey := HKEY_CURRENT_USER;
    if Reg.OpenKey('Software\Microsoft\Windows\CurrentVersion\Run', True) then begin
      if Enable then
        Reg.WriteString('ResourceMonitor', '"' + Application.ExeName + '"')
      else
        Reg.DeleteValue('ResourceMonitor');
      Reg.CloseKey;
    end;
  finally
    Reg.Free;
  end;
end;

function TMonitorForm.AutoStartEnabled: Boolean;
var
  Reg: TRegistry;
begin
  Result := False;
  Reg := TRegistry.Create(KEY_READ);
  try
    Reg.RootKey := HKEY_CURRENT_USER;
    if Reg.OpenKeyReadOnly('Software\Microsoft\Windows\CurrentVersion\Run') then begin
      Result := Reg.ValueExists('ResourceMonitor');
      Reg.CloseKey;
    end;
  finally
    Reg.Free;
  end;
end;

procedure TMonitorForm.BtnSaveClick(Sender: TObject);
var
  V: Integer;
  F: Double;
begin
  V := StrToIntDef(EdInterval.Text, 0);
  if (V < 200) or (V > 10000) then begin
    PageControl1.ActivePage := TabSet;
    EdInterval.SetFocus;
    ShowMessage('刷新间隔需在 200-10000 毫秒之间。');
    Exit;
  end;
  FIntervalMs := V;

  V := StrToIntDef(EdMaxPoints.Text, 0);
  if (V < 100) or (V > 3600) then begin
    PageControl1.ActivePage := TabSet;
    EdMaxPoints.SetFocus;
    ShowMessage('历史点数需在 100-3600 之间。');
    Exit;
  end;
  FMaxPoints := V;

  FCpuAlert := EnsureRange(StrToFloatDef(EdCpuAlert.Text, 90), 10, 100);
  FMemAlert := EnsureRange(StrToFloatDef(EdMemAlert.Text, 90), 10, 100);
  FDiskFreeAlertGB := EnsureRange(StrToFloatDef(EdDiskFree.Text, 5), 0, 1024);

  FSoundAlert := ChkSound.Checked;
  FCloseToTray := ChkCloseTray.Checked;
  FStartMinimized := ChkStartMin.Checked;
  FLogAlerts := ChkLogAlerts.Checked;
  FLogSnapshot := ChkLogSnap.Checked;

  SetAutoStart(ChkAutoStart.Checked);
  SetTopMost(ChkTop.Checked);

  SaveSettings;
  ApplySettings;
  ShowMessage('设置已保存并应用。');
end;

procedure TMonitorForm.BtnDefaultsClick(Sender: TObject);
begin
  FIntervalMs := 1000;
  FMaxPoints := 600;
  FCpuAlert := 90;
  FMemAlert := 90;
  FDiskFreeAlertGB := 5;
  FSoundAlert := True;
  FTopMost := False;
  FStartMinimized := False;
  FCloseToTray := True;
  FLogAlerts := True;
  FLogSnapshot := False;
  SetAutoStart(False);
  FillSettingsControls;
  SaveSettings;
  ApplySettings;
end;

procedure TMonitorForm.BtnTestAlertClick(Sender: TObject);
begin
  TrayIcon1.BalloonTitle := '测试告警';
  TrayIcon1.BalloonFlags := bfWarning;
  TrayIcon1.BalloonHint := '这是一条测试告警：CPU 使用率 99%，内存 95%。';
  TrayIcon1.ShowBalloonHint;
  if FSoundAlert then
    MessageBeep(MB_ICONWARNING);
  LogLine('测试', '手动触发告警测试');
end;

{ ---------------- 托盘 ---------------- }

procedure TMonitorForm.TrayIcon1Click(Sender: TObject);
begin
  if Visible then Exit;
  Application.Restore;
  Show;
  WindowState := wsNormal;
  SetForegroundWindow(Handle);
end;

procedure TMonitorForm.MiShowClick(Sender: TObject);
begin
  TrayIcon1Click(nil);
end;

procedure TMonitorForm.MiCopyClick(Sender: TObject);
var
  S: string;
  D: TDriveInfo;
begin
  if not FHasSample then Exit;
  S := FormatDateTime('yyyy-mm-dd hh:nn:ss', Now) + #13#10;
  S := S + Format('CPU：%.1f%%    温度：%s', [FLastSample.CpuTotal, CpuTempText]) + #13#10;
  S := S + Format('内存：%.1f%%（%s / %s）', [FLastSample.MemUsedPct,
    ByteSizeStr(FLastSample.MemUsed), ByteSizeStr(FLastSample.MemTotal)]) + #13#10;
  for D in FLastSample.Drives do
    if D.DriveType = DRIVE_FIXED then
      S := S + Format('%s 剩余 %s / %s，读 %s/s 写 %s/s', [D.Letter,
        ByteSizeStr(D.FreeBytes), ByteSizeStr(D.TotalBytes),
        ByteSizeStr(D.ReadBPS), ByteSizeStr(D.WriteBPS)]) + #13#10;
  Clipboard.AsText := S;
end;

procedure TMonitorForm.MiTopClick(Sender: TObject);
begin
  SetTopMost(not FTopMost);
  SaveSettings;
end;

procedure TMonitorForm.MiAutoClick(Sender: TObject);
begin
  SetAutoStart(not AutoStartEnabled);
  MiAuto.Checked := AutoStartEnabled;
  if ChkAutoStart <> nil then ChkAutoStart.Checked := AutoStartEnabled;
end;

procedure TMonitorForm.MiExitClick(Sender: TObject);
begin
  FExitConfirmed := True;
  Close;
end;

procedure TMonitorForm.WMSysCommand(var Msg: TWMSysCommand);
begin
  // 点击标题栏最小化 → 隐藏到托盘
  if (Msg.CmdType and $FFF0) = SC_MINIMIZE then begin
    Hide;
    Msg.Result := 0;
  end else
    inherited;
end;

{ ---------------- 采样 ---------------- }

procedure TMonitorForm.Timer1Timer(Sender: TObject);
var
  Elapsed: Double;
begin
  Elapsed := FIntervalMs / 1000.0;
  if FHasSample then begin
    Elapsed := (Now - FPrevTime) * SecsPerDay;
    if Elapsed < 0.05 then
      Elapsed := FIntervalMs / 1000.0;
  end;
  FPrevTime := Now;
  FHasSample := True;
  DoSample(Elapsed);
end;

procedure TMonitorForm.PushHist(AList: TList<Double>; const V: Double);
begin
  AList.Add(V);
  while AList.Count > FMaxPoints do
    AList.Delete(0);
end;

procedure TMonitorForm.DoSample(const ElapsedSec: Double);
var
  D: TDriveInfo;
begin
  FLastSample := FEngine.Sample(ElapsedSec);
  // 温度由后台线程刷新，这里只做线程安全读取
  FCpuTempOk := FThermal.GetTemperature(FCpuTempC, FCpuTempStatus);

  FLastReadBPS := 0;
  FLastWriteBPS := 0;
  for D in FLastSample.Drives do begin
    FLastReadBPS := FLastReadBPS + D.ReadBPS;
    FLastWriteBPS := FLastWriteBPS + D.WriteBPS;
  end;

  PushHist(FCpuHist, FLastSample.CpuTotal);
  PushHist(FMemHist, FLastSample.MemUsedPct);
  PushHist(FReadHist, FLastReadBPS);
  PushHist(FWriteHist, FLastWriteBPS);

  PbOverview.Invalidate;
  PbCpuChart.Invalidate;
  PbCpuCores.Invalidate;
  PbMemChart.Invalidate;
  PbMemBar.Invalidate;
  PbDisk.Invalidate;

  Inc(FProcRefreshTick);
  if (PageControl1.ActivePage = TabProc) or (FProcRefreshTick mod 2 = 0) then
    RefreshProcView;

  UpdateStatusBar;
  CheckAlerts;

  if FLogSnapshot and (Now - FLastSnapLog >= 60 / SecsPerDay) then begin
    FLastSnapLog := Now;
    LogSnapshotLine;
  end;
end;

function TMonitorForm.CpuTempText: string;
begin
  if FCpuTempOk then
    Result := Format('%.1f°C', [FCpuTempC])
  else
    Result := '不可用';
end;

procedure TMonitorForm.UpdateStatusBar;
begin
  if not FHasSample then Exit;
  StatusBar1.Panels[0].Text := Format('CPU %.1f%%', [FLastSample.CpuTotal]);
  StatusBar1.Panels[1].Text := '温度 ' + CpuTempText;
  StatusBar1.Panels[2].Text := Format('内存 %.1f%%', [FLastSample.MemUsedPct]);
  StatusBar1.Panels[3].Text := Format('磁盘 读%s/s 写%s/s',
    [ByteSizeStr(FLastReadBPS), ByteSizeStr(FLastWriteBPS)]);
  StatusBar1.Panels[4].Text := Format('刷新 %dms', [FIntervalMs]);
  StatusBar1.Panels[5].Text := FormatDateTime('hh:nn:ss', Now);
end;

{ ---------------- 告警 / 日志 ---------------- }

// 取 CPU 占用最高的 Count 个应用程序描述（Procs 已按 CPU 降序）
function TMonitorForm.TopCpuProcsText(const Count: Integer): string;
var
  I, n: Integer;
  P: TProcessCpuInfo;
begin
  Result := '';
  n := 0;
  for I := 0 to High(FLastSample.Procs) do begin
    P := FLastSample.Procs[I];
    if SameText(P.Name, 'System Idle Process') then Continue;
    if P.CpuPct < 0.1 then Break;   // 降序排列，后面更低，直接结束
    if n > 0 then Result := Result + '、';
    Result := Result + Format('%s（%.1f%%）', [P.Name, P.CpuPct]);
    Inc(n);
    if n >= Count then Break;
  end;
  if n = 0 then
    Result := 'CPU 占用最高的程序：无单进程显著占用（可能由多个进程合计导致）'
  else
    Result := Format('CPU 占用最高的 %d 个程序：', [n]) + Result;
end;

procedure TMonitorForm.CheckAlerts;
var
  Msgs: TStringList;
  D: TDriveInfo;
  FreeGB: Double;
begin
  if not FHasSample then Exit;
  Msgs := TStringList.Create;
  try
    if FLastSample.CpuTotal >= FCpuAlert then begin
      Msgs.Add(Format('CPU 使用率 %.1f%%，超过阈值 %.0f%%', [FLastSample.CpuTotal, FCpuAlert]));
      Msgs.Add(TopCpuProcsText(3));
    end;
    if FLastSample.MemUsedPct >= FMemAlert then
      Msgs.Add(Format('内存使用率 %.1f%%，超过阈值 %.0f%%', [FLastSample.MemUsedPct, FMemAlert]));
    for D in FLastSample.Drives do
      if D.DriveType = DRIVE_FIXED then begin
        FreeGB := D.FreeBytes / 1024 / 1024 / 1024;
        if (D.TotalBytes > 0) and (FreeGB <= FDiskFreeAlertGB) then
          Msgs.Add(Format('磁盘 %s 剩余 %.1f GB（阈值 %.0f GB）', [D.Letter, FreeGB, FDiskFreeAlertGB]));
      end;

    if (Msgs.Count > 0) and (Now >= FAlertCooldown) then begin
      FAlertCooldown := IncSecond(Now, 30);
      TrayIcon1.BalloonTitle := '系统资源告警';
      TrayIcon1.BalloonFlags := bfWarning;
      TrayIcon1.BalloonHint := Copy(Msgs.Text, 1, 240);
      TrayIcon1.ShowBalloonHint;
      if FSoundAlert then
        MessageBeep(MB_ICONWARNING);
      if FLogAlerts then
        LogLine('告警', Msgs.Text);
    end;
  finally
    Msgs.Free;
  end;
end;

procedure TMonitorForm.LogLine(const AType, ADetail: string);
var
  SList: TStringList;
  Path, Tmp: string;
begin
  Path := ExtractFilePath(Application.ExeName) + LOG_NAME;
  Tmp := StringReplace(ADetail, #13#10, ' | ', [rfReplaceAll]);
  Tmp := StringReplace(Tmp, #13, ' ', [rfReplaceAll]);
  Tmp := StringReplace(Tmp, #10, ' ', [rfReplaceAll]);
  SList := TStringList.Create;
  try
    if FileExists(Path) then
      SList.LoadFromFile(Path, TEncoding.UTF8);
    if SList.Count = 0 then
      SList.Add('时间,类型,内容');
    SList.Add(FormatDateTime('yyyy-mm-dd hh:nn:ss', Now) + ',' + AType + ',' + Tmp);
    SList.SaveToFile(Path, TEncoding.UTF8);
  finally
    SList.Free;
  end;
end;

procedure TMonitorForm.LogSnapshotLine;
begin
  LogLine('快照', Format('CPU %.1f%%, 温度 %s, 内存 %.1f%%, 读 %s/s, 写 %s/s',
    [FLastSample.CpuTotal, CpuTempText, FLastSample.MemUsedPct,
     ByteSizeStr(FLastReadBPS), ByteSizeStr(FLastWriteBPS)]));
end;

{ ---------------- 进程列表 ---------------- }

procedure TMonitorForm.SortProcView(var A: TArray<TProcessCpuInfo>);
begin
  TArray.Sort<TProcessCpuInfo>(A, TComparer<TProcessCpuInfo>.Construct(
    function(const L, R: TProcessCpuInfo): Integer
    var
      C: Integer;
    begin
      case FProcSortCol of
        1: C := CompareValue(Int64(L.PID), Int64(R.PID));
        2: C := CompareValue(L.CpuPct, R.CpuPct);
        3: C := CompareValue(L.MemBytes, R.MemBytes);
      else
        C := CompareText(L.Name, R.Name);
      end;
      if FProcSortDesc then Result := -C else Result := C;
    end));
end;

procedure TMonitorForm.RefreshProcView;
var
  Arr: TArray<TProcessCpuInfo>;
begin
  Arr := Copy(FLastSample.Procs, 0, Length(FLastSample.Procs));
  SortProcView(Arr);
  FProcsView := Arr;
  LvProcs.Items.Count := Length(FProcsView);
  LvProcs.Invalidate;
end;

procedure TMonitorForm.LvProcsData(Sender: TObject; Item: TListItem);
var
  P: TProcessCpuInfo;
begin
  if (Item.Index < 0) or (Item.Index >= Length(FProcsView)) then Exit;
  P := FProcsView[Item.Index];
  Item.Caption := P.Name;
  Item.SubItems.Clear;
  Item.SubItems.Add(IntToStr(P.PID));
  Item.SubItems.Add(Format('%.2f', [P.CpuPct]));
  Item.SubItems.Add(ByteSizeStr(P.MemBytes));
end;

procedure TMonitorForm.LvProcsColumnClick(Sender: TObject; Column: TListColumn);
begin
  if Column.Index = FProcSortCol then
    FProcSortDesc := not FProcSortDesc
  else begin
    FProcSortCol := Column.Index;
    FProcSortDesc := Column.Index <> 0;
  end;
  RefreshProcView;
end;

{ ---------------- 绘制 ---------------- }

procedure TMonitorForm.PbOverviewPaint(Sender: TObject);
var
  C: TCanvas;
  W, H, SecH, I, y, cw, bx, bh, usedPctW: Integer;
  MemPct, UsedPct: Double;
  Bar: TRect;
  D: TDriveInfo;
  s, Io: string;
begin
  C := PbOverview.Canvas;
  W := PbOverview.ClientWidth;
  H := PbOverview.ClientHeight;
  C.Brush.Style := bsSolid;
  C.Brush.Color := clWindow;
  C.FillRect(Rect(0, 0, W, H));
  if not FHasSample then Exit;

  SecH := H div 3;
  MemPct := FLastSample.MemUsedPct;

  { ---- CPU ---- }
  C.Font.Size := 14;
  C.Font.Style := [fsBold];
  C.Font.Color := clWindowText;
  C.Brush.Style := bsClear;
  C.TextOut(16, 8, Format('CPU   %.1f%%', [FLastSample.CpuTotal]));
  s := '温度 ' + CpuTempText + '    核心数 ' + IntToStr(FLastSample.CoreCount);
  C.Font.Size := 9;
  C.Font.Style := [];
  C.TextOut(W - 16 - C.TextWidth(s), 16, s);

  Bar := Rect(16, 40, W - 16, 62);
  DrawGaugeBar(C, Bar, FLastSample.CpuTotal, GaugeColor(FLastSample.CpuTotal), '');

  // 每核心迷你柱状条
  if FLastSample.CoreCount > 0 then begin
    y := 70;
    bh := 30;
    cw := (W - 32 - (FLastSample.CoreCount - 1) * 2) div FLastSample.CoreCount;
    for I := 0 to FLastSample.CoreCount - 1 do begin
      bx := 16 + I * (cw + 2);
      bh := 0;
      usedPctW := Round(30 * EnsureRange(FLastSample.CpuPerCore[I], 0, 100) / 100);
      C.Brush.Style := bsSolid;
      C.Brush.Color := RGB(233, 236, 239);
      C.FillRect(Rect(bx, y, bx + cw, y + 30));
      C.Brush.Color := GaugeColor(FLastSample.CpuPerCore[I]);
      C.FillRect(Rect(bx, y + 30 - usedPctW, bx + cw, y + 30));
    end;
    C.Brush.Color := RGB(198, 203, 208);
    C.FrameRect(Rect(16, 70, W - 16, 100));
  end;

  { ---- 内存 ---- }
  y := SecH;
  C.Font.Size := 14;
  C.Font.Style := [fsBold];
  C.Font.Color := clWindowText;
  C.Brush.Style := bsClear;
  C.TextOut(16, y + 8, Format('内存   %.1f%%   （%s / %s）',
    [MemPct, ByteSizeStr(FLastSample.MemUsed), ByteSizeStr(FLastSample.MemTotal)]));
  C.Font.Size := 9;
  C.Font.Style := [];
  C.TextOut(16, y + 34, Format('可用 %s    提交 %s / %s    内核：分页 %s / 非分页 %s',
    [ByteSizeStr(FLastSample.MemAvail), ByteSizeStr(FLastSample.CommitTotal),
     ByteSizeStr(FLastSample.CommitLimit), ByteSizeStr(FLastSample.KernelPaged),
     ByteSizeStr(FLastSample.KernelNonPaged)]));
  Bar := Rect(16, y + 54, W - 16, y + 76);
  DrawGaugeBar(C, Bar, MemPct, GaugeColor(MemPct), '');

  { ---- 磁盘 ---- }
  y := SecH * 2;
  C.Font.Size := 12;
  C.Font.Style := [fsBold];
  C.Font.Color := clWindowText;
  C.Brush.Style := bsClear;
  C.TextOut(16, y + 8, '磁盘');
  Io := Format('合计读 %s/s   写 %s/s', [ByteSizeStr(FLastReadBPS), ByteSizeStr(FLastWriteBPS)]);
  C.Font.Size := 9;
  C.Font.Style := [];
  C.TextOut(W - 16 - C.TextWidth(Io), y + 12, Io);
  y := y + 34;
  for I := 0 to High(FLastSample.Drives) do begin
    D := FLastSample.Drives[I];
    if (D.DriveType <> DRIVE_FIXED) and (D.DriveType <> DRIVE_REMOVABLE) then Continue;
    if y + 22 > H - 4 then Break;
    C.Font.Style := [fsBold];
    C.Font.Color := clWindowText;
    C.TextOut(16, y, D.Letter);
    C.Font.Style := [];
    Bar := Rect(56, y + 2, 236, y + 16);
    if D.TotalBytes > 0 then begin
      UsedPct := (D.TotalBytes - D.FreeBytes) / D.TotalBytes * 100;
      DrawGaugeBar(C, Bar, UsedPct, GaugeColor(UsedPct), '');
      s := Format('已用 %s / %s（%.1f%%）', [ByteSizeStr(D.TotalBytes - D.FreeBytes),
        ByteSizeStr(D.TotalBytes), UsedPct]);
    end else
      s := '无法读取容量';
    C.Font.Color := clWindowText;
    C.TextOut(246, y, s);
    if D.IoValid then
      Io := Format('读 %s/s  写 %s/s  忙 %.0f%%', [ByteSizeStr(D.ReadBPS), ByteSizeStr(D.WriteBPS), D.BusyPct])
    else
      Io := 'IO 数据不可用';
    C.TextOut(W - 16 - C.TextWidth(Io), y, Io);
    y := y + 22;
  end;
end;

procedure TMonitorForm.PbCpuChartPaint(Sender: TObject);
var
  Series: TArray<TSeriesDef>;
  Header: string;
begin
  SetLength(Series, 1);
  Series[0].Data := FCpuHist.ToArray;
  Series[0].Color := RGB(26, 132, 222);
  Series[0].Title := 'CPU';
  if FHasSample then
    Header := Format('CPU 总使用率：%.1f%%    温度：%s    核心数：%d    历史点数：%d    （与任务管理器同口径：含睿频加权与 DPC/中断）',
      [FLastSample.CpuTotal, CpuTempText, FLastSample.CoreCount, FCpuHist.Count])
  else
    Header := 'CPU 总使用率';
  DrawLineChart(PbCpuChart.Canvas, PbCpuChart.ClientRect, Series, 100, FMaxPoints,
    '%.0f%%', Header);
end;

procedure TMonitorForm.PbCpuCoresPaint(Sender: TObject);
var
  C: TCanvas;
  W, H, I, n, bh, y, BarL, BarR: Integer;
  v: Double;
  txt: string;
begin
  C := PbCpuCores.Canvas;
  W := PbCpuCores.ClientWidth;
  H := PbCpuCores.ClientHeight;
  C.Brush.Style := bsSolid;
  C.Brush.Color := clWindow;
  C.FillRect(Rect(0, 0, W, H));
  if not FHasSample then Exit;
  n := FLastSample.CoreCount;
  if n = 0 then Exit;

  bh := Min(24, (H - 8) div n);
  if bh < 4 then bh := 4;
  BarL := 80;
  BarR := W - 70;
  C.Font.Size := 9;
  for I := 0 to n - 1 do begin
    y := 4 + I * bh;
    v := EnsureRange(FLastSample.CpuPerCore[I], 0, 100);
    txt := Format('%.0f%%', [v]);
    C.Brush.Style := bsClear;
    C.Font.Color := clWindowText;
    C.TextOut(8, y + (bh - C.TextHeight(txt)) div 2, Format('Core %d', [I]));
    DrawGaugeBar(C, Rect(BarL, y + 2, BarR, y + bh - 2), v, GaugeColor(v), '');
    C.TextOut(BarR + 8, y + (bh - C.TextHeight(txt)) div 2, txt);
  end;
end;

procedure TMonitorForm.PbMemChartPaint(Sender: TObject);
var
  Series: TArray<TSeriesDef>;
  Header: string;
begin
  SetLength(Series, 1);
  Series[0].Data := FMemHist.ToArray;
  Series[0].Color := RGB(140, 80, 200);
  Series[0].Title := 'Mem';
  if FHasSample then
    Header := Format('物理内存使用率：%.1f%%   （已用 %s / 共 %s）',
      [FLastSample.MemUsedPct, ByteSizeStr(FLastSample.MemUsed), ByteSizeStr(FLastSample.MemTotal)])
  else
    Header := '物理内存使用率';
  DrawLineChart(PbMemChart.Canvas, PbMemChart.ClientRect, Series, 100, FMaxPoints,
    '%.0f%%', Header);
end;

procedure TMonitorForm.PbMemBarPaint(Sender: TObject);
var
  C: TCanvas;
  W, H, y: Integer;
  MemPct, CommitPct: Double;
  CommitLimit: Int64;
begin
  C := PbMemBar.Canvas;
  W := PbMemBar.ClientWidth;
  H := PbMemBar.ClientHeight;
  C.Brush.Style := bsSolid;
  C.Brush.Color := clWindow;
  C.FillRect(Rect(0, 0, W, H));
  if not FHasSample then Exit;

  MemPct := FLastSample.MemUsedPct;
  y := 12;
  DrawGaugeBar(C, Rect(16, y, W - 16, y + 28), MemPct, GaugeColor(MemPct),
    Format('物理内存  已用 %.1f%%', [MemPct]));
  C.Brush.Style := bsClear;
  C.Font.Size := 9;
  C.Font.Color := clWindowText;
  C.TextOut(16, y + 34, Format('已用 %s    可用 %s    总量 %s',
    [ByteSizeStr(FLastSample.MemUsed), ByteSizeStr(FLastSample.MemAvail),
     ByteSizeStr(FLastSample.MemTotal)]));

  y := y + 62;
  CommitLimit := FLastSample.CommitLimit;
  if CommitLimit > 0 then
    CommitPct := FLastSample.CommitTotal / CommitLimit * 100
  else
    CommitPct := 0;
  DrawGaugeBar(C, Rect(16, y, W - 16, y + 28), CommitPct, RGB(140, 80, 200),
    Format('提交内存（物理+页面文件）  %.1f%%', [CommitPct]));
  C.Brush.Style := bsClear;
  C.Font.Color := clWindowText;
  C.TextOut(16, y + 34, Format('已提交 %s    上限 %s    系统缓存 %s',
    [ByteSizeStr(FLastSample.CommitTotal), ByteSizeStr(FLastSample.CommitLimit),
     ByteSizeStr(FLastSample.SystemCache)]));

  y := y + 62;
  C.Font.Color := clWindowText;
  C.TextOut(16, y, Format('内核内存：分页 %s    非分页 %s',
    [ByteSizeStr(FLastSample.KernelPaged), ByteSizeStr(FLastSample.KernelNonPaged)]));
  C.TextOut(16, y + 22, Format('系统统计：进程 %d 个    线程 %d 个    句柄 %d 个',
    [FLastSample.ProcessCount, FLastSample.ThreadCount, FLastSample.HandleCount]));
end;

procedure TMonitorForm.PbDiskPaint(Sender: TObject);
var
  C: TCanvas;
  W, H, I, y: Integer;
  D: TDriveInfo;
  UsedPct: Double;
  Bar: TRect;
  s, Io, TypeStr: string;
begin
  C := PbDisk.Canvas;
  W := PbDisk.ClientWidth;
  H := PbDisk.ClientHeight;
  C.Brush.Style := bsSolid;
  C.Brush.Color := clWindow;
  C.FillRect(Rect(0, 0, W, H));
  if not FHasSample then Exit;

  // 表头
  C.Font.Size := 10;
  C.Font.Style := [fsBold];
  C.Font.Color := clGrayText;
  C.Brush.Style := bsClear;
  C.TextOut(16, 6, '磁盘');
  C.TextOut(80, 6, '卷标');
  C.TextOut(260, 6, '容量使用');
  C.TextOut(W - 16 - C.TextWidth('读写速度 / 忙闲'), 6, '读写速度 / 忙闲');
  C.Pen.Color := RGB(200, 205, 210);
  C.MoveTo(16, 26);
  C.LineTo(W - 16, 26);

  y := 38;
  C.Font.Size := 9;
  for I := 0 to High(FLastSample.Drives) do begin
    D := FLastSample.Drives[I];
    if (D.DriveType <> DRIVE_FIXED) and (D.DriveType <> DRIVE_REMOVABLE) then Continue;
    if y + 62 > H then Break;

    // 第一行：盘符 + 卷标 + 类型
    case D.DriveType of
      DRIVE_FIXED: TypeStr := '本地磁盘';
      DRIVE_REMOVABLE: TypeStr := '可移动磁盘';
    else
      TypeStr := '未知';
    end;
    C.Font.Style := [fsBold];
    C.Font.Color := clWindowText;
    C.TextOut(16, y, D.Letter);
    C.Font.Style := [];
    if D.VolumeLabel <> '' then
      s := D.VolumeLabel + '  (' + TypeStr + ')'
    else
      s := TypeStr;
    C.TextOut(80, y, s);

    if D.IoValid then
      Io := Format('读 %s/s   写 %s/s   忙 %.0f%%', [ByteSizeStr(D.ReadBPS),
        ByteSizeStr(D.WriteBPS), D.BusyPct])
    else
      Io := 'IO 数据不可用';
    C.TextOut(W - 16 - C.TextWidth(Io), y, Io);

    // 第二行：容量条
    Bar := Rect(260, y + 20, W - 16, y + 38);
    if D.TotalBytes > 0 then begin
      UsedPct := (D.TotalBytes - D.FreeBytes) / D.TotalBytes * 100;
      DrawGaugeBar(C, Bar, UsedPct, GaugeColor(UsedPct), '');
      s := Format('已用 %s / %s（%.1f%%）    剩余 %s', [ByteSizeStr(D.TotalBytes - D.FreeBytes),
        ByteSizeStr(D.TotalBytes), UsedPct, ByteSizeStr(D.FreeBytes)]);
    end else
      s := '无法读取容量';
    C.TextOut(260, y + 42, s);

    y := y + 66;
  end;
end;

end.
