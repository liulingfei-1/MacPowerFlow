# 构建与测试

[返回 README](../README.md)

需要 Apple Silicon Mac 和 Xcode 27 或更新版本。工程部署目标为 macOS 13；MetricKit 与 StateReporting 的新接口仅在 macOS 27 或更高版本启用。

## 用 Xcode 运行

1. 打开 `MacPowerFlow.xcodeproj`。
2. 选择 `MacPowerFlow` scheme 和 “My Mac” 运行目标。
3. 按 `Command-R`。应用默认在菜单栏显示。

如果命令行当前使用的是 Command Line Tools，可以为本次命令指定完整 Xcode，不必更改全局设置。

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

使用 Xcode beta 时，把路径换成实际安装位置。

## 构建安装包

在项目根目录运行以下命令。

```bash
bash scripts/build_release.sh
```

脚本在独立临时目录构建 arm64 Release，对主程序、helper 和安装器做 ad-hoc 签名，然后生成 `dist/MacPowerFlow-版本号.zip`。它会解包复验签名；同名旧包保留在 `.build/previous-releases/`。

构建流程从 Git 提取已提交源码，再叠加当前修改和未忽略的新源文件，以减少同步目录的文件属性对签名的影响。安装时使用 ZIP 解包后的应用。

公开构建目前没有 Developer ID 签名或 Apple 公证。正式分发身份、公证和 `SMAppService` 迁移仍需另外配置。重新构建会改变精确签名，增强服务需要主动授权更新。

## 回归测试

```bash
swift test --scratch-path /tmp/macpowerflow-core-tests
bash scripts/test_hardware_sampler.sh
bash scripts/test_privileged_runner.sh
bash scripts/test_system_insights.sh
```

可选的本机只读检查会采集真实数据，部分测试会短暂运行 CPU 负载。

```bash
bash scripts/test_hardware_sampler.sh --live
bash scripts/test_system_insights.sh --smoke
```

核心测试覆盖供电方向、历史积分、导出格式、通知条件和解析边界。硬件、连接与进程统计另有独立回归。测试通过不能替代不同机型、真实睡眠唤醒和管理员安装流程的验证。

## 预览与诊断

| 参数 | 用途 |
| --- | --- |
| `--preview` | 在普通窗口中显示实时标准采样，跳过自动增强连接 |
| `--preview-charging` | 显示固定充电示例，用于检查布局 |
| `--preview-about` | 打开关于页 |
| `--diagnose-startup` | 执行普通静默启动流程，约 16 秒后输出 JSON 并退出 |

```bash
/Applications/MacPowerFlow.app/Contents/MacOS/MacPowerFlow --diagnose-startup
```

启动诊断不会主动授权安装服务。它只有一段短时间快照，不能证明所有冷启动服务都已就绪。复现问题前应退出其他实例，避免两个程序争用增强采样连接。
