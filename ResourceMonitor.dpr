program ResourceMonitor;

uses
  Vcl.Forms,
  MainForm in 'MainForm.pas' {MonitorForm},
  Monitor.Core in 'Monitor.Core.pas',
  ChartUtils in 'ChartUtils.pas',
  CpuTemp in 'CpuTemp.pas';

{$R *.res}

begin
  Application.Initialize;
  Application.MainFormOnTaskbar := True;
  Application.Title := '系统资源监控';
  Application.CreateForm(TMonitorForm, MonitorForm);
  Application.Run;
end.
