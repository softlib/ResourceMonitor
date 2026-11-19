object MonitorForm: TMonitorForm
  Left = 180
  Top = 120
  Caption = 'ResourceMonitor'
  ClientHeight = 680
  ClientWidth = 980
  Color = clBtnFace
  DoubleBuffered = True
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -13
  Font.Name = 'Microsoft YaHei UI'
  Font.Style = []
  Position = poScreenCenter
  OnCloseQuery = FormCloseQuery
  OnCreate = FormCreate
  OnDestroy = FormDestroy
  OnResize = FormResize
  TextHeight = 19
  object PageControl1: TPageControl
    Left = 0
    Top = 0
    Width = 980
    Height = 659
    ActivePage = TabOverview
    Align = alClient
    TabOrder = 0
    ExplicitWidth = 976
    ExplicitHeight = 658
    object TabOverview: TTabSheet
      Caption = 'Overview'
    end
    object TabCpu: TTabSheet
      Caption = 'CPU'
    end
    object TabMem: TTabSheet
      Caption = 'Memory'
    end
    object TabDisk: TTabSheet
      Caption = 'Disk'
    end
    object TabProc: TTabSheet
      Caption = 'Process'
    end
    object TabSet: TTabSheet
      Caption = 'Settings'
    end
    object TabFile: TTabSheet
      Caption = 'File Monitor'
    end
  end
  object StatusBar1: TStatusBar
    Left = 0
    Top = 659
    Width = 980
    Height = 21
    Panels = <
      item
        Width = 130
      end
      item
        Width = 110
      end
      item
        Width = 130
      end
      item
        Width = 230
      end
      item
        Width = 110
      end
      item
        Width = 100
      end>
    ExplicitTop = 658
    ExplicitWidth = 976
  end
  object Timer1: TTimer
    OnTimer = Timer1Timer
    Left = 32
    Top = 12
  end
  object TrayIcon1: TTrayIcon
    OnClick = TrayIcon1Click
    Left = 72
    Top = 12
  end
end
