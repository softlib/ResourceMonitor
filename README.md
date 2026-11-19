# 系统资源监控（ResourceMonitor）

基于 **Delphi 11.3 Alexandria** 开发的 Windows 桌面系统资源实时监控小工具，监控 **CPU、内存、存储磁盘** 三大资源。纯 WinAPI + VCL 实现，**无任何第三方控件依赖**。

## 功能清单

### 1. CPU 监控
- 总体使用率实时曲线（历史可保存 100~3600 个采样点）
- 每核心使用率横向柱状条（最多支持 64 核心）
- 数据来源：`NtQuerySystemInformation(SystemProcessorPerformanceInformation)`，精确且轻量
- **CPU 温度显示**：后台线程通过 WMI（`MSAcpi_ThermalZoneTemperature`）每 5 秒读取一次 ACPI 热区温度，显示在总览区、CPU 页签标题、状态栏、复制到剪贴板和日志快照中；若主板/BIOS 不提供该数据则显示“不可用”，不影响其他功能

### 2. 内存监控
- 物理内存使用率曲线、已用/可用/总量
- 提交内存（物理+页面文件）及上限
- 内核内存（分页/非分页）、系统缓存
- 系统统计：进程数 / 线程数 / 句柄数
- 数据来源：`GlobalMemoryStatusEx` + `GetPerformanceInfo`

### 3. 磁盘监控
- 每个本地/可移动磁盘的容量条：已用 / 剩余 / 总量、卷标
- 每盘实时读写速度（字节/秒）与磁盘忙闲度（%）
- 数据来源：`GetDiskFreeSpaceEx` + `IOCTL_DISK_PERFORMANCE`（DeviceIoControl）

### 4. 进程监控
- 全系统进程列表：进程名、PID、CPU 占用、工作集内存
- 按任意列排序（点击表头），默认按 CPU 降序
- 数据来源：Toolhelp32 快照 + `GetProcessTimes` + `GetProcessMemoryInfo`

### 5. 总览页
- CPU / 内存 / 磁盘三大资源的仪表条 + 迷你核心柱状图一屏呈现

### 6. 托盘功能
- 最小化/关闭窗口自动隐藏到托盘，双击恢复
- 右键菜单：显示主窗口、复制状态到剪贴板、总在最前、开机自启动、退出
- TTrayIcon 气泡通知

### 7. 告警
- CPU 使用率阈值（默认 ≥90%）、内存使用率阈值（默认 ≥90%）、磁盘剩余空间阈值（默认 ≤5GB）
- 触发时：托盘气泡提醒 + 提示音（可关）+ 写入日志，30 秒冷却防止刷屏
- "测试告警提示" 按钮可立即验证

### 8. 日志
- 告警事件日志、每 60 秒资源快照日志（可选）
- 输出为程序目录下 `monitor_log.csv`（UTF-8）

### 9. 设置（INI 持久化）
- 刷新间隔 200~10000ms（默认 1000ms）、历史点数
- 各项阈值、声音提醒、总在最前、启动最小化、关闭到托盘
- 开机自启动（写 HKCU Run 注册键，仅当前用户）
- 配置文件：程序目录下 `ResourceMonitor.ini`

## 编译方法

1. 用 Delphi 11.3（Alexandria）打开 `ResourceMonitor.dproj`（或直接打开 `ResourceMonitor.dpr`，IDE 会自动生成 dproj）。
2. 选择目标平台 Win32 或 Win64，点击 **Build / 编译**。
3. 生成的 `ResourceMonitor.exe` 位于 `Win32\Debug`（或对应配置目录）下，可单文件直接运行，无需安装。

> 源码均为 UTF-8（带 BOM）编码，中文字符串在 IDE 中可正常显示。

## 运行说明

- 普通用户权限即可运行全部功能；以管理员身份运行可显示更多系统进程的 CPU/内存数据。
- 界面各页签：
  - **总览**：三大资源一屏速览
  - **CPU**：总体历史曲线 + 每核心使用率
  - **内存**：使用率曲线 + 物理内存/提交内存/内核内存明细
  - **磁盘**：每盘容量条 + 实时读写速度与忙闲度
  - **进程**：全进程 CPU/内存排行（点表头排序）
  - **设置**：采样、告警阈值、行为、日志配置

## 文件结构

| 文件 | 说明 |
|------|------|
| `ResourceMonitor.dpr` | 工程入口 |
| `ResourceMonitor.dproj` | 工程配置（Delphi 11.3） |
| `MainForm.pas / .dfm` | 主窗体：界面、托盘、告警、日志、设置 |
| `Monitor.Core.pas` | 采样引擎：CPU/内存/磁盘/进程数据采集 |
| `ChartUtils.pas` | 绘图工具：历史曲线、仪表条、字节格式化 |

## 技术要点

- CPU 总使用率通过 PDH 读取 `\Processor Information(_Total)\% Processor Utility`，与 Windows 任务管理器（Win8+）完全同口径：包含睿频频率加权与 DPC/中断时间；每核心曲线基于 `SYSTEM_PROCESSOR_PERFORMANCE_INFORMATION` 并补算 DPC/中断时间。
- 若 PDH 初始化失败（如旧系统），自动回退为经典处理器时间百分比，不影响使用。
- 磁盘 IO 通过 `IOCTL_DISK_PERFORMANCE` 获取累计读写字节数与空闲时间，两次采样做差值计算速率与忙闲度；若系统不支持则显示 "IO 数据不可用" 而不崩溃。
- 历史曲线自绘（TPaintBox），最新数据从右侧滚入；窗体开启双缓冲避免闪烁。
- 进程列表使用 OwnerData 虚拟模式，数百进程下刷新流畅。
