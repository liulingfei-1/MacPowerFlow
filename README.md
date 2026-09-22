# MacPowerFlow

<img src="Design/IconSource.svg" width="96" alt="MacPowerFlow 图标">

**在 Mac 菜单栏里，看清电从哪里来、用到了哪里。**

[![Release](https://img.shields.io/github/v/release/liulingfei-1/MacPowerFlow)](https://github.com/liulingfei-1/MacPowerFlow/releases/latest)
[![Platform](https://img.shields.io/badge/macOS-13%2B-blue)](#安装)
[![Apple Silicon](https://img.shields.io/badge/芯片-Apple%20Silicon-black)](#安装)
[![License](https://img.shields.io/github/license/liulingfei-1/MacPowerFlow)](LICENSE)

MacPowerFlow 是一个开源的 Mac 功耗监视器。平时，菜单栏显示电量和整机功耗；点开后，可以看充电器、电池和各个部件之间的能量流向，也能进一步查看温度、内存压力和进程活动。

如果你想知道接着充电器为什么还在掉电，或者想比较一次编译、视频导出前后的功耗变化，可以从这里看起。

[下载最新版](https://github.com/liulingfei-1/MacPowerFlow/releases/latest) · [更新记录](CHANGELOG.md) · [反馈问题](https://github.com/liulingfei-1/MacPowerFlow/issues) · [开发文档](docs/DEVELOPMENT.md)

## 安装

需要 **Apple Silicon Mac（M1 或更新芯片）和 macOS 13 或更高版本**。目前不支持 Intel Mac。没有内置电池的机型会显示外接电源状态；不同机型能读到的传感器有所不同。

### 下载安装包

1. 打开 [Releases](https://github.com/liulingfei-1/MacPowerFlow/releases/latest)，下载 `MacPowerFlow-版本号.zip`。
2. 解压，把 `MacPowerFlow.app` 拖入“应用程序”文件夹。
3. 打开应用，在屏幕顶部菜单栏找到电量和功耗。它不会出现在 Dock 中。

当前安装包尚未经过 Apple 公证。如果 macOS 阻止打开，请先确认文件来自本仓库的 Releases，再按系统提示到“系统设置 → 隐私与安全性”允许打开。

### 使用 Homebrew

```bash
brew tap liulingfei-1/macpowerflow
brew install --cask macpowerflow
```

通过 Homebrew 安装的版本，可以这样更新。

```bash
brew update
brew upgrade --cask macpowerflow
```

## 可以看什么

| 你关心的事 | 应用里能看到的内容 |
| --- | --- |
| 这台 Mac 现在用了多少电 | 整机功耗，以及 CPU、GPU、显示和其他功耗的流向图 |
| 充电器够不够用 | 实时输入、协商的电压和电流档位，以及电池是在充电、闲置还是补充供电 |
| 为什么发热或变慢 | CPU/GPU 温度、风扇转速、内存压力、压缩内存和 Swap |
| 哪些活动比较多 | CPU 占用靠前的进程、GPU 活动时间、磁盘和网络读写速率，以及阻止空闲睡眠的进程 |
| 刚才那项任务用了多少电 | 功耗历史、任务能耗估算、峰值和平均值，可以导出 CSV 或 JSON |

支持的机型还可以显示神经网络引擎（ANE）、内存和媒体引擎等功耗。读不到的项目会标为不可用，不会补出一个看似精确的数字。

## 开始使用

**左键点击菜单栏图标**打开主面板，查看功耗流向和硬件读数。展开“诊断与历史”，可以看到充电详情、内存与进程活动，以及历史曲线。

想记录一次任务，可以在“功耗历史”里填一个名称，比如“导出视频”，点击“开始记录”。完成任务后点击“结束任务记录”，再查看累计能耗。W 表示功率，Wh 表示一段时间内消耗的能量。

**右键点击菜单栏图标**可以立即刷新、设置“登录时启动”、启用增强采样或退出应用。如果登录启动需要额外批准，菜单会提示你到系统设置中处理。

“持续异常时通知”默认关闭。手动开启后，应用会申请通知权限。高功耗、高温、低电量或接电时电池补电持续 30 秒才提醒，同类提醒至少间隔 10 分钟。

## 标准采样和增强采样

**直接打开就能使用标准采样，无需管理员密码。** 功耗、充电诊断、历史和活动详情中可用的数据都会正常显示。

增强采样通过 macOS 的 `powermetrics` 补充 CPU、GPU、ANE 等读数。需要时，右键选择“启用或更新增强采样…”，在系统对话框里完成一次管理员授权。

同一个构建安装好增强服务后，日常启动会直接连接。更换版本或重新编译后，可能需要主动授权更新一次。自动启动不会因为连接超时反复弹出密码框；服务不可用时，应用继续使用标准采样。

## 怎样理解这些数字

这些读数适合观察同一台 Mac 的负载变化，也能帮助排查充电和耗电问题。CPU/GPU 等功耗包含 Apple 能量模型的估算，**不能当作经过校准的功率计读数，也不适合直接比较不同机型的能效**。

- 充电器标称或协商的 100W 是供电上限，当前输入可能只有十几瓦。外设的分配额度也不等于实际耗电。
- 插着电源仍然可能消耗电池。负载超过电源能提供的功率时，电池会一起给电脑供电。
- “其他”是未分到主图部件的剩余功耗。没有独立传感器的数据不会按固定比例分给无线网络、风扇等设备。
- 不同来源的读数可能不同步。流图有时会按整机预算调整显示，详情和导出保留原始值，并说明调整情况。
- 进程 CPU 百分比和 GPU 活动时间反映忙碌程度，不能换算成该应用的精确瓦数。
- 历史能耗只统计有效采样时段。休眠、缺失或过期数据会留下空白，不计成零功耗，也不补算未知时段。

历史最多保留最近 24 小时、20,000 个采样点和 100 个已完成任务。持续高频采样时，点数上限可能先达到。

## 常见问题

### 某些读数为什么没有显示？

不同芯片和 macOS 版本提供的数据不同，传感器也可能暂时没有更新。“不可用”和真实的 0W 会分别处理。可以先查看“诊断与历史”中的来源与状态；升级系统后仍有异常，欢迎提交 Issue。

### 它自己会不会很耗资源？

主面板打开或记录任务时，硬件数据约每 2 秒更新；后台约每 5 秒更新，低电量模式下后台约每 10 秒更新。进程、GPU、网络和磁盘详情按需采集，后台不持续扫描这些详情。实际开销会随设备和系统变化。

### 数据会上传吗？

采样数据在本机处理，历史和诊断保存在 `~/Library/Application Support/MacPowerFlow`。应用没有遥测上传功能，日常监控无需联网。

macOS 27 上还会接收系统提供的应用自身诊断报告，用于了解 MacPowerFlow 的运行情况。这些报告只保存在本机；尚未收到系统日报时，显示等待是正常的。旧系统仍可使用其他功能。

### 能调风扇或限制充电吗？

当前版本只读数据，不修改风扇转速或充电设置。

### 怎样卸载？

先从右键菜单退出应用，再把它移到废纸篓。Homebrew 用户可以运行 `brew uninstall --cask macpowerflow`。

如果安装过增强采样服务，还需要移除它的系统文件，步骤见 [完整卸载说明](docs/TECHNICAL.md#完整卸载)。普通卸载会保留本地历史，方便以后重新安装。

## 开发与反馈

源码构建需要 Xcode 27 或更新版本，步骤和测试命令见 [开发文档](docs/DEVELOPMENT.md)。想了解采样来源、权限和服务设计，可以看 [技术说明](docs/TECHNICAL.md)。

反馈读数问题时，请附上 Mac 芯片、macOS 和应用版本，以及当时是否接电、是否启用增强采样。若有截图或导出文件，提交前请检查其中的进程名称和其他个人信息。

## 致谢与许可

MacPowerFlow 参考了 [macpow](https://github.com/k06a/macpow)、[MacMonitor](https://github.com/ryyansafar/MacMonitor)、[Powerflow](https://github.com/lzt1008/powerflow)、[WhatBattery](https://github.com/darrylmorley/whatbattery)、[mactop](https://github.com/metaspartan/mactop)、[macmon](https://github.com/vladkens/macmon) 和 [Stats](https://github.com/exelban/stats) 的实现与经验。

项目采用 [MIT License](LICENSE)。第三方版权与许可保留在 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)，也随应用一起分发。
