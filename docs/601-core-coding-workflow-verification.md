# Core 工具修复、验证、审查与 Git 闭环

接续[核心矩阵](599-core-function-parity-matrix.md) C03—C17、C19 和 C22。此前补丁、Git 与编译各自通过不能证明跨模块的执行次序、结果归属和恢复；本阶段新增一条连续集成用例，并复核只读计划/审查、MCP 与无人值守边界。

## 新的跨模块用例

`ModelTransportTests.testCoreRepairsActualSwiftFailureThenReviewsCommitsAndPushesLocally` 使用临时项目、独立数据目录和本机 Responses 夹具：

1. 创建真实 Git 项目，Swift 源码 `answer()` 返回 41，验证程序要求 42。初始源码和忽略规则先提交，编译目录 `.core-verification/` 被排除。
2. 实际 Rust Agent / Codex Core 发起 `exec_command`，调用本机 `xcrun swiftc` 编译并运行。编译成功，运行验证打印错误并退出 1；并非伪造编译失败或仅在测试代码里设置失败状态。
3. 夹具从 Core 返回的真实工具输出确认预期失败后，返回 `apply_patch` 将源码 41 改为 42；然后再次通过 Core 命令编译运行。最后回复只有读到真实成功输出才说明修复已验证。
4. 检查三项执行依次包含失败验证、成功补丁和成功再验证，磁盘源码只有预期替换。应用加载最近一轮差异，确认只包含 `Sources/Main.swift` 的正确增删内容。
5. 切回正常未暂存审查范围，通过应用的 `performGitAction(.commit)` 和工作区推送服务提交并推送到临时本地裸仓库。核对本地与目标分支提交一致，树中只有源码和 `.gitignore`，没有编译产物，工作区干净。
6. 关闭 Store，再从独立目录恢复，检查工具时间线与最近一轮审查来源仍属于原任务。

用例首次完整运行通过（`.cache/core-coding-workflow-integration.log`，16.867 秒）。共享模型夹具新增分支后，重新运行下面 18 项相关集成全部通过（`.cache/core-tools-and-review-final.log`，38.409 秒）；Python 夹具语法和 Git 差异空白检查通过。

## 18 项最终相关集成范围

| 核心要求 | 本轮实际覆盖 |
| --- | --- |
| C07/C15/C16 | 新的 Swift 验证 → 补丁 → 再验证 → 最近一轮审查 → 应用提交/本地推送 → 恢复；既有真实补丁、差异存储和重启恢复 |
| C10 | 原生 Core 计划回合实际拒绝写入，次轮恢复默认并实际写入 |
| C09/C19 | HTTP MCP 工具；类型化表单；带标题的单选/多选；URL elicitation 完成或取消 |
| C16 | 大差异审查以只读 Core 回合拒绝写入；跨重启重试保留原快照，分叉/删除保留与清理相应引用；内联审查保留任务并允许正常续聊 |
| C22 | 自动化使用自己的项目及模型/推理设置；无人值守审批/提问不会无限等待；无人值守 MCP 表单拒绝；实际托管工作树携带来源修改、单独执行 setup 和工具写入且不污染源项目 |
| C14/C12 | 文件消息、队列和重启保留实际 HTTP 文件内容；HTTP 失败/重试保留文件及原图片 |
| C02/C04 | 两个任务真实流式并行且归属独立；独立任务窗口在主窗口所属项目之外发送 |

这些用例调用真实 Agent、Core、Git、编译器、文件系统和本机 HTTP 服务器；模型回答与工具请求由确定性夹具提供。它们验证应用传输和执行闭环，**不证明真实模型自主完成复杂需求的能力**，也没有真实 GitHub PR、用户 API 服务或前台鼠标/键盘操作证据。

另补跑两项原生 Core 目标集成（`.cache/core-native-goal-integration.log`）：实际执行两轮、完成后清理目标指令并正常续聊；缺少明确完成信号时只执行一轮并暂停。这补齐了之前仅报告通用目标解析和 Chat Completions 续轮的协议范围，没有把本机夹具的完成信号当成真实模型完成判断的证明。

## 可重复运行

需要先构建当前 `target/debug/shipios-agent`；不需要外部 API Key。保持项目的独立 Swift 缓存目录，运行以下筛选即可复现新增闭环：

```sh
cargo build --locked -p shipios-agent
CLANG_MODULE_CACHE_PATH="$PWD/.cache/clang-module-cache" swift test \
  --package-path apps/macos --scratch-path "$PWD/.cache/macos-build" \
  --cache-path "$PWD/.cache/swiftpm-cache" --disable-sandbox \
  --filter ModelTransportTests/testCoreRepairsActualSwiftFailureThenReviewsCommitsAndPushesLocally
```

测试不修改生产设置，不使用外部账户/远端，不保留或提交临时项目及构建产物。本阶段只修改测试和夹具，应用源码与第 600 篇已构建/签名的版本相同，因此没有把旧包启动当作新的页面验收。

## 剩余完整性门槛

真实用户服务和 GitHub 闭环、完整自主编码、多工具失败/取消/断联组合、任务/设置所有前台路径及 Codex 双端配对仍需继续。Mac 在上一阶段自动锁定，本轮没有新增前台证据；完整配对保持 **0/47**。不因一条本地编译/Git 流程通过而宣称核心全部完整。
