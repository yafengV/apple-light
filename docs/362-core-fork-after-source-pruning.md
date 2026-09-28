# 来源检出清理后的 Core 分叉续聊

日期：2026-09-28。第 361 篇记录的「子线程首次续聊前来源工作树已被清理」依赖，现已实际复现、修复并验证。

## 失败证据与修复

扩展真实 Core 新工作树分叉测试：子工作树已经创建并复制来源文件，但尚未创建自己的 Core 线程；随后归档来源托管任务，确认原检出确已移除。此前首次续聊失败为 `source workspace is unavailable`，日志 `.cache/fork-pruned-source-before.log`。私有 rollout 仍存在，错误发生在读取它之前对旧工作目录的强制规范化。

来源目录缺失时，Agent 现按已保存的传输路径拼写定位 ShipiOS 私有 `Projects/<digest>/Codex/Tasks/<UUID>`。已存在的来源仍规范化并检查目录类型，其他解析错误仍报错。目标执行目录仍须有效；不同目录来源必须位于私有 Projects 命名空间，未放宽到任意 rollout 路径或外部目录。

原有任务/线程/回合身份、私有根目录、项目与任务目录、引用和 rollout 范围校验继续执行。来源记录损坏或丢失时仍明确失败，不退回聊天文字复制。修复没有重建来源工作树或修改其历史；原生 Core 仍读取固定的已结束前缀，并创建独立子线程。

## 验证

- 25 项 Agent/Core Rust 测试通过，`.cache/fork-pruned-source-rust.log`。来源校验用例扩展为目录移除、路径别名失效后仍定位其私有历史；无历史的目录、非 Projects 存储、来源被普通文件替换、错误线程及逃出私有根目录的引用/项目链接仍拒绝。
- `cargo fmt --all --check`、Agent 全部 target Clippy（`-D warnings`）及实际 Agent 构建通过，`.cache/fork-pruned-source-fmt.log`、`.cache/fork-pruned-source-clippy.log` 和 `.cache/fork-pruned-source-agent-build.log`。
- 16 项 Swift 路径、真实 Core、侧栏传输及工作树分叉回归通过，`.cache/fork-pruned-source-swift.log`。扩展用例保留两层实际工具调用和输出，移除来源后在子目录执行新命令；验证独立线程、真实私有会话路径、重启后恢复相同子线程，且来源目录继续保持缺失。
- 最终 `./script/build_and_run.sh --build-app` 通过，`.cache/fork-pruned-source-app-build.log`；`codesign --verify --deep --strict dist/ShipiOS.app` 与 `git diff --check` 通过。打包未包含原生启动、焦点或窗口交互验收。

这证明该具体目录清理边界已处理，不代表所有分叉历史、Core 生命周期或全部应用测试已完成。既有首次模型响应偶发超时仍未解决。托管相同检出分叉及其他 UI 交互仍缺；当前 Codex 原生双端配对保持 0/45，未重试尚待解锁确认的原生 UI。
