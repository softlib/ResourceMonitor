unit CpuTemp;


{ CPU 温度读取（后台线程 + WMI MSAcpi_ThermalZoneTemperature）
  说明：
  - 数据来自 ACPI 热区（Thermal Zone），通常即 CPU/系统温度；
  - 部分主板/BIOS（尤其台式机、虚拟机）不提供该数据，此时 Available=False；
  - WMI 查询较慢，放在后台线程定时执行，不阻塞 UI。 }

(*
 二、使用PowerShell调用WMI接口获取ACPI热区温度
该方法绕过图形界面，直接通过Windows Management Instrumentation服务查询主板ACPI Thermal Zone传感器原始值，经单位换算后输出摄氏度，完全基于系统内建功能，无需额外组件，但要求OEM厂商在固件中完整实现MSAcpi_ThermalZoneTemperature类。

1、右键点击“开始”按钮，选择“Windows Terminal（管理员）”或“PowerShell（管理员）”。

2、输入以下命令并回车执行：Get-WmiObject -Namespace root/wmi -Class MSAcpi_ThermalZoneTemperature | ForEach-Object {($_.CurrentTemperature - 2732) / 10}。

3、若主板支持该接口，终端将返回一个浮点数值，例如61.8，表示当前CPU所在热区温度约为61.8℃。

4、如命令无输出、报错“无法找到类”或提示“拒绝访问”，说明当前设备未启用或不支持该ACPI热区接口。

*)

(*
三、使用Windows性能监视器（PerfMon）配置WMI温度计数器
性能监视器是Windows内置的系统级诊断工具，虽不直接提供温度图表，但可通过手动添加WMI数据源实现对ACPI热区温度的周期性采集与可视化记录，适合需要时间序列数据用于分析的场景。

1、按Win + R组合键打开“运行”对话框，输入perfmon并回车。

2、在左侧树形菜单中展开“性能监视器”，右键点击“数据收集器集”，选择“用户定义” → “新建” → “数据收集器集”。

3、在向导中输入名称，选择“创建手动数据收集器集”，点击“下一步”。

4、点击“添加”按钮，在“性能计数器”类别中选择“Windows Management Instrumentation (WMI)”，再点击“添加”。

5、在WMI查询字段中输入：SELECT CurrentTemperature FROM MSAcpi_ThermalZoneTemperature，设置采样间隔（如30秒），完成配置。

*)

(*
四、通过BIOS/UEFI固件界面读取瞬时CPU封装温度
该方法完全脱离操作系统运行环境，由UEFI固件直连主板传感器获取原始采样值，数据未经驱动层处理，可信度高，适用于开机阶段快速验证散热基础状态，但仅提供单次静态读数，无法反映负载过程中的温升变化。

1、点击“开始”按钮，按住键盘上Shift键的同时选择“重启”选项。

2、电脑重启后进入“高级启动”菜单，依次选择“疑难解答” → “高级选项” → “UEFI固件设置”。

3、点击“重启”，系统将自动进入UEFI界面。

4、使用方向键导航至“Hardware Monitor”、“PC Health”、“Status”或“Main”等标签页。

5、在该页面中查找标有“CPU Temperature”、“Core Temp”或“CPU Die Temp”的条目，其后显示的数字即为当前瞬时温度（单位：℃）。

*)

interface

uses
  winapi.windows,System.Classes, System.SysUtils, System.SyncObjs;

type
  TThermalThread = class(TThread)
  private
    FLock: TRTLCriticalSection;
    FTempC: Double;
    FAvailable: Boolean;
    FStatusText: string;
    FIntervalMs: Integer;
    FStopEvent: TEvent;
    procedure QueryTemperature;
    function ReadWmiTemperature(out TempC: Double; out ErrMsg: string): Boolean;
  protected
    procedure Execute; override;
  public
    constructor Create(AIntervalMs: Integer = 5000);
    destructor Destroy; override;
    procedure Stop;
    function GetTemperature(out TempC: Double; out StatusText: string): Boolean;
  end;

implementation

uses
  Winapi.ActiveX,
  System.Variants, System.Win.ComObj;

constructor TThermalThread.Create(AIntervalMs: Integer);
begin
  inherited Create(True);   // 挂起创建，由调用方 Start
  FreeOnTerminate := False;
  FIntervalMs := AIntervalMs;
  if FIntervalMs < 1000 then FIntervalMs := 1000;
  InitializeCriticalSection(FLock);
  FStopEvent := TEvent.Create(nil, True, False, '');
  FAvailable := False;
  FTempC := 0;
  FStatusText := '正在读取 CPU 温度…';
end;

destructor TThermalThread.Destroy;
begin
  Stop;
  FStopEvent.Free;
  DeleteCriticalSection(FLock);
  inherited;
end;

procedure TThermalThread.Stop;
begin
  if FStopEvent <> nil then
    FStopEvent.SetEvent;
  Terminate;
  if ThreadID <> 0 then
    WaitFor;
end;

function TThermalThread.ReadWmiTemperature(out TempC: Double;
  out ErrMsg: string): Boolean;
var
  Locator, Services, ObjSet, Item: OleVariant;
  EnumVar: IEnumVariant;
  V: OleVariant;
  Fetched: Cardinal;
  Raw, MaxRaw: Double;
begin
  Result := False;
  TempC := 0;
  ErrMsg := '';
  MaxRaw := 0;
  try
    Locator := CreateOleObject('WbemScripting.SWbemLocator');
    Services := Locator.ConnectServer('.', 'root\WMI');
    ObjSet := Services.ExecQuery(
      'SELECT CurrentTemperature FROM MSAcpi_ThermalZoneTemperature');
    EnumVar := IUnknown(ObjSet._NewEnum) as IEnumVariant;
    // 遍历所有热区，取最高温度（多个热区时通常 CPU 最热）
    while EnumVar.Next(1, V, Fetched) = S_OK do begin
      Item := V;
      Raw := Item.CurrentTemperature;   // 单位：开尔文的十分之一
      if (Raw > MaxRaw) and (Raw > 2000) and (Raw < 5000) then
        MaxRaw := Raw;
    end;
    if MaxRaw > 0 then begin
      TempC := MaxRaw / 10.0 - 273.15;  // 转摄氏度
      Result := True;
    end else
      ErrMsg := 'WMI 未提供有效的热区温度数据';
  except
    on E: Exception do
      ErrMsg := E.Message;
  end;
end;

procedure TThermalThread.QueryTemperature;
var
  T: Double;
  Msg: string;
  Ok: Boolean;
begin
  Ok := ReadWmiTemperature(T, Msg);
  EnterCriticalSection(FLock);
  try
    FTempC := T;
    FAvailable := Ok;
    FStatusText := Msg;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

procedure TThermalThread.Execute;
begin
  CoInitialize(nil);
  try
    QueryTemperature;   // 立即读取一次
    while FStopEvent.WaitFor(FIntervalMs) = wrTimeout do
      QueryTemperature;
  finally
    CoUninitialize;
  end;
end;

function TThermalThread.GetTemperature(out TempC: Double;
  out StatusText: string): Boolean;
begin
  EnterCriticalSection(FLock);
  try
    Result := FAvailable;
    TempC := FTempC;
    StatusText := FStatusText;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

end.
