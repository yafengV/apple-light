# 完整回归终态、测试夹具修正与当前正式包验证

日期：2026-10-09。接续第 711 篇，诊断固定 `85d1ee0` 的完整回归失败，并重建当前应用。

## 固定完整回归终态

会话 `82625` 已结束，Swift exit 1。共 **3,272 项，2 跳过，8 个失败方法／13 条失败断言**，4,771.608 秒；3,262 个方法通过。两个跳过为未配置的本地语音音频夹具。原编排在 Swift 失败时停止，未执行该轮 IPC，不能描述为完整回归通过。

终态重新核对原清单：2,369 个源文件、187 个编译资源及测试执行文件／helper／参考 CSS 摘要均未变化，结果保存在 `.cache/isolated-full-704-terminal-integrity-712.json`。原完整日志、清单和状态分别为 `.cache/isolated-full-704.log`、`.cache/isolated-full-704-manifest.json`、`.cache/isolated-full-704-status.json`。这轮只覆盖固定第 704 篇；不覆盖第 705—711 篇。固定检出已请求归档，诊断和终态记录保存在当前仓库忽略目录。

## 八个失败方法的诊断及修正

| 失败范围 | 证据 | 本阶段修正 |
| --- | --- | --- |
| `ProjectFolderTransportTests` 七个方法 | 当前检出单独运行七项均通过；用原固定测试包单独运行一个方法仍失败。固定 helper 明确拒绝位于 `.codex` 下的数据目录，且拒绝时未创建诊断目录 | 测试原来依据 `#filePath` 把运行数据放入仓库 `.cache`；管理检出在 `~/.codex/worktrees`，因此违反应用既有隔离规则。改用系统用户缓存中的 `ShipiOSTests/project-folders-UUID`，并断言既不在 `.codex` 内，也不在系统临时目录内 |
| `PinnedTabRestoreRaceTests.testRepeatedRestoreDuringScopeLoadCreatesOneLiveTabAndOneDurablePin` | 当前代码也复现：固定项有正确 browser ID，旧断言却与分屏下合法为 nil 的左侧 active ID 比较 | 改为核对真实 focused 标签、唯一浏览器身份、右侧活动 ID、split 模式、侧栏可见及左侧 nil；重复恢复仍要求只创建一个资源和一个持久固定项 |

保留 `/tmp` 之外的项目测试目录，是为了不让默认临时目录写入授权掩盖未附加目录的权限拒绝。没有移除或放宽 Rust 的 `.codex` 数据隔离规则。夹具还增加必定关闭 Agent 的 teardown，并在连接失败处直接报告错误，避免后续空编辑请求掩盖原因。

证据日志：`.cache/full-failure-reproduction-712.log`（当前七项通过、旧固定断言失败）、`.cache/frozen-project-folder-reproduction-712.log`（原固定包的一项复现）、`.cache/project-folder-isolation-diagnosis-712.log`（固定 helper 的明确拒绝）。

排查中曾推测审查固定项应保留 split，并为此新增临时测试；进一步核对实际入口明确打开主内容区并切换 full，故撤掉错误假设、临时测试和尝试的生产改动。相关失败日志保留，不能作为产品缺陷证据。本阶段最终仅修改两份既有测试，不修改应用行为。

## 当前关联回归与正式应用

最终关联 **65 项、0 失败／跳过**，11.610 秒，exit 0（`.cache/full-failure-corrected-regression-712.log`）。覆盖七项真实 Core 多目录权限、固定项并发恢复、任务窗口固定、工作区恢复以及 full／split 布局；两份变更测试与第 705 篇 helper 的摘要在运行期间记录，终态一致，测试执行文件摘要见 `.cache/full-failure-corrected-provenance-712.json`。此前带错误审查假设的一轮 66 项有三条失败断言，不能算通过；最终已移除错误假设并复测。

通过标准 `script/build_and_run.sh --app` 构建当前代码并执行启动命令，exit 0（`.cache/alignment-current-build-run-712.log`）。正式包现已包含第 706—711 篇生产修复。应用代码摘要相较第 705 篇改变、helper 代码摘要不变；两者 Apple Development 签名要求仍与第 705 篇保存基准相同，均通过旧要求及严格深度校验（`.cache/alignment-current-signature-712.json`）。签名检查首轮只采集 stderr，遗漏 designated 输出而报解析错误；使用保存的完整基准及合并输出后校验通过，并非签名失败。

当前包内 helper 的 IPC 与本地 Core RPC 冒烟均 exit 0，日志 `.cache/alignment-current-ipc-712.log`、`.cache/alignment-current-core-rpc-712.log`。没有使用真实模型服务、个人密钥或改动系统授权。

## 仍未完成

桌面交互工具再次超时，未确认实际工作区可交互，不把构建／启动或隐藏原生测试描述为前台验收。当前测试修正之后的完整回归尚未重跑；65 项不能覆盖整个当前应用。完整双端配对保持 **0/47**，47 页／29 项核心原范围及矩阵未完成项保持，真实 API／云账户、primary workspace、Pages 配对、竞争草稿孤立管理及全部前台页面／交互验收继续未完成。

后续状态（第 713 篇）：修正后的固定提交 `376e471` 已在独立管理检出开始完整重跑，编译及先前失败组预检通过；原 handle `66840` 仍运行于 `swift-full`，结果尚未取得，不包含第 713 篇的新布局命令。原固定第 704 篇检出已完成可恢复归档。

当前复核（第 717 篇）：原 handle 已缺失，runner／Swift／xctest 的原 PID 均不在，日志可见 3,279 个完成方法、没有可见失败，但没有全套总结或退出码；状态文件停在 `swift-full`，不能计为通过。根据原清单重新校验所有冻结输入未变（`.cache/isolated-full-712-terminal-audit.json`），已完成可恢复归档检出并保留外部缓存中的原证据。需要重新取得覆盖当前代码且具有完整终态的全量结果。
