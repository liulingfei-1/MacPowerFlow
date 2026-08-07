# MacPowerFlow 1.5.3 设计与发布 QA

## 验收对象

- 视觉参考：用户提供的能量流截图。
- 最终包：`dist/MacPowerFlow-1.5.3.zip`。
- 版本：`MacPowerFlow 1.5.3 (15)`，Apple Silicon `arm64`。
- 压缩包大小：`1,314,674 bytes`。
- SHA-256：
  `69a0b6c0d98c8377bfcdb779fc938c8fc28aba06ceeb65102c08fe607ee4c377`。
- 面板基准宽度：`420 pt`，深色外观。

## 关于面板与开源披露

- 使用 AppKit 原生“关于”面板，沿用 macOS 的图标、应用名、版本号和版权信息，
  没有另造一套与系统不一致的弹窗。
- 第一屏直接提供 GitHub 仓库和版本发布入口，并列出实际用于采样、兼容或视觉
  参考/改编的五个 MIT 项目：`macpow`、`MacMonitor`、`Powerflow`、
  `WhatBattery` 和 `mactop`。
- 明确说明应用基于 Apple 系统框架、没有第三方运行时依赖；开源项目的完整版权
  声明与许可证保存在应用包内的 `THIRD_PARTY_NOTICES.md`，本项目许可证保存在
  `LICENSE.txt`。
- 在正式安装的 `/Applications/MacPowerFlow.app` 上完成可访问性树和视觉检查：
  GitHub、Releases、5 个项目及 2 份许可共 9 个链接均可聚焦，全部内容无需滚动
  即可看完，许可链接指向正式应用包内资源。

## 能量流与展开态

- 主图保留适配器、电池、整机、CPU、GPU、显示和其他功耗；CPU
  和 GPU 只在主图出现，“其他功耗分项”展开后不再重复。
- 主流道及各支路的厚度按当前功耗分布连续变化，保留 `0.35 s`
  的过渡动画。极低功耗不会被放大成与高功耗相同的视觉权重。
- 数值与名称放在与流道连体、但拥有独立安全区的终点节点中。节点不随极窄
  流道继续缩小，因此动态变化时文字不会越过边框、被曲线遮挡或与相邻支路重叠。
- 电池与适配器改为紧凑的独立节点；充电时使用绿色，未充电时使用系统
  标签色。菜单栏电池内只保留数字，不显示百分号、分隔点或追加空格。
- 界面不再显示“实测”、“估算”或 `≈` 等来源前缀；展开区保留紧凑数值，
  数据口径放在 README 中说明。

## 六组连续真实采样

1.5.0 在同一台真实硬件上的 6 组连续刷新保留为布局与功耗守恒基线；
1.5.1 没有改动流道或文字布局，1.5.2 重做独立电池支路，1.5.3
只调整充电数据的守恒解析与电源字段标签：

| 采样 | 整机 | CPU | GPU | 显示 | 其他 |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 33.9 W | 16.1 W | 1.1 W | 3.0 W | 13.7 W |
| 2 | 33.6 W | 16.2 W | 1.1 W | 3.0 W | 13.3 W |
| 3 | 33.6 W | 16.6 W | 1.1 W | 3.0 W | 12.9 W |
| 4 | 37.9 W | 24.7 W | 5.8 W | 3.0 W | 4.4 W |
| 5 | 45.6 W | 21.0 W | 5.5 W | 3.0 W | 16.2 W |
| 6 | 42.6 W | 15.8 W | 6.8 W | 3.0 W | 17.0 W |

- 6 组数据均满足“整机 = CPU + GPU + 显示 + 其他”，仅存在界面显示到
  `0.1 W` 的舍入误差，没有负数支路。
- 在这 6 次实时改变中，折叠态和展开态均未发现流道交叉、文字越界、
  节点相互覆盖、卡片碰撞或边缘裁切。
- 还以 `0 / 0.1 / 1 / 10 / 100 / 500 W` 的边界输入检查了零流量、极细支路和
  极端比例，文字仍保持在安全节点内。

## SMC 与 IOReport 数据验证

- 在本机 M1 Pro 上通过 AppleSMC `#KEY` 枚举到 `2,131 / 2,131` 个键，其中
  `1,684` 个可按已知数值类型解码。
- 数值解码覆盖浮点、有/无符号整数和定点类型；实际 `0` 与缺失、不支持、
  读取失败分开保留。
- 未核对语义的 FourCC 只进入诊断表，不会根据名称猜测后直接映射到产品界面。
  本机实际验证了 `PSTR`、`PDTR` 和 `PDBR` 等已知键；Wi-Fi 与 USB 只在
  `wiPm`、`PUSB` 或已知分端键存在时使用。
- IOReport 能量差分窗口由 `100 ms` 改为 `500 ms`，低于应用的 2 秒刷新周期，
  同时减少过短窗口将 GPU 短促活动放大成单帧异常尖峰的问题。
- 标准 GPU 明显超过同帧可用预算时，回退 8 秒内最近合理值；没有历史值则用 0。
  小幅跨采样器偏差会钳到预算。管理员 GPU 明显超预算时回退标准通道，CPU、
  GPU、显示与其他最终都受同一整机预算约束，但原始通道值仍保留供诊断。
- 只有 `#KEY` 未超过 8,192 且所有索引都成功枚举时，能力表才用于短路“键缺失”；
  枚举失败或被安全上限截断时，已知键仍会直接读取，不会在本次会话中被永久误判。
- “其他”仍由整机功耗扣除 CPU、GPU 和显示后取非负残差；最终 6 组连续采样
  均未再出现 GPU 瞬时值大于整机、导致 CPU 被挤为零的不可能流图。

## 充电状态、电池方向与功率守恒

- 状态解析同时读取公开 IOPowerSources、`IsCharging`、
  `AppleRawExternalConnected`、充电器活动和已知 SMC `CHCC`；外接电源变化
  会触发立即刷新，不再只等待两秒轮询。
- 充电时优先使用同一 `PowerTelemetryData` 样本中的 `SystemPowerIn`、
  `SystemLoad`、`BatteryPower` 三元组；只有三者能在 2% / 0.25 W 容差内
  对账时才把它当完整原子样本。`PPBR` 在本机是放电轨，充电时不再使用。
- 完整遥测缺失时使用 AppleSMC `PDTR - PSTR`；如果它与独立整包电压 × 电流
  相差超过 `max(3 W, 35%)`，则保留实时输入腿、用整包功率重新推导系统腿。
  再缺一腿时也只由剩余两项推导第三项，不会重新混合三个异步来源。
- 某一刷新周期完全得不到两项可信值时，最多沿用 6 秒内上一份完整三元组；
  过期后整组归零。AC 充电路径因此始终满足
  `适配器供电 = 系统负载 + 电池充入`。
- 2026-08-07 本机实际充电样本为 `35.420 = 31.006 + 4.414 W`；同一时刻
  SMC `PDTR / PSTR / PPBR` 为 `36.281 / 32.059 / 0.951 W`，再次验证
  `PPBR` 不能代表整包充电功率。
- 固定充电预览使用 `62%`、适配器 `50.0 W`、整机 `31.6 W`、充入
  `18.4 W`；顶部电池条、状态标签和能量流均显示“正在充电”，绿色箭头明确
  指向电池，所有文字均在节点内且无重叠。
- 实机满电状态为 IOPowerSources `100% / Is Charging = false / Is Charged = true`；
  面板显示“已充满”、电池功率 `0.0 W`，支路降为细中性连接。该检查同时发现并
  修正了满电时 `CHCC` 非零残留造成的误报。
- 在原有纯状态用例基础上新增 10 个功率守恒回归用例，覆盖完整遥测优先、
  `PDTR - PSTR`、错相纠偏、缺腿推导、`PPBR` 排除、NaN / Infinity、CHCC
  双滞后抑制和正向整包佐证；当前测试源码共 34 个用例，6 场景独立 smoke
  harness 全部通过，Swift 6 全应用 typecheck 通过。

## CPU 零值与部分帧回归

- 现场复现帧同时存在 `33.9 W` 整机负载、`66%` CPU 活跃度和有效 CPU
  频率，但 `cpu_power` 为 0；旧逻辑将这个 0 视为最高优先级，导致 CPU
  绕过普通通道与估算并显示为“—”。
- 解析器现在同时读取 `processor.cpu_energy` 与顶层 `elapsed_ns`；当直接
  `cpu_power` 为 0 或缺失时，以 `energy_mJ × 1,000,000 / elapsed_ns`
  还原同一采样窗的平均 W。GPU 与 ANE 使用相同兼容路径。
- 如果能量字段也不可用，CPU 会依次使用增强合计残差、普通 IOReport CPU
  通道和整机负载/CPU 活跃度估算；单个零值不再阻断后续来源。
- CPU 与 GPU 先独立形成候选值；两者合计超过处理器预算时按比例共同缩放，
  不再因为 GPU 先计算而只把 CPU 压成 0。
- 新增独立 `PowerMetricsCore` 回归套件；`swift test` 的 18 个测试全部通过，
  覆盖真实 plist 字段接线、能量换算、零值/缺失回退、无效时长、来源优先级
  以及 CPU/GPU 共同预算守恒；同时覆盖前导/结尾 NUL、完整 XML、跨块帧、
  同包多帧、损坏帧重新同步、首样状态竞争和 4 MiB 边界。
- build 9 实机增强帧再次出现原始 `administratorCPUPowerWatts = 0`，同时
  整机 `40.94 W`、CPU 活跃度 `75.3%`、频率 `2.70 GHz`；普通 CPU 通道同样
  为 0，但 SoC 残差与本地模型仍给出有效候选，主视觉没有再显示“—”。
- 面板随后连续读取 3 帧：CPU 分别为 `15.7 W`、`15.3 W`、`24.4 W`，增强
  样本数由 `259` 增至 `262`；三帧 CPU 都随负载变化并保持在流道节点内。

## 增强服务、重启与登录启动

- `powermetrics` plist 流改为 `--buffer-size 0` 无缓冲输出；helper 在冷启动
  的 0.75、3.5、10、20 秒探针中受控发送 `SIGINFO`，并在每次探针后发送
  `SIGIO` 刷新可能只有半帧、尚无 NUL 分隔符的输出。
- build 10 现场抓到 macOS 27 beta 实际以 `NUL + 完整 XML` 发送一帧；旧解析器
  必须等下一帧前导 NUL 才处理上一帧，极端冷启动会与 60 秒看门狗竞争。新解码器
  在收到完整 `</plist>` 时立即产出首帧，同时保留 NUL 兼容和严格单帧大小限制。
- 首个完整样本即使早于 XPC `.running` 回执也会被接受；迟到的 `.authorizing`
  或 `.running` 状态不会再把已激活采样降级回启动态。
- 应用端首样看门狗放宽到 60 秒，只作为坏流的最终安全网；稳态新鲜度仍保持
  8 秒。首次安装后的 `powermetrics` PID `92500` 连续存活 84 秒并产生样本，
  跨过旧 25 秒和新 60 秒边界。
- 退出并重开主应用后没有出现 `SecurityAgent`；helper PID `92499` 保持不变，
  主应用由 PID `92073` 更新为 `92762`，新的单一 `powermetrics` PID 为
  `92771`。第二次流同样跨过 60 秒且面板读到超过 260 个连续样本。
- 最终 build 13 在不挂调试器的真实路径中，首次启动的 App / helper /
  `powermetrics` 分别为 `41421 / 41527 / 41528`，连续存活 1 分 52 秒；退出重开后
  App / `powermetrics` 更新为 `41878 / 41889`，再次跨过 60 秒且无密码框。
- 通过应用自身的“登录时启动”菜单执行 `SMAppService.mainApp.register()`；最终包
  重启后读取 `SMAppService.mainApp.status.rawValue == 1`，即 `.enabled`。
- 最终 XPC 服务仍只暴露版本、开始采样和停止采样三个操作；不接受命令、
  可执行路径、参数、环境变量或输出路径。

## 构建、签名与安装验证

- Swift 6 全应用 typecheck、Core 源 typecheck，以及当前源码的 Release
  `arm64` 编译和链接均通过。本机当前只选择了 Command Line Tools，没有完整
  Xcode 的 `XCTest.framework`，因此本轮没有把 `swift test` 记作重新通过；测试源
  保留 34 个用例，本次充电守恒关键路径另由 6 场景独立 smoke harness 全部通过。
- 使用与发布脚本相同的独立暂存、签名和压缩步骤生成最终 ZIP 后重新解包验证；
  helper、installer 和外层 App 均通过
  `codesign --verify --strict`，解包后没有额外扩展属性输出。
- 发布暂存先从 Git 对象库恢复未修改的跟踪文件，再叠加当前差异和非忽略新文件；
  即使 Documents/File Provider 把未修改图标或许可证逐出为 `dataless`，也不会卡住构建。
- 解包后的主程序为 Mach-O 64-bit `arm64`，`CFBundleShortVersionString` 与
  `CFBundleVersion` 分别为 `1.5.3` 和 `15`。
- 最终应用使用固定 `/Applications/MacPowerFlow.app` 路径验证；旧版本在替换前移入
  `.build/previous-releases/`，没有直接删除用户副本。
- 1.5.2 先行构建（CDHash
  `2eee6b6b9b65bbe9d013f50b84ecf607f77088ca`）已完成管理员批准；现场核对到
  root helper、单一 `powermetrics` 子进程和 `root:wheel 0444` 的精确客户端
  要求配置均正常，且没有再次出现 `SecurityAgent`。这验证了同一二进制批准后
  重开应用免输密码的链路。
- 最终 1.5.3 App 的 CDHash 为
  `28609c5704dc15f7f6cf7a76a7e8e2b6bcecd90f`，已安装到
  `/Applications/MacPowerFlow.app`；旧 1.5.2 完整保存在
  `.build/previous-releases/`。因为安全配置精确绑定二进制，首次打开 1.5.3
  仍需批准一次；之后同一包的日常启动和系统重启不再输入密码。批准后的增强
  重启检查不会在用户完成系统认证前宣称通过。

## 发布限制

当前包使用 hardened ad-hoc 签名，helper 通过精确 CDHash 绑定已安装的 1.5.3 App。
同一个二进制在日常重启和 Mac 重启后不需再次输入密码；以后重建或升级 App 会
改变 CDHash，因此需要对新二进制批准一次。要在跨版本升级后继续保持稳定身份，
仍需 Developer ID Application 签名、公证与基于 `SMAppService` 的 LaunchDaemon。

final result: coherent charging balance, visual states, build, signing, archive verification, and installation passed; one-time approval and post-approval restart verification remain for the exact final CDHash
