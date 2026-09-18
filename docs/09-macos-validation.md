# 原生 macOS 工作台：实现与验收

日期：2026-09-16。范围是用户选择的“先实现本地部分”，并按后续要求直接在 Mac 上运行、补齐和测试桌面功能。本轮没有启动 iOS Simulator；iOS fixture 仅使用 Simulator SDK 编译。

后续已完成任务式界面改版、任务组织与输入交互；最新 UI 与新增回归记录见 [桌面交互对齐与验收](10-desktop-interactions.md)。本页保留底层执行能力的验收证据。

## 运行与结构

执行 `./script/build_and_run.sh`，或使用项目的 Codex Run 按钮。脚本构建 Rust 与 SwiftPM，生成 `dist/ShipiOS.app`，嵌入 `shipios-agent` 和示例工程，进行本地 ad hoc 签名，再通过 Launch Services 打开原生应用。`--build-app` 只生成应用；`--verify` 启动并核对进程。

客户端使用 SwiftUI NavigationSplitView、Settings、原生菜单与快捷键；AppKit 负责文件面板、Finder 定位和退出清理。应用要求 macOS 14+，当前产物是本机架构的开发构建，尚未做 Developer ID 签名、公证或分发打包。

目录职责：

- `apps/macos/Sources/ShipiOS/App`：应用场景、菜单、退出生命周期。
- `Models`：JSON 值、Run/Event、分片 JSONL 解码。
- `Services/AgentClient.swift`：独立子进程、显式环境、请求响应、事件流、超时和断线。
- `Stores/WorkspaceStore.swift`：项目切换、任务状态、日志、报告。
- `Views`：项目操作、历史、过程、诊断、日志、运行时设置。

桌面状态默认位于 `~/Library/Application Support/ShipiOS/Desktop/Projects/<canonical 项目路径 SHA-256>/`。项目切换关闭旧 Agent，再连接新项目的数据目录；每个项目保存自己的运行历史。界面记忆最近项目与填写的 Scheme，不读取个人 Codex 配置或认证。项目 `.shipios/config.toml` 在 GUI 中默认不信任。

## 已完成的功能验证

环境：macOS 26.6.2、Xcode 26.3、Rust 1.97.1。通过桌面 UI 自动化检查真实窗口和操作，并结合数据库、导出文件及进程表核验结果。

| 场景 | 实际结果 |
| --- | --- |
| 原生启动、项目选择、示例复制 | 通过；示例复制到数据目录后打开 |
| 环境诊断 | 通过；Xcode 版本输出、事件和历史正确 |
| iOS fixture 真实构建 | 通过；退出码 0，约 6.6 秒，生成 App / xcresult |
| 重跑 | 通过；新建独立 Run，原记录保留 |
| 慢构建取消 | 通过；记录 cancelled，Xcode 返回 75，构建脚本及 sleep 子进程退出 |
| 构建过程中 Cmd-Q | 通过；取消任务、保存终态、退出 Agent，未遗留测试构建进程 |
| 错误 Scheme | 通过；failed、退出码 65，展示具体 Xcode 错误 |
| 日志及诊断 | 标准输出/标准错误可切换，长日志可滚动、可选择复制；诊断显示错误或警告 |
| 导出报告 | 通过系统保存面板写入 JSON；复核 succeeded、退出码 0、4 条事件 |
| 重启恢复 | 项目与任务历史恢复；不会自动重跑 |
| Agent 退出与重新连接 | 退出后显示未连接和原因，禁用执行；重新连接后恢复历史 |
| Settings | 显示连接、数据目录及当前能力范围 |
| 窗口布局 | 检查缩放与较小窗口，修复侧栏/详情裁切和日志初始滚动位置 |

测试数据保留在忽略的 `.shipios-local/` 中：

- 构建成功：`72d02ad6-6e33-4aac-8aba-d857cb574902`。
- 导出文件：`.shipios-local/ui-validation/desktop-build-report.json`，对应成功重跑 `76ff691a-9888-46fb-8475-85fada7cb3e3`。
- 修复后的取消：`8fc7063e-56cd-47ba-964b-1ca2365990f1`。
- 修复后的退出清理：`65698868-a5ef-4ea2-8b41-150066646070`。
- 错误 Scheme：`ae70dadf-4731-459b-a92f-2a85ff1b0162`。

慢构建是从仓库 fixture 复制出来的独立测试工程，新增 30 秒 sleep 构建阶段，未修改原始 fixture。构建脚本依然是任意项目代码；没有额外 OS 沙箱，也不保证回收主动脱离进程树的恶意子进程。

## 自动化回归

`./script/test.sh` 集中运行：格式检查、Clippy（警告即失败）、12 项 Rust 测试、4 项 Swift 测试和真实 stdio 冒烟验证，全部通过。日志在 `.cache/desktop-tests.log`。

新增覆盖包括：报告只能导出终态、日志读取限额与路径边界、终态后立即重跑、协作式取消、客户端保持 stdin 打开时 SIGTERM 仍能退出、UTF-8 分片/多帧/非法及超限消息、毫秒时间戳、Swift 对真实 Agent 的握手/错误/重连。

实测修复：

1. 终态写入与活动任务占位不同步，导致立即重跑偶发失败。现在在同一调度锁内释放占位。
2. 直接 SIGKILL xcodebuild 可能留下独立构建服务启动的脚本。现在先向 Xcode 客户端发送 SIGINT，等待协作取消，超时再强制清理进程组。
3. Tokio stdin 的阻塞读取会在客户端管道未关闭时拖住 runtime 析构，导致 SIGTERM 后进程不退出。业务清理完成后使用有界 runtime shutdown，并加入回归测试。
4. 文件保存改为附着主窗口的 sheet；JSONL 使用单一有序消费者；较晚响应不能把终态回退为运行中。

## 尚未覆盖的产品能力

本地桌面工作流已可使用，但不等于完整 AI 开发/发布产品：Codex Core 内嵌、模型会话、自动改代码、Diff 审查、iOS 交互验证、签名、TestFlight 和 App Store 流程均未接入。Scheme 当前手动填写；构建目标固定为 iOS Simulator SDK；不支持独立 Swift Package 的 GUI 构建。日志在任务结束后查看，尚无实时逐行流式日志。历史分页、配额、自动清理和异常断电后的孤儿任务回收也尚未实现。

下一阶段保持用户选择的 `codex-core + extension-api` 内嵌路线，先做固定版本的离线适配与配置隔离；模型凭据由后续配置阶段处理。
