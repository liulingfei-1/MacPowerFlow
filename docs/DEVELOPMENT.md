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
bash scripts/test_history_store.sh
bash scripts/test_energy_insights_store.sh
bash scripts/test_power_controls.sh
bash scripts/test_fan_diagnostics.sh
bash scripts/test_alert_preferences.sh
bash scripts/test_privileged_helper.sh
```

可选的本机只读检查会采集真实数据，部分测试会短暂运行 CPU 负载。

```bash
bash scripts/test_hardware_sampler.sh --live
bash scripts/test_system_insights.sh --smoke
bash scripts/test_energy_insights_store.sh --live
bash scripts/test_fan_diagnostics.sh --live
bash scripts/test_privileged_helper.sh --live-query
```

核心测试覆盖供电方向、历史积分、导出格式、通知条件、每日健康摘要与睡眠端点边界。独立脚本还检查后台保存顺序与退出屏障、损坏档案保留、缺失／真实 0 的电池字段、通知偏好恢复、风扇只读值及 helper 参数策略。

`test_privileged_helper.sh` 编译生产 helper 与客户端相关代码，但设置写入由模拟执行器替代；`--live-query` 仅调用真实 `pmset` 查询，不更改系统设置。它验证 2／5／10 秒白名单、低功耗参数限制、能力检查、授权取消、回读不一致与执行失败。本轮未实际执行 root 写设置，不能据此声称管理员写入已通过端到端验证。通知偏好测试也不会主动申请系统通知权限。

测试通过不能替代不同机型、真实睡眠唤醒和管理员安装流程的验证。新增文件需同时进入 Xcode target；纯核心位于 `PowerFlow/Core`，由 Swift Package 测试。

## 预览与诊断

| 参数 | 用途 |
| --- | --- |
| `--preview` | 在普通窗口中显示实时标准采样，跳过自动增强连接 |
| `--preview-charging` | 显示固定充电示例，用于检查布局 |
| `--preview-about` | 打开关于页，跳过自动增强连接 |
| `--data-directory=/绝对路径` | 将功率历史和电池档案写入指定目录；通知偏好使用独立预览 suite |
| `--audit-ui` | 约 22 秒后，用当前实时标准采样渲染概览和四个详情页的明／暗两套 PNG，然后退出 |
| `--render-directory=/绝对路径` | 指定 `--audit-ui` 的图片输出目录，需配合使用 |
| `--verify-integration` | 仅 Debug 构建：检查窗口、采样档位、睡眠／唤醒和停止流程，打印 PASS / FAIL 并退出；必须显式提供 `--data-directory` |
| `--diagnose-startup` | 执行普通静默启动流程，约 16 秒后输出 JSON 并退出 |

预览或界面检查应使用独立数据目录，避免覆盖日常运行的历史。`--data-directory` 只隔离上述两类档案和通知偏好；外观偏好、系统自身诊断等并不因此全部隔离。不要在预览中操作登录启动或低功耗按钮，除非正在专门验证这些系统操作。

以下示例使用自己构建的应用路径，输出留在临时目录供检查。

```bash
app_binary="/path/to/MacPowerFlow.app/Contents/MacOS/MacPowerFlow"
check_dir="$(mktemp -d /tmp/macpowerflow-ui.XXXXXX)"
"$app_binary" --preview "--data-directory=$check_dir/data"
```

明暗界面检查需要能打开窗口的 macOS 图形会话。它会生成概览与四页详情共 10 张图片；应逐张检查文字、滚动和布局，不以成功生成文件代替视觉验收。

```bash
"$app_binary" --audit-ui "--data-directory=$check_dir/audit-data" \
  "--render-directory=$check_dir/images"
```

生命周期检查必须使用 **Debug 构建**。它只向当前应用进程发布模拟的睡眠／唤醒通知，不会让电脑真的休眠，不会安装服务或切换低功耗模式。输出检查也不能代替真实合盖、唤醒和系统通知的验证。

```bash
"$app_binary" --verify-integration "--data-directory=$check_dir/integration-data"
```

测试完成后可删除自己创建的 `check_dir`。渲染使用真实本机读数，图片和诊断 JSON 可能包含进程名称等信息，不应未经检查放进公开文档或发布包。

普通启动诊断使用实际静默连接路径，**不要同时加 `--preview` 或 `--audit-ui`**，否则会跳过要检查的自动增强连接。可单独指定数据目录，避免写入日常历史。

```bash
"$app_binary" --diagnose-startup "--data-directory=$check_dir/startup-data"
```

启动诊断不会主动授权安装服务。它只有一段短时间快照，不能证明所有冷启动服务都已就绪。复现问题前应退出其他实例，避免两个程序争用增强采样连接。
