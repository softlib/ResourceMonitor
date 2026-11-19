unit ChartUtils;

{ 图表绘制工具：历史曲线图、仪表条、字节大小格式化 }

interface

uses
  System.SysUtils, System.Math,
  Winapi.Windows,
  Vcl.Graphics;

type
  TSeriesDef = record
    Data: TArray<Double>;
    Color: TColor;
    Title: string;
  end;

function ByteSizeStr(const V: Double): string;
function GaugeColor(Pct: Double): TColor;
procedure DrawGaugeBar(Canvas: TCanvas; const R: TRect; Pct: Double;
  Color: TColor; const Text: string);
procedure DrawLineChart(Canvas: TCanvas; const ARect: TRect;
  const Series: TArray<TSeriesDef>; MaxVal: Double; TotalSlots: Integer;
  const ValueFmt: string; const HeaderText: string);

implementation

function ByteSizeStr(const V: Double): string;
const
  Units: array[0..4] of string = ('B', 'KB', 'MB', 'GB', 'TB');
var
  V2: Double;
  U: Integer;
begin
  V2 := Abs(V);
  U := 0;
  while (V2 >= 1024) and (U < 4) do begin
    V2 := V2 / 1024;
    Inc(U);
  end;
  if U = 0 then
    Result := Format('%.0f %s', [V2, Units[U]])
  else
    Result := Format('%.1f %s', [V2, Units[U]]);
end;

function GaugeColor(Pct: Double): TColor;
begin
  if Pct >= 90 then
    Result := RGB(219, 68, 55)     // 红色：严重
  else if Pct >= 75 then
    Result := RGB(244, 150, 40)    // 橙色：警告
  else
    Result := RGB(26, 132, 222);   // 蓝色：正常
end;

procedure DrawGaugeBar(Canvas: TCanvas; const R: TRect; Pct: Double;
  Color: TColor; const Text: string);
var
  FillR: TRect;
begin
  if R.Width <= 0 then Exit;
  with Canvas do begin
    Brush.Style := bsSolid;
    Brush.Color := RGB(233, 236, 239);
    FillRect(R);
    FillR := R;
    FillR.Right := R.Left + Round(R.Width * EnsureRange(Pct, 0, 100) / 100);
    Brush.Color := Color;
    FillRect(FillR);
    Brush.Color := RGB(198, 203, 208);
    FrameRect(R);
    if Text <> '' then begin
      Brush.Style := bsClear;
      Font.Color := clWindowText;
      TextOut(R.Left + (R.Width - TextWidth(Text)) div 2,
        R.Top + (R.Height - TextHeight(Text)) div 2, Text);
      Brush.Style := bsSolid;
    end;
  end;
end;

procedure DrawLineChart(Canvas: TCanvas; const ARect: TRect;
  const Series: TArray<TSeriesDef>; MaxVal: Double; TotalSlots: Integer;
  const ValueFmt: string; const HeaderText: string);
var
  I: Integer;
  Plot: TRect;
  GridY, X, Y: Integer;
  S: TSeriesDef;
  N: Integer;
begin
  if MaxVal <= 0 then MaxVal := 100;
  Plot := ARect;
  Plot.Left := ARect.Left + 56;
  Plot.Right := ARect.Right - 10;
  Plot.Top := ARect.Top + 32;
  Plot.Bottom := ARect.Bottom - 22;

  with Canvas do begin
    Brush.Style := bsSolid;
    Brush.Color := clWindow;
    FillRect(ARect);

    // 网格与纵轴刻度
    Pen.Color := RGB(224, 227, 230);
    Pen.Width := 1;
    Brush.Style := bsClear;
    Font.Size := 8;
    Font.Color := clGrayText;
    for I := 0 to 4 do begin
      GridY := Plot.Top + Round(Plot.Height * I / 4);
      MoveTo(Plot.Left, GridY);
      LineTo(Plot.Right, GridY);
      TextOut(ARect.Left + 4, GridY - 7, Format(ValueFmt, [MaxVal * (4 - I) / 4]));
    end;

    // 标题
    Font.Size := 10;
    Font.Style := [fsBold];
    Font.Color := clWindowText;
    TextOut(ARect.Left + 4, ARect.Top + 6, HeaderText);
    Font.Style := [];

    // 数据曲线（最新数据在右侧）
    for S in Series do begin
      N := Length(S.Data);
      if N < 2 then Continue;
      Pen.Color := S.Color;
      Pen.Width := 2;
      for I := 0 to N - 1 do begin
        X := Plot.Right - Round((N - 1 - I) * Plot.Width / Max(1, TotalSlots - 1));
        if X < Plot.Left then X := Plot.Left;
        Y := Plot.Bottom - Round(EnsureRange(S.Data[I], 0, MaxVal) / MaxVal * Plot.Height);
        if I = 0 then MoveTo(X, Y) else LineTo(X, Y);
      end;
    end;
  end;
end;

end.
