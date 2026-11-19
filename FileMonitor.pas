unit FileMonitor;

{ 基于 Winapi.ShlObj 的外壳变更通知（Shell Change Notification）文件监控单元

  核心机制：
  - SHChangeNotifyRegister 为每个待监控目录注册 PIDL（递归），系统把变更消息发给隐藏窗口
  - SHChangeNotifyDeregister 注销
  - 使用 SHCNRF_NewDelivery 共享内存投递：wParam/lParam 传给 SHChangeNotification_Lock
    取出事件 ID 与两个 PIDL，再经 SHGetPathFromIDList 转成路径
    （Lock 等函数按微软 SDK 的正确签名自行声明，规避旧版 RTL 声明缺陷）

  可捕获：文件/文件夹的创建、删除、重命名/移动、内容更新、属性变化、磁盘增减等 }

interface

uses
  Winapi.Windows, Winapi.Messages, Winapi.ShlObj,
  System.Classes, System.SysUtils,
  Vcl.Controls;

const
  WM_SHELL_CHANGE = WM_USER + $1200;

 const
   WM_SHNOTIFY = $401;

type
  // 简化后的操作类型
  TFileOp = (foCreate, foDelete, foRename, foModify, foOther);

  TFileChangeEvent = record
    Time: TDateTime;
    Op: TFileOp;
    OpText: string;
    Path1: string;      // 主路径（重命名时是旧路径）
    Path2: string;      // 重命名时是新路径
    RawEvent: LongInt;  // 原始 SHCNE_* 事件码
  end;


  TOnFileChange = procedure(Sender: TObject; const AEvent: TFileChangeEvent) of object;

  TShellFileMonitor = class
  private
    FWnd: HWND;
    FNotifyIDs: array of ULONG;   // 每个监控目录对应一个注册 ID
    FPidls: array of PItemIDList; // 对应的 PIDL
    FPaths: TStringList;
    FActive: Boolean;
    FOnChange: TOnFileChange;
    FEventFilter: LongInt;
    FExcludeTemp: Boolean;
    procedure WndProc(var Msg: TMessage);
    procedure RebuildRegistration;   //注册
    procedure ClearRegistration;    //反注册
    procedure DoChange(const AEvent: TFileChangeEvent);
    function PathOfPidl(P: PItemIDList): string;
  public
    constructor Create;
    destructor Destroy; override;
    procedure AddPath(const APath: string);
    procedure RemovePath(const APath: string);
    procedure ClearPaths;
    procedure LoadPathsFromFile(const AFileName: string);
    procedure SavePathsToFile(const AFileName: string);
    procedure Start;
    procedure Stop;
    property EventFilter: LongInt read FEventFilter write FEventFilter;
    property ExcludeTemp: Boolean read FExcludeTemp write FExcludeTemp;
    property Active: Boolean read FActive;
    property Paths: TStringList read FPaths;
    property OnChange: TOnFileChange read FOnChange write FOnChange;
  end;


  {}


 type
  PIDLSTRUCT = ^IDLSTRUCT;

  _IDLSTRUCT = record
    pidl: PItemIDList;
    bWatchSubFolders: Integer;
  end;

  IDLSTRUCT = _IDLSTRUCT;

 var
   m_hSHNotify: Integer;
   m_pidlDesktop: PItemIDList;


implementation

uses
   Winapi.ShellAPI, Winapi.ActiveX;

const
  { SHCNRF_* 通知来源标志 }
  SHCNRF_InterruptLevel     = $0001;
  SHCNRF_ShellLevel         = $0002;
  SHCNRF_RecursiveInterrupt = $1000;
  SHCNRF_NewDelivery        = $8000;

  { SHCNE_* 事件码 }
  SHCNE_RENAMEITEM       = $00000001;
  SHCNE_CREATE           = $00000002;
  SHCNE_DELETE           = $00000004;
  SHCNE_MKDIR            = $00000008;
  SHCNE_RMDIR            = $00000010;
  SHCNE_MEDIAINSERTED    = $00000020;
  SHCNE_MEDIAREMOVED     = $00000040;
  SHCNE_DRIVEREMOVED     = $00000080;
  SHCNE_DRIVEADD         = $00000100;
  SHCNE_ATTRIBUTES       = $00000800;
  SHCNE_UPDATEDIR        = $00001000;
  SHCNE_UPDATEITEM       = $00002000;
  SHCNE_RENAMEFOLDER     = $00020000;
  SHCNE_FREESPACE        = $00040000;

type
  TSHChangeNotifyEntryLocal = record
    pidl: PItemIDList;
    fRecursive: BOOL;
  end;
  TShNotifyPidlArray = array[0..1] of PItemIDList;
  PShNotifyPidlArray = ^TShNotifyPidlArray;

{ shell32 导出函数：按微软 SDK 的正确签名声明。
  Winapi.ShlObj 中同名函数在不同 RTL 版本存在参数类型差异（历史 QC#90540），
  这里以独立名称导入，避免冲突并保证跨版本正确。 }
function Shell_ChangeNotifyRegister(hwnd: HWND; fSources: Integer; fEvents: LongInt;
  wMsg: UINT; cEntries: Integer; const pshcne: TSHChangeNotifyEntryLocal): ULONG;
  stdcall; external 'shell32.dll' name 'SHChangeNotifyRegister';
function Shell_ChangeNotifyDeregister(ulID: ULONG): BOOL;
  stdcall; external 'shell32.dll' name 'SHChangeNotifyDeregister';
function Shell_ChangeNotification_Lock(hChange: THandle; dwProcessId: DWORD;
  out ppidl: PShNotifyPidlArray; out plEvent: LongInt): THandle;
  stdcall; external 'shell32.dll' name 'SHChangeNotification_Lock';
function Shell_ChangeNotification_Unlock(hLock: THandle): BOOL;
  stdcall; external 'shell32.dll' name 'SHChangeNotification_Unlock';
function Shell_ILCreateFromPath(pszPath: PWideChar): PItemIDList;
  stdcall; external 'shell32.dll' name 'ILCreateFromPathW';
procedure Shell_ILFree(pidl: PItemIDList);
  stdcall; external 'shell32.dll' name 'ILFree';

constructor TShellFileMonitor.Create;
begin
  inherited Create;
  FPaths := TStringList.Create;
  FPaths.Sorted := True;
  FPaths.Duplicates := dupIgnore;
  FActive := False;
  FExcludeTemp := True;
  FEventFilter := SHCNE_CREATE or SHCNE_DELETE or SHCNE_MKDIR or SHCNE_RMDIR or
    SHCNE_RENAMEITEM or SHCNE_RENAMEFOLDER or SHCNE_UPDATEITEM or
    SHCNE_ATTRIBUTES or SHCNE_DRIVEADD or SHCNE_DRIVEREMOVED;
  FWnd := AllocateHWnd(WndProc);
end;

destructor TShellFileMonitor.Destroy;
begin
  Stop;
  FreeAndNil(FPaths);
  if FWnd <> 0 then begin
    DeallocateHWnd(FWnd);
    FWnd := 0;
  end;
  inherited;
end;

procedure TShellFileMonitor.ClearRegistration;
var
  I: Integer;
begin
  for I := 0 to High(FNotifyIDs) do
    if (FNotifyIDs[I] <> 0) and (FWnd <> 0) then
      Shell_ChangeNotifyDeregister(FNotifyIDs[I]);
  for I := 0 to High(FPidls) do
    if FPidls[I] <> nil then
      Shell_ILFree(FPidls[I]);
  SetLength(FNotifyIDs, 0);
  SetLength(FPidls, 0);


(*
  if Boolean(m_hSHNotify) then
   //取消系统消息监视,同时释放桌面的 Pidl
    if Boolean(SHChangeNotifyDeregister(m_hSHNotify)) then
    begin
  {$R-}
        m_hSHNotify := 0;
        CoTaskMemFree(m_pidlDesktop);
  {$R-}
    end;
  *)

end;

procedure TShellFileMonitor.RebuildRegistration;
var
  I, N: Integer;
  Entry: TSHChangeNotifyEntryLocal;
  P: PItemIDList;
{var
  ps:_SHChangeNotifyEntry; }
begin
  ClearRegistration;

  if (not FActive) or (FPaths.Count = 0) then Exit;

  N := FPaths.Count;
  SetLength(FNotifyIDs, N);
  SetLength(FPidls, N);
  for I := 0 to N - 1 do begin
    FNotifyIDs[I] := 0;
    FPidls[I] := nil;
    P := Shell_ILCreateFromPath(PWideChar(FPaths[I]));
    if P = nil then Continue;
    FPidls[I] := P;
    FillChar(Entry, SizeOf(Entry), 0);
    Entry.pidl := P;
    Entry.fRecursive := True;
    FNotifyIDs[I] := Shell_ChangeNotifyRegister(FWnd,
      SHCNRF_ShellLevel or SHCNRF_InterruptLevel or SHCNRF_RecursiveInterrupt or
      SHCNRF_NewDelivery,
      FEventFilter, WM_SHELL_CHANGE, 1, Entry);
  end; //for i end


 (*
  {$R-}
  if m_hSHNotify = 0 then
  begin
//获取桌面文件夹的 Pidl
    if SHGetSpecialFolderLocation(0, CSIDL_DESKTOP, m_pidlDesktop) <> NOERROR then
        exit;

    if Boolean(m_pidlDesktop) then
    begin
    //  new(ps);
      ps.fRecursive :=true;
      ps.pidl := m_pidlDesktop;
      m_hSHNotify := SHChangeNotifyRegister(FWnd,
        (SHCNF_TYPE or SHCNF_IDLIST), (SHCNE_ALLEVENTS or SHCNE_INTERRUPT)
        , WM_SHNOTIFY, 1, ps);
   //   dispose(ps);
    end
    else
      //如果出现错误就使用 CoTaskMemFree 函数来释放句柄
      CoTaskMemFree(m_pidlDesktop);
  end;
  {$R+}
 *)
end;

procedure TShellFileMonitor.Start;
begin
  if FActive then Exit;
  FActive := True;
  RebuildRegistration;
end;

procedure TShellFileMonitor.Stop;
begin
  ClearRegistration;
  FActive := False;
end;

procedure TShellFileMonitor.AddPath(const APath: string);
var
  P: string;
begin
  P := IncludeTrailingPathDelimiter(ExpandFileName(APath));
  if (P <> '') and DirectoryExists(P) and (FPaths.IndexOf(P) < 0) then begin
    FPaths.Add(P);
    if FActive then RebuildRegistration;
  end;
end;

procedure TShellFileMonitor.RemovePath(const APath: string);
var
  Idx: Integer;
begin
  Idx := FPaths.IndexOf(APath);
  if Idx >= 0 then begin
    FPaths.Delete(Idx);
    if FActive then RebuildRegistration;
  end;
end;

procedure TShellFileMonitor.ClearPaths;
begin
  FPaths.Clear;
  if FActive then RebuildRegistration;
end;

procedure TShellFileMonitor.LoadPathsFromFile(const AFileName: string);
begin
  if FileExists(AFileName) then begin
    FPaths.LoadFromFile(AFileName);
    if FActive then RebuildRegistration;
  end;
end;

procedure TShellFileMonitor.SavePathsToFile(const AFileName: string);
begin
  FPaths.SaveToFile(AFileName);
end;

function TShellFileMonitor.PathOfPidl(P: PItemIDList): string;
var
  Buf: array[0..MAX_PATH] of Char;
begin
  Result := '';
  if P = nil then Exit;
  FillChar(Buf, SizeOf(Buf), 0);
  // 使用 Winapi.ShlObj 提供的 PIDL → 路径转换函数
  if SHGetPathFromIDList(P, Buf) then
    Result := string(Buf);
end;

function IsTempFile(const APath: string): Boolean;
var
  Name: string;
begin
  Name := ExtractFileName(APath);
  Result := (Name <> '') and
    ((Name[Length(Name)] = '~') or
     (SameText(ExtractFileExt(Name), '.tmp')) or
     (Pos('.~lock.', Name) > 0) or
     (SameText(Name, 'thumbs.db')) or
     (SameText(Name, 'desktop.ini')));
end;

procedure TShellFileMonitor.DoChange(const AEvent: TFileChangeEvent);
begin
  if Assigned(FOnChange) then
    FOnChange(Self, AEvent);
end;

procedure TShellFileMonitor.WndProc(var Msg: TMessage);
var
  hLock: THandle;
  Pidls: PShNotifyPidlArray;
  lEvent: LongInt;
  E: TFileChangeEvent;
  Code: LongInt;
  P1, P2: PItemIDList;

  pidlItem: PSHChangeNotifyEntry;
begin

 { if Msg.msg=WM_SHNOTIFY then
  begin
     pidlItem := PSHChangeNotifyEntry(Msg.wParam);

     case Msg.lParam  of
      SHCNE_CREATE:
        MessageBox(0,pchar('file Created: '+slinebreak+PathOfPidl(pidlItem.pidl)),'hi2',0);
      SHCNE_DELETE:
        MessageBox(0,pchar('file Deleted: '+slinebreak+PathOfPidl(pidlItem.pidl)),'hi2',0);
     end;
  end;}


  if (Msg.Msg = WM_SHELL_CHANGE)  then
  begin
    if (Length(FNotifyIDs) = 0) then
    begin
      Msg.Result := 0;
      Exit;
    end;

    hLock := Shell_ChangeNotification_Lock(THandle(Msg.WParam), DWORD(Msg.LParam),
      Pidls, lEvent);
    if hLock <> 0 then
    try
      if (FEventFilter <> 0) and ((lEvent and $7FFFFFFF and FEventFilter) = 0) then
        Exit;
      Code := lEvent and $7FFFFFFF;   // 去掉 SHCNE_INTERRUPT 标志
      P1 := nil;
      P2 := nil;
      if Pidls <> nil then begin
        P1 := Pidls^[0];
        P2 := Pidls^[1];
      end;
      FillChar(E, SizeOf(E), 0);
      E.Time := Now;
      E.RawEvent := Code;
      E.Path1 := PathOfPidl(P1);
      E.Path2 := PathOfPidl(P2);
      if FExcludeTemp and IsTempFile(E.Path1) then Exit;

      case Code of
        SHCNE_CREATE:
          begin E.Op := foCreate; E.OpText := '创建文件'; end;
        SHCNE_MKDIR:
          begin E.Op := foCreate; E.OpText := '创建文件夹'; end;
        SHCNE_DELETE:
          begin E.Op := foDelete; E.OpText := '删除文件'; end;
        SHCNE_RMDIR:
          begin E.Op := foDelete; E.OpText := '删除文件夹'; end;
        SHCNE_RENAMEITEM:
          begin E.Op := foRename; E.OpText := '移动/重命名文件'; end;
        SHCNE_RENAMEFOLDER:
          begin E.Op := foRename; E.OpText := '移动/重命名文件夹'; end;
        SHCNE_UPDATEITEM:
          begin E.Op := foModify; E.OpText := '内容修改'; end;
        SHCNE_UPDATEDIR:
          begin E.Op := foModify; E.OpText := '目录内容更新'; end;
        SHCNE_ATTRIBUTES:
          begin E.Op := foModify; E.OpText := '属性变化'; end;
        SHCNE_DRIVEADD, SHCNE_DRIVEREMOVED, SHCNE_MEDIAINSERTED, SHCNE_MEDIAREMOVED:
          begin E.Op := foOther; E.OpText := '磁盘/介质变化'; end;
      else
        E.Op := foOther;
        E.OpText := '其他外壳事件';
      end;

      DoChange(E);
    finally
      Shell_ChangeNotification_Unlock(hLock);
    end;
    Msg.Result := 0;
  end else
    Msg.Result := DefWindowProc(FWnd, Msg.Msg, Msg.WParam, Msg.LParam);
end;

end.
