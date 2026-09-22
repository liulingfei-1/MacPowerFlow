# 调研与技术取舍

[返回 README](../README.md) · [技术说明](TECHNICAL.md) · [第三方许可](../THIRD_PARTY_NOTICES.md)

这份文档整理 2026 年 9 月 21–22 日的官方资料与开源源码研究，说明 1.7.0 为什么选择这些功能。上游源码能够证明一种实现存在，不能证明它在所有芯片、固件和 macOS 版本上都有效。本次研究没有运行下载的第三方控制工具，也没有试写充电或风扇 SMC 键。

## 优先使用系统已有能力

Apple 的[电源模式说明](https://support.apple.com/en-us/101613)区分低功耗、自动和高功率模式，并说明可以分别设置电池与接电时的行为。低功耗旨在降低能耗，但对同一项工作是否更省电，还要同时比较完成时间与总能耗；系统更新也不意味着所有机型获得高功率模式。

MacPowerFlow 因此提供明确的低功耗手动操作，以固定参数检查支持情况、执行并回读结果，同时保留系统设置入口。它不会按负载自动切换。实现与测试边界见[增强服务与权限](TECHNICAL.md#增强服务与权限)；模拟写入测试不等于真实管理员写入验收。

Apple 的[优化充电与充电上限说明](https://support.apple.com/en-us/102338)指出，Apple 芯片 Mac 在 macOS 26.4 或更新版本可设置 80%–100% 的充电上限。系统可能偶尔充满以保持电量估计准确，也提供临时充满的操作。[电池设置指南](https://support.apple.com/guide/mac-help/change-battery-settings-mchlfc3b7879/mac)列出了相关入口与机型差异。

本项目选择引导使用系统充电功能，避免再运行一套停充控制器。应用没有读取并展示“当前系统上限”的可靠接口，不会把“未充电”直接解释为达到上限。

## 从开源实现中借鉴什么

以下链接固定到实际阅读的源码版本；“借鉴”指设计或采样思路，不代表直接复制整个模块，也不代表附带运行这些工具。

| 项目与许可 | 参考的实现 | 本项目的取舍 |
| --- | --- | --- |
| macmon · MIT | [连续 IOReport 基线与真实时间间隔](https://github.com/vladkens/macmon/blob/6919d7781b6c55a6e3bedff83a210435837e1dfe/src_lib/sources.rs#L924) | 采用相邻累计计数差分，记录真实窗口，唤醒与计数重置后重建基线。保留原始整机功耗，不采用其把整机值抬高至部件合计的纠偏方式。 |
| Stats · MIT | [内存压力、压缩内存与 Swap](https://github.com/exelban/stats/blob/cb141ae6ffe3dbf64b1273a213b79c63451e4912/Modules/RAM/readers.swift#L36)；[风扇读取与模式处理](https://github.com/exelban/stats/blob/a9bf99866eac97d62e8952c058961f6c5e51bc67/SMC/smc.swift#L358) | 补充原生内存信息，按实际页大小换算；读取失败保持未知。风扇增加实际／目标／上下限与模式显示，保留真实 0 RPM，目前只读。 |
| mactop · MIT | [原生 CPU 时间差分](https://github.com/metaspartan/mactop/blob/220df7efeba860f50939b027afc03ee330f209bf/internal/app/processes.go#L84)；[AGX 累计 GPU 时间](https://github.com/metaspartan/mactop/blob/220df7efeba860f50939b027afc03ee330f209bf/internal/app/native_stats.go#L403) | 采用按窗口的进程活动与原生磁盘／网络计数思路，处理退出、PID 复用和计数回退。GPU 活动用时间速率表示，不转换成逐应用瓦数；不加入屏幕捕获式 FPS。 |
| batt · GPL-2.0 | [按能力选择充电控制机制](https://github.com/charlie0129/batt/blob/ee86539e977049d9f15d2641f4545c17eabf679f/pkg/smc/charging.go)；[恢复与边界测试](https://github.com/charlie0129/batt/blob/ee86539e977049d9f15d2641f4545c17eabf679f/pkg/smc/charging_test.go#L31) | 作为新固件存在不同控制机制的研究证据。只凭系统版本不足以选择私有键；mock 测试也不是实机写入证明。本项目未移植其控制实现或测试代码。 |
| bclm · MIT | [兼容性限制](https://github.com/zackelia/bclm/blob/ae2c209614755d81bf5b788513dba1d44280a6f6/README.md#L1)；[架构对应的控制路径](https://github.com/zackelia/bclm/blob/ae2c209614755d81bf5b788513dba1d44280a6f6/Sources/bclm/main.swift#L4) | 上游说明 macOS 15+ 的 entitlement 限制会阻止工作；所读 Apple Silicon 实现只接受 80 或 100。此路线不适合作为新系统的限充基础，本项目不要求关闭 SIP。 |
| AlDente · 当前专有许可 | [当前版本说明](https://github.com/AppHouseKitchen/AlDente-Charge-Limiter/blob/9136e85d111d73d7c8680d379a91780dabb906e2/README.md#L50)；[LICENSE](https://github.com/AppHouseKitchen/AlDente-Charge-Limiter/blob/9136e85d111d73d7c8680d379a91780dabb906e2/LICENSE) | 当前产品已不再开源。历史可见源码可帮助理解“前端退出后要恢复控制权”的需求，不能代表商业最新版，也不能当作可自由复制的开源依赖。 |

另外，[battery 的回差控制](https://github.com/actuallymentor/battery/blob/f4e342f013e5e35d6c55f89a4f06917a118f993a/battery.sh#L943)（MIT）和 [Battery-Toolkit 的结构化能力检查](https://github.com/mhaeuser/Battery-Toolkit/blob/ed3adf103abfdad53223ce6f0a764ae7163c385b/Libraries/SMCComm%2BPower.swift)（BSD-3-Clause）提供了参考。但本项目没有引入其常驻控制器、sudoers 安装方式或充电写入路径。

MIT 代码复用需要保留版权和许可，BSD-3-Clause 还包含非背书等条款。GPL-2.0 实现不能复制后仅按本项目 MIT 许可分发；如要引入，必须另行处理 GPL 对衍生作品及分发的要求。可见源码也不等于开源授权。已经使用的第三方声明集中保留在 [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md)，并随应用分发。

## 为什么这一版没有风扇控制

Stats 的[解锁路径](https://github.com/exelban/stats/blob/a9bf99866eac97d62e8952c058961f6c5e51bc67/SMC/smc.swift#L561)和[恢复路径](https://github.com/exelban/stats/blob/a9bf99866eac97d62e8952c058961f6c5e51bc67/SMC/smc.swift#L609)表明，某些 Apple Silicon 机型需要与固件及系统热管理协调，恢复时也必须交还控制权，不能只写回一个转速数字。系统调用成功仍需检查固件返回值与实际状态。

一个可靠的控制功能还需要机型能力限制、最低／最高转速约束、写后回读，以及客户端断开、传感器失效、睡眠、进程崩溃时的恢复方案。这些尚未完成实机验收。因此 1.7.0 只展示风扇状态，让系统或用户原有工具继续管理转速；降低转速也不被宣传为整机节能。

同样，健康容量比、睡眠前后端点耗电和 Apple 能量模型读数都保留估算边界。本项目优先增加有来源、能解释的数据，而不把活动时间、网络字节或风扇转速推算成看似精确的新瓦数。
