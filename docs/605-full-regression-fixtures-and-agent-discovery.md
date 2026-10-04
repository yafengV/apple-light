# 全量失败项、正确前置状态与测试 Agent 发现

接续[第 604 篇](604-native-hook-trust-and-lifecycle.md)记录的全量终态。旧提交 `f96b997` 的 2,569 项 Swift 测试中，8 个用例产生 9 个失败断言，3 项跳过；这次失败记录保留，不改成全量通过。

后续终态：本阶段提交 `f572ecf` 的全量 session 57933 已确认 exit 0，2,574 项 Swift、0 失败、2 项语音夹具跳过及 Agent IPC 冒烟通过。完整记录及准确覆盖边界见[第 607 篇](607-native-plugin-hook-environment.md)；它不覆盖第 606/607 篇的新源码，下方“仍需执行”保留为当时状态。

## 逐项定位和修正

| 原失败 | 依据及修改 | 本阶段验证 |
| --- | --- | --- |
| Core 归档等待（1 用例、1 断言） | 第 602/603 篇已区分初始化/首段输出等待，并修复启动取消；保留实际流已开始后归档的门槛 | ActivityArchiveTransport 11 项通过，包含延迟启动 |
| 运行中的无项目任务切换项目（1 用例、2 断言） | 测试打开不存在的 `/other`，且没有提供 SwiftPM 测试应用缺少的 Agent；产品正确拒绝并保留旧选择。改用真实临时项目与实际 Agent 初始化，保留运行中任务/并行资格断言，额外确认 connected | ProjectlessConversation 8 项通过 |
| 任务分支（1 用例、1 断言） | 第 367 篇早已支持子目录项目识别所属仓库；旧断言仍要求不继承父仓库分支。现在分别验证子目录读取实际分支且不改变任务目录、真正无 Git 的独立目录返回 nil、项目外任务返回 nil | TaskSearch 11 项及 ArchivedTaskSearch 2 项通过 |
| 四种终端重启（4 用例、4 断言） | 分离标签不属于主窗口 `focusedWorkspaceContentTab`；旧 fixture 在此处 XCTUnwrap 失败，实际重启断言从未执行。改为通过焦点标签 ID 找原标签，并明确断言它仍处于 detached 且主窗口目标为 nil | TerminalRestart 4 项完整执行通过：实际 PTY 替换/进程、路由/固定/后台布局保留、另一任务选中时原生隐藏窗口换视图和焦点、非活动窗口延迟聚焦、关闭/退出不创建进程 |
| 附加目录搜索（1 用例、1 断言） | 仅 XCTUnwrap 环境变量，但 `script/test.sh` 没有设置；同类搜索还因此跳过。新增公共测试 Agent 解析，优先明确环境路径，否则找仓库构建产物，缺失/目录/不可执行文件直接失败。脚本显式提供本次构建目录的 Agent，IPC 冒烟使用同一指定文件 | WorkspaceAttachedFile 5 项、WorkspaceFileSearchSession 6 项通过；附加来源区分、真实 Rust 搜索和打开内容均执行 |

没有修改产品的有效目录校验、仓库发现边界或主窗口/分离窗口焦点隔离来迎合过时测试。测试使用临时夹具；项目切换测试的运行中模型任务仍是状态 fixture，不将其冒充真实模型流。已有真实会话并行证明保留在 ModelTransportTests 中。

## 证据与下一门槛

`.cache/full-regression-failure-targeted.log`：上述 7 个测试组共 **47 项通过，0 失败、0 跳过**，21.804 秒。两项使用公共 Agent 解析的搜索测试在取消 `SHIPIOS_TEST_AGENT` 后再次通过（`.cache/full-regression-agent-fallback.log`），与 47 项重叠，不累加为 49 项。

`.cache/full-regression-configured-ipc.log`：明确指定第 604 篇 Agent 的实际诊断、事件重放、日志、立即再运行、构建取消、重启持久化和帧上限冒烟通过。`script/test.sh`、`script/build_and_run.sh` 的 bash 语法检查及 git diff 检查通过。此阶段是测试前置状态/发现流程修正，没有新的应用 UI 变更；不重复将前一阶段签名构建冒充新页面验收。

仍需按最终提交重新执行全量脚本，证明测试在完整顺序及真实 Agent 下成立。47 项专项不代替全量，也不代替真实 API/GitHub 或双端页面配对。Mac 前台仍锁定；完整配对保持 **0/47**。
