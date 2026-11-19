unit Monitor.Core;

{ 系统资源采样引擎（纯 WinAPI 实现，无第三方依赖）
  - CPU 总体 + 每核心使用率：NtQuerySystemInformation(SystemProcessorPerformanceInformation)
  - 内存 / 提交内存 / 内核内存：GlobalMemoryStatusEx + GetPerformanceInfo
  - 磁盘容量：GetDiskFreeSpaceEx；磁盘 IO 与忙闲：IOCTL_DISK_PERFORMANCE
  - 进程 CPU / 内存：Toolhelp32 快照 + GetProcessTimes + GetProcessMemoryInfo }

interface

uses
  System.SysUtils, System.Classes, System.Math,
  System.Generics.Collections, System.Generics.Defaults,
  Winapi.Windows, Winapi.TlHelp32;

const
  MAX_CORES = 64;
  IOCTL_DISK_PERFORMANCE = $00070020;

type
  TDriveInfo = record
    Letter: string;             // 如 'C:'
    DriveType: Cardinal;
    VolumeLabel: string;
    TotalBytes: Int64;
    FreeBytes: Int64;
    ReadBPS: Double;            // 字节/秒
    WriteBPS: Double;           // 字节/秒
    BusyPct: Double;            // 0..100
    IoValid: Boolean;
  end;

  TProcessCpuInfo = record
    PID: Cardinal;
    Name: string;
    CpuPct: Double;             // 0..100（单进程相对全部核心）
    MemBytes: Int64;            // 工作集
  end;

  TMonitorSample = record
    Time: TDateTime;
    CpuTotal: Double;           // 0..100
    CpuPerCore: array[0..MAX_CORES - 1] of Double;
    CoreCount: Integer;
    MemTotal: Int64;            // 物理内存总量
    MemAvail: Int64;            // 物理内存可用
    CommitTotal: Int64;         // 已提交
    CommitLimit: Int64;         // 提交上限（物理+页面文件）
    KernelPaged: Int64;
    KernelNonPaged: Int64;
    SystemCache: Int64;
    HandleCount: Cardinal;
    ProcessCount: Cardinal;
    ThreadCount: Cardinal;
    Drives: TArray<TDriveInfo>;
    Procs: TArray<TProcessCpuInfo>;  // 已按 CPU 降序

    function MemUsed: Int64;
    function MemUsedPct: Double;
  end;

  TMonitorEngine = class
  public type
    TCpuPrev = record
      Idle: Int64;
      Kernel: Int64;
      User: Int64;
      Dpc: Int64;
      Intr: Int64;
    end;
    TDiskPrev = record
      Letter: Char;
      BytesRead: Int64;
      BytesWritten: Int64;
      IdleTime: Int64;
      QueryTime: Int64;
    end;
    TProcPrev = record
      PID: Cardinal;
      TotalTime: Int64;
    end;
  private
    FCores: Integer;
    FCpuValid: Boolean;
    FCpuPrev: array[0..MAX_CORES - 1] of TCpuPrev;
    FDiskPrev: TArray<TDiskPrev>;
    FProcPrev: TArray<TProcPrev>;
    // PDH：% Processor Utility（任务管理器口径）
    FPdhQuery: THandle;
    FPdhCounter: THandle;
    FPdhOk: Boolean;
    function SampleCpu(var S: TMonitorSample): Boolean;
    procedure SampleMemory(var S: TMonitorSample);
    procedure SampleDrives(var S: TMonitorSample; const IntervalSec: Double);
    procedure SampleDiskIo(const L: Char; var Di: TDriveInfo; const IntervalSec: Double);
    procedure SampleProcesses(var S: TMonitorSample; const IntervalSec: Double);
    function FindDiskPrev(const L: Char): Integer;
    function FindProcPrev(const PID: Cardinal): Integer;
  public
    constructor Create;
    destructor Destroy; override;
    // IntervalSec：与上一次采样间隔的秒数（用于计算速率）
    function Sample(const IntervalSec: Double): TMonitorSample;
    property CoreCount: Integer read FCores;
  end;

implementation

const
  SystemProcessorPerformanceInformation = 8;
  PROCESS_QUERY_LIMITED_INFORMATION = $1000;

type
  TSysPerfInfo = record
    cb: DWORD;
    CommitTotal: NativeUInt;
    CommitLimit: NativeUInt;
    CommitPeak: NativeUInt;
    PhysicalTotal: NativeUInt;
    PhysicalAvailable: NativeUInt;
    SystemCache: NativeUInt;
    KernelTotal: NativeUInt;
    KernelPaged: NativeUInt;
    KernelNonPaged: NativeUInt;
    PageSize: NativeUInt;
    HandleCount: DWORD;
    ProcessCount: DWORD;
    ThreadCount: DWORD;
  end;

  TProcMemCounters = record
    cb: DWORD;
    PageFaultCount: DWORD;
    PeakWorkingSetSize: NativeUInt;
    WorkingSetSize: NativeUInt;
    QuotaPeakPagedPoolUsage: NativeUInt;
    QuotaPagedPoolUsage: NativeUInt;
    QuotaPeakNonPagedPoolUsage: NativeUInt;
    QuotaNonPagedPoolUsage: NativeUInt;
    PagefileUsage: NativeUInt;
    PeakPagefileUsage: NativeUInt;
  end;

  TDisKPerformance = record
    BytesRead: Int64;
    BytesWritten: Int64;
    ReadTime: Int64;
    WriteTime: Int64;
    IdleTime: Int64;
    ReadCount: DWORD;
    WriteCount: DWORD;
    QueueDepth: DWORD;
    SplitCount: DWORD;
    QueryTime: Int64;
    StorageDeviceNumber: DWORD;
    StorageManagerName: array[0..7] of WideChar;
  end;

function NtQuerySystemInformation(SystemInformationClass: Cardinal;
  SystemInformation: Pointer; SystemInformationLength: Cardinal;
  ReturnLength: PCardinal): LongInt; stdcall; external 'ntdll.dll';

function _GetPerformanceInfo(out Info: TSysPerfInfo; cb: DWORD): BOOL; stdcall;
  external 'psapi.dll' name 'GetPerformanceInfo';

function _GetProcessMemoryInfo(hProcess: THandle; var Counters: TProcMemCounters;
  cb: DWORD): BOOL; stdcall; external 'psapi.dll' name 'GetProcessMemoryInfo';

function _GetVolumeInformationW(lpRootPathName: LPCWSTR;
  lpVolumeNameBuffer: LPWSTR; nVolumeNameSize: DWORD;
  lpVolumeSerialNumber: LPDWORD; lpMaximumComponentLength: LPDWORD;
  lpFileSystemFlags: LPDWORD; lpFileSystemNameBuffer: LPWSTR;
  nFileSystemNameSize: DWORD): BOOL; stdcall;
  external 'kernel32.dll' name 'GetVolumeInformationW';

{ PDH：读取与任务管理器一致的 "% Processor Utility"（处理器效用）计数器 }
const
  PDH_FMT_DOUBLE = $00000200;

type
  TPdhFmtCounterValue = record
    CStatus: DWORD;
    case Integer of
      0: (doubleV: Double);
      1: (longV: LongInt);
      2: (largeV: Int64);
  end;

function PdhOpenQueryW(szDataSource: LPCWSTR; dwUserData: NativeUInt;
  var phQuery: THandle): DWORD; stdcall; external 'pdh.dll';
function PdhAddEnglishCounterW(hQuery: THandle; szFullCounterPath: LPCWSTR;
  dwUserData: NativeUInt; var phCounter: THandle): DWORD; stdcall; external 'pdh.dll';
function PdhCollectQueryData(hQuery: THandle): DWORD; stdcall; external 'pdh.dll';
function PdhGetFormattedCounterValue(hCounter: THandle; dwFormat: DWORD;
  lpType: PDWORD; var pValue: TPdhFmtCounterValue): DWORD; stdcall; external 'pdh.dll';
function PdhCloseQuery(hQuery: THandle): DWORD; stdcall; external 'pdh.dll';

{ TMonitorSample }

function TMonitorSample.MemUsed: Int64;
begin
  Result := MemTotal - MemAvail;
  if Result < 0 then Result := 0;
end;

function TMonitorSample.MemUsedPct: Double;
begin
  if MemTotal > 0 then
    Result := MemUsed / MemTotal * 100
  else
    Result := 0;
end;

{ TMonitorEngine }

constructor TMonitorEngine.Create;
var
  SI: TSystemInfo;
begin
  inherited Create;
  GetSystemInfo(SI);
  FCores := SI.dwNumberOfProcessors;
  if FCores < 1 then FCores := 1;
  if FCores > MAX_CORES then FCores := MAX_CORES;
  FCpuValid := False;

  // 初始化 PDH，读取与任务管理器相同的 "% Processor Utility"
  FPdhQuery := 0;
  FPdhCounter := 0;
  FPdhOk := False;
  if PdhOpenQueryW(nil, 0, FPdhQuery) = ERROR_SUCCESS then
    if PdhAddEnglishCounterW(FPdhQuery,
      '\Processor Information(_Total)\% Processor Utility',
      0, FPdhCounter) = ERROR_SUCCESS then begin
      FPdhOk := True;
      PdhCollectQueryData(FPdhQuery);   // 预热一次，后续采样才有效值
    end;
end;

destructor TMonitorEngine.Destroy;
begin
  if FPdhQuery <> 0 then begin
    PdhCloseQuery(FPdhQuery);
    FPdhQuery := 0;
  end;
  inherited;
end;

function TMonitorEngine.Sample(const IntervalSec: Double): TMonitorSample;
begin
  Result := Default(TMonitorSample);
  SampleCpu(Result);
  SampleMemory(Result);
  SampleDrives(Result, IntervalSec);
  SampleProcesses(Result, IntervalSec);
  Result.Time := Now;
end;

function TMonitorEngine.SampleCpu(var S: TMonitorSample): Boolean;
var
  Buf: Pointer;
  Len: Cardinal;
  Entry, I: Integer;
  P: PByte;
  Idle, Kernel, User, DIdle, DK, DU, Tot: Int64;
  DDpc, DIntr: Int64;
  Sum: Double;
  Val: TPdhFmtCounterValue;
begin
  Result := False;
  S.CoreCount := FCores;
  Len := 0;
  GetMem(Buf, FCores * 128);
  try
    if NtQuerySystemInformation(SystemProcessorPerformanceInformation,
      Buf, FCores * 128, @Len) < 0 then
      Exit;
    if Len < Cardinal(FCores * 8) then
      Exit;
    Entry := Len div FCores;
    if Entry < 24 then
      Exit;
    Sum := 0;
    for I := 0 to FCores - 1 do begin
      P := PByte(Buf) + Cardinal(I * Entry);
      Idle := PInt64(P)^;
      Kernel := PInt64(P + 8)^;
      User := PInt64(P + 16)^;
      DDpc := 0;
      DIntr := 0;
      if FCpuValid then begin
        DIdle := Idle - FCpuPrev[I].Idle;
        DK := Kernel - FCpuPrev[I].Kernel;
        DU := User - FCpuPrev[I].User;
        Tot := DK + DU;   // 内核时间包含空闲线程时间
        // Win8+ 上 KernelTime 不含 DPC/中断时间，需单独计入（任务管理器口径）
        if Entry >= 48 then begin
          DDpc := PInt64(P + 24)^ - FCpuPrev[I].Dpc;
          DIntr := PInt64(P + 32)^ - FCpuPrev[I].Intr;
          if DDpc < 0 then DDpc := 0;
          if DIntr < 0 then DIntr := 0;
          Tot := Tot + DDpc + DIntr;
        end;
        if (Tot > 0) and (DIdle >= 0) then
          S.CpuPerCore[I] := EnsureRange((Tot - DIdle) / Tot * 100, 0.0, 100.0)
        else
          S.CpuPerCore[I] := 0;
      end else
        S.CpuPerCore[I] := 0;
      FCpuPrev[I].Idle := Idle;
      FCpuPrev[I].Kernel := Kernel;
      FCpuPrev[I].User := User;
      if Entry >= 48 then begin
        FCpuPrev[I].Dpc := PInt64(P + 24)^;
        FCpuPrev[I].Intr := PInt64(P + 32)^;
      end;
      Sum := Sum + S.CpuPerCore[I];
    end;
    FCpuValid := True;
    S.CpuTotal := Sum / FCores;
    // 总使用率优先采用任务管理器口径：% Processor Utility（含睿频频率加权）
    if FPdhOk and (PdhCollectQueryData(FPdhQuery) = ERROR_SUCCESS) and
       (PdhGetFormattedCounterValue(FPdhCounter, PDH_FMT_DOUBLE, nil, Val) = ERROR_SUCCESS) and
       (Val.CStatus = ERROR_SUCCESS) then
      S.CpuTotal := EnsureRange(Val.doubleV, 0.0, 100.0);
    Result := True;
  finally
    FreeMem(Buf);
  end;
end;

procedure TMonitorEngine.SampleMemory(var S: TMonitorSample);
var
  MS: TMemoryStatusEx;
  PI: TSysPerfInfo;
begin
  ZeroMemory(@MS, SizeOf(MS));
  MS.dwLength := SizeOf(MS);
  if GlobalMemoryStatusEx(MS) then begin
    S.MemTotal := Int64(MS.ullTotalPhys);
    S.MemAvail := Int64(MS.ullAvailPhys);
  end;
  if _GetPerformanceInfo(PI, SizeOf(PI)) then begin
    S.CommitTotal := Int64(PI.CommitTotal) * Int64(PI.PageSize);
    S.CommitLimit := Int64(PI.CommitLimit) * Int64(PI.PageSize);
    S.KernelPaged := Int64(PI.KernelPaged) * Int64(PI.PageSize);
    S.KernelNonPaged := Int64(PI.KernelNonPaged) * Int64(PI.PageSize);
    S.SystemCache := Int64(PI.SystemCache) * Int64(PI.PageSize);
    S.HandleCount := PI.HandleCount;
    S.ProcessCount := PI.ProcessCount;
    S.ThreadCount := PI.ThreadCount;
  end;
end;

procedure TMonitorEngine.SampleDrives(var S: TMonitorSample; const IntervalSec: Double);
var
  Mask: DWORD;
  I, n: Integer;
  Di: TDriveInfo;
  FreeAvail, TotalB: Int64;
  VolName: array[0..MAX_PATH - 1] of Char;
begin
  n := 0;
  SetLength(S.Drives, 26);
  Mask := GetLogicalDrives;
  for I := 0 to 25 do
    if (Mask and (1 shl I)) <> 0 then begin
      FillChar(Di, SizeOf(Di), 0);
      Di.Letter := Chr(Ord('A') + I) + ':';
      Di.DriveType := GetDriveType(PChar(Di.Letter + '\'));
      Di.IoValid := False;
      Di.ReadBPS := 0;
      Di.WriteBPS := 0;
      Di.BusyPct := 0;
      Di.TotalBytes := 0;
      Di.FreeBytes := 0;
      if Di.DriveType in [DRIVE_FIXED, DRIVE_REMOVABLE] then begin
        if GetDiskFreeSpaceEx(PChar(Di.Letter + '\'), FreeAvail, TotalB, nil) then begin
          Di.TotalBytes := TotalB;
          Di.FreeBytes := FreeAvail;
        end;
        if _GetVolumeInformationW(PChar(Di.Letter + '\'), VolName,
          SizeOf(VolName), nil, nil, nil, nil, 0) then
          Di.VolumeLabel := VolName;
        SampleDiskIo(Di.Letter[1], Di, IntervalSec);
      end;
      S.Drives[n] := Di;
      Inc(n);
    end;
  SetLength(S.Drives, n);
end;

function TMonitorEngine.FindDiskPrev(const L: Char): Integer;
var
  I: Integer;
begin
  Result := -1;
  for I := 0 to High(FDiskPrev) do
    if FDiskPrev[I].Letter = L then begin
      Result := I;
      Break;
    end;
end;

procedure TMonitorEngine.SampleDiskIo(const L: Char; var Di: TDriveInfo;
  const IntervalSec: Double);
var
  hDev: THandle;
  br: DWORD;
  dp: TDisKPerformance;
  Idx: Integer;
  DQ, DIo: Int64;
  Elapsed: Double;
  NewPrev: TDiskPrev;
begin
  hDev := CreateFile(PChar('\\.\' + L + ':'), GENERIC_READ,
    FILE_SHARE_READ or FILE_SHARE_WRITE, nil, OPEN_EXISTING, 0, 0);
  if hDev = INVALID_HANDLE_VALUE then
    Exit;
  try
    if not DeviceIoControl(hDev, IOCTL_DISK_PERFORMANCE, nil, 0,
      @dp, SizeOf(dp), br, nil) then
      Exit;
  finally
    CloseHandle(hDev);
  end;

  NewPrev.Letter := L;
  NewPrev.BytesRead := dp.BytesRead;
  NewPrev.BytesWritten := dp.BytesWritten;
  NewPrev.IdleTime := dp.IdleTime;
  NewPrev.QueryTime := dp.QueryTime;

  Idx := FindDiskPrev(L);
  if Idx >= 0 then begin
    DQ := dp.QueryTime - FDiskPrev[Idx].QueryTime;
    DIo := dp.IdleTime - FDiskPrev[Idx].IdleTime;
    if DQ > 0 then begin
      Elapsed := DQ / 10000000.0;   // QueryTime 单位 100ns
      Di.ReadBPS := Max(0, dp.BytesRead - FDiskPrev[Idx].BytesRead) / Elapsed;
      Di.WriteBPS := Max(0, dp.BytesWritten - FDiskPrev[Idx].BytesWritten) / Elapsed;
      if (DIo >= 0) and (DIo <= DQ) then
        Di.BusyPct := EnsureRange(100.0 * (1.0 - DIo / DQ), 0.0, 100.0)
      else if DIo < 0 then
        Di.BusyPct := 100
      else
        Di.BusyPct := 0;
      Di.IoValid := True;
    end;
  end;

  if Idx >= 0 then
    FDiskPrev[Idx] := NewPrev
  else begin
    SetLength(FDiskPrev, Length(FDiskPrev) + 1);
    FDiskPrev[High(FDiskPrev)] := NewPrev;
  end;
end;

function TMonitorEngine.FindProcPrev(const PID: Cardinal): Integer;
var
  I: Integer;
begin
  Result := -1;
  for I := 0 to High(FProcPrev) do
    if FProcPrev[I].PID = PID then begin
      Result := I;
      Break;
    end;
end;

procedure TMonitorEngine.SampleProcesses(var S: TMonitorSample;
  const IntervalSec: Double);
var
  Snap: THandle;
  PE: TProcessEntry32;
  hProc: THandle;
  ftCreate, ftExit, ftKernel, ftUser: TFileTime;
  KT, UT, Total, Mem: Int64;
  pmc: TProcMemCounters;
  Idx, n, nPrev: Integer;
  NewPrev: TArray<TProcPrev>;
begin
  Snap := CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
  if Snap = INVALID_HANDLE_VALUE then
    Exit;
  try
    PE.dwSize := SizeOf(PE);
    if not Process32First(Snap, PE) then
      Exit;
    SetLength(S.Procs, 256);
    SetLength(NewPrev, 256);
    n := 0;
    nPrev := 0;
    repeat
      Total := 0;
      Mem := 0;
      hProc := OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, False, PE.th32ProcessID);
      if hProc <> 0 then
      try
        if GetProcessTimes(hProc, ftCreate, ftExit, ftKernel, ftUser) then begin
          KT := (Int64(ftKernel.dwHighDateTime) shl 32) or ftKernel.dwLowDateTime;
          UT := (Int64(ftUser.dwHighDateTime) shl 32) or ftUser.dwLowDateTime;
          Total := KT + UT;
        end;
        pmc.cb := SizeOf(pmc);
        if _GetProcessMemoryInfo(hProc, pmc, SizeOf(pmc)) then
          Mem := Int64(pmc.WorkingSetSize);
      finally
        CloseHandle(hProc);
      end;

      if n >= Length(S.Procs) then
        SetLength(S.Procs, n + 64);
      if nPrev >= Length(NewPrev) then
        SetLength(NewPrev, nPrev + 64);

      S.Procs[n].PID := PE.th32ProcessID;
      S.Procs[n].Name := PE.szExeFile;
      S.Procs[n].MemBytes := Mem;
      S.Procs[n].CpuPct := 0;
      Idx := FindProcPrev(PE.th32ProcessID);
      if (Idx >= 0) and (Total >= FProcPrev[Idx].TotalTime) and (IntervalSec > 0) then
        S.Procs[n].CpuPct := EnsureRange(
          (Total - FProcPrev[Idx].TotalTime) / (IntervalSec * 10000000.0 * FCores) * 100,
          0.0, 100.0);

      NewPrev[nPrev].PID := PE.th32ProcessID;
      NewPrev[nPrev].TotalTime := Total;
      Inc(n);
      Inc(nPrev);
    until not Process32Next(Snap, PE);

    SetLength(S.Procs, n);
    FProcPrev := Copy(NewPrev, 0, nPrev);

    // 按 CPU 占用降序
    TArray.Sort<TProcessCpuInfo>(S.Procs, TComparer<TProcessCpuInfo>.Construct(
      function(const Left, Right: TProcessCpuInfo): Integer
      begin
        if Left.CpuPct > Right.CpuPct then Result := -1
        else if Left.CpuPct < Right.CpuPct then Result := 1
        else Result := CompareText(Left.Name, Right.Name);
      end));
  finally
    CloseHandle(Snap);
  end;
end;

end.
