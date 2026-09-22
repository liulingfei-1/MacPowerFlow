# 数据来源、权限与卸载

[返回 README](../README.md)

## 数据来源

| 数据 | 当前实现 |
| --- | --- |
| 电池状态、容量、循环和剩余时间 | IOPowerSources 与 IOKit `AppleSmartBattery` 属性 |
| 输入、整机负载和电池功率 | 可用的同源 `PowerTelemetryData`；备用来源为 SMC `PDTR` / `PSTR` 与带符号的电池电压 × 电流 |
| 充电器档位 | `AdapterDetails` 的协商规格和 PD 档位列表；与实时输入分开 |
| CPU/GPU/ANE/DRAM 等功耗 | IOReport 能量计数器的连续相邻差值，按实际间隔换算 |
| 温度与风扇 | 已核对含义的 AppleSMC 只读键；部分温度有其他读取路径 |
| 集群频率、活跃率、内存带宽 | IOReport 中可用的 CPU/GPU/AMC/PMP 通道，按数据类型与单位处理 |
| 增强采样 | root helper 以固定参数运行系统 `/usr/bin/powermetrics`，解析流式 plist |
| 进程 CPU 与内存 | 原生进程累计计数差分和 RSS；处理时间单位、PID 复用及计数重置 |
| 进程 GPU 活动 | 可用的 AGX `AppUsage` 累计 GPU 时间差值，显示 ms/s，不推算瓦数 |
| 内存与 Swap | Mach VM 统计及 sysctl，采用本机实际页大小 |
| 网络与磁盘速率 | 物理网卡和物理磁盘的累计字节差值；排除部分虚拟接口与磁盘镜像，减少重复统计 |
| 防休眠原因 | `IOPMCopyAssertionsByProcess` 的有效声明，区分系统睡眠、显示器睡眠和其他活动 |
| 温压与低电量模式 | Foundation `ProcessInfo` |
| 应用自身诊断 | macOS 27 的 MetricKit / StateReporting；仅保存筛选后的本地报告 |

IOReport 和 AppleSMC 包含私有、未文档化接口。通道存在并不保证每一帧都有有效读数，macOS 更新也可能改变可用性。CPU/GPU 等能量模型读数不应当作跨设备的绝对精度基准。

## 供电与历史的处理

电池功率保留符号，正值表示充入，负值表示向系统供电。优先使用可用且内部一致的同源遥测；遥测计数和值长期未变化时会停止使用，只有稳定瓦数、没有更新计数时不据此断言过期。

备用来源中，已读到的输入和整机负载保留原值，可信电池电流也保留原符号。不同来源不完全闭合时显示差额；只有缺少输入或负载其中一条时才推导缺失值。流图的预算调整不覆盖历史中的原始数据。

历史区分瞬时功率和区间平均功率。前者对相邻有效点做梯形积分，后者按实际窗口积分；来源切换、过期、缺失、睡眠和过大间隔会断开。首次读取但尚未确认新鲜的遥测可供查看，不冒充新的测量时段累计 Wh。

CPU/GPU 记录有独立来源、质量和时间窗口，不借用整机时间窗。JSON 与 CSV 保留这些字段。最多保存最近 24 小时和 20,000 点，达到任一限制即淘汰较早数据；已完成任务最多 100 个。

## 增强服务与权限

主程序和标准采样以当前用户身份运行。用户主动启用或更新增强采样时，系统授权安装以下固定文件。

- `/Library/PrivilegedHelperTools/com.llf.MacPowerFlow.PrivilegedHelper`
- `/Library/LaunchDaemons/com.llf.MacPowerFlow.PrivilegedHelper.plist`
- `/Library/Application Support/com.llf.MacPowerFlow/helper-config.plist`

helper 只开放协议版本、开始采样和停止采样三个 XPC 操作，不接受任意命令、执行路径或参数。客户端受到用户 ID 与精确代码签名要求约束，主程序也校验 helper 的签名。

安装前，已验签的 helper 和安装器先被复制到固定的 root 所有暂存路径，再校验身份后执行。安装流程不修改 `sudoers`，应用不读取或保存管理员密码。

退出应用会停止当前增强采样流，保留服务注册。自动连接失败不会触发安装授权。当前 ad-hoc 构建的精确签名会随版本或重新编译变化，因此更新后可能需要再次主动授权。

应用不需要辅助功能、屏幕录制或完全磁盘访问权限。本地通知仅在用户开启对应功能后申请权限。采样和诊断不上传；导出及公开截图前，应自行检查是否含有不希望公开的进程名称或其他信息。

## 完整卸载

先退出 MacPowerFlow。如果只使用标准采样，把应用移到废纸篓即可；Homebrew 用户也可以运行 `brew uninstall --cask macpowerflow`。

如果曾安装增强服务，以下命令会卸载并移除它的固定系统文件。它们不删除其他软件的服务，也不删除你的历史记录。

```bash
sudo launchctl bootout system/com.llf.MacPowerFlow.PrivilegedHelper 2>/dev/null || true
sudo rm -f /Library/PrivilegedHelperTools/com.llf.MacPowerFlow.PrivilegedHelper
sudo rm -f /Library/PrivilegedHelperTools/.com.llf.MacPowerFlow.PrivilegedHelper.staging
sudo rm -f /Library/PrivilegedHelperTools/.com.llf.MacPowerFlow.PrivilegedInstaller.staging
sudo rm -f /Library/LaunchDaemons/com.llf.MacPowerFlow.PrivilegedHelper.plist
sudo rm -f "/Library/Application Support/com.llf.MacPowerFlow/helper-config.plist"
sudo rmdir "/Library/Application Support/com.llf.MacPowerFlow" 2>/dev/null || true
```

如需同时删除历史与自身诊断，可以在 Finder 的“前往文件夹”中输入 `~/Library/Application Support/MacPowerFlow`，确认内容后移到废纸篓。Homebrew 的 `--zap` 也会清理此目录，请在使用前导出需要保留的记录。
