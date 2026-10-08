# 全局听写的 Esc 取消与过期事件隔离

日期：2026-10-09。接续第 688 篇明确保留的取消缺口。本阶段不计为任何整页配对验收通过。

## 参考要求与实现范围

第 688 篇从本机当前公开设置资源 `keyboard-shortcuts-settings-ef4c455aeec6.js`（SHA-256 `f31de7f3b3c6b2449870be9f0fbc8259cd5f494d06105b619a26560976892328`）确认听写提示要求：Works in any app. Press Esc to cancel a recording. 该提示证明产品要求，不证明参考宿主内部使用哪种原生监听、修饰键判断或事件调度。

新增 `GlobalDictationCancellationMonitor`，仅在全局听写准备开始后安装本地／全局 keyDown 监听；结束、启动失败、目标替换、退出或对象释放时移除。每个回调固定捕获自己的录音 token，旧排队事件、旧启动结果及旧结束请求不能作用于新录音。原生全局监听沿用全局文本插入已经要求的辅助功能权限，没有新增自动授权或绕过系统权限。Apple 的[事件监听说明](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/EventOverview/MonitoringEvents/MonitoringEvents.html)明确：两种回调都在主线程执行，全局监听不能阻止其他应用接收事件。因此外部应用仍可收到 Esc；参考宿主是否同样透传，保留为实际配对问题。

AppDelegate 的实际取消回调清除对应切换／按住启动身份，并调用 `SpeechDictation.stop(target:token, commitResult:false)`，覆盖准备授权、录音及等待最终转写阶段；不提交已识别文字，迟到的识别结果和超时不能再次提交。目标已变成本地输入时不吞其 Esc。快捷键录制拥有 Esc 的优先权；录制期间不取消听写。

按住快捷键可能仍有修饰键按下，因此取消监听按 Escape 键码处理，不要求修饰键归零。这是 ShipiOS 对按住模式的实现选择，未从提示推断出参考宿主的全部键盘策略。裸修饰键监视器不再把 Esc 当普通输入先结束并提交；保留按住状态直到物理修饰键松开。取消后的按住状态禁止重复启动直至松开。三种语音 Carbon 命令也按一次按下触发，重复事件不能在取消后立即重启；其他全局命令保留原有重复策略。

`SpeechDictation` 将原有会话初始化与开始采集的身份检查拆为实际生产入口，识别回调先规范化文本／final 再按同一 generation 处理。测试可以直接驱动这些实际生命周期入口，不调用系统授权或打开麦克风。这些测试不能替代真实 Speech／录音／跨应用文字插入验收。

## 验证记录

初次测试编译因新增夹具的 actor／Observation 可见性声明失败，未进入功能测试（`.cache/global-dictation-cancel-focused-first-689.log`）。修正夹具后，13 项中目标替换竞争用例出现两个失败断言（`.cache/global-dictation-cancel-ownership-red-689.log`）：原监听在观察任务执行前仍吞掉本地输入框的 Esc。现于事件消费时立即检查实际目标归属，不单靠延迟的观察任务清理。

修复后专项先完成 **58 项、0 失败／跳过，3.213 秒**（`.cache/global-dictation-cancel-focused-final-689.log`）。随后增加等待原始 5 秒收尾期限的用例，专项 **59 项、0 失败／跳过，8.443 秒**，terminal exit 0（`.cache/global-dictation-cancel-focused-timeout-final-689.log`）。同步修复前的扩大回归已取得 terminal exit 0：**1,372 项、0 失败／跳过，956.140 秒**（`.cache/global-dictation-cancel-expanded-689.log`，原句柄 8790）。它使用测试类筛选，包含更多完整类／工作树流程，不声称与上一轮 706 项范围相同；不覆盖下述同步取消修复。

扩大回归末尾日志曾暂时停在工作区标签用例，实际父子进程均存活，一秒采样仍见 `LocalWorkspaceService.runCommand` 执行／`Process.waitUntilExit`，随后原句柄正常结束；没有因观察超时重启。采样为 `.cache/global-dictation-cancel-expanded-sample-689.txt`。事中保护快照 `.cache/global-dictation-cancel-expanded-689-artifacts.json` 不是启动前冻结清单；原执行文件在终态之后已为后续红／绿复测重建，不补称完整终态工件审计。正式构建曾使用独立 native-ui-689，只复制依赖检出／仓库和工作区依赖状态，没有复用 build database 或编译产物。

继续审阅 Apple 的主线程回调保证，补充“Esc 已到达但最终识别任务已排队”用例，红测试 **1 项、2 个失败断言**（`.cache/global-dictation-cancel-queued-final-red-689.log`）：额外排队的取消让最终结果先插入。现于原生全局回调内立即执行取消；旧原生回调仍固定捕获自己的录音 token，晚到新录音时被拒绝。最终专项 **60 项、0 失败／跳过，8.469 秒**，terminal exit 0（`.cache/global-dictation-cancel-focused-synchronous-final-689.log`），新增取消测试共 17 项。

最终源码扩大复测 **730 项、0 失败／跳过，231.195 秒**，原句柄 73184 terminal exit 0（`.cache/global-dictation-cancel-expanded-synchronous-final-689.log`）。筛选精确保留第 688 篇 706 个方法，另含取消／Speech 专项。它覆盖最后同步取消修复，区别于修复前的 1,372 项；与专项及前轮重叠，不累加，不称最新源码全量已通过。

新增测试覆盖实际 AppDelegate 取消接线、Speech 部分／最终结果和 generation、监听注册失败清理、对象释放、监听生命周期、旧回调、新录音、快捷键录制优先、裸修饰键释放及 Carbon 重复输入。测试适配器驱动监听回调，Carbon 事件送入自有应用事件目标；不是跨应用真实 OS 按键验证。各组测试重叠，不累加，也不替代最新源码全量。

最终同步源码通过标准 `script/build_and_run.sh --app` 构建与启动命令，terminal exit 0（`.cache/global-dictation-cancel-build-run-synchronous-final-689.log`）。主应用代码改变，App／helper 均使用 Apple Development，指定要求与重建前相同，并分别通过旧要求和严格深度校验；helper CDHash 与保存的第 688 篇受测代码一致（`.cache/global-dictation-cancel-code-equivalence-689.json`）。启动后 CUA 仍明确报告 Mac 锁屏，因此未完成本次前台工作区可交互验证或真实跨应用 Esc；不将启动命令成功描述为页面验收通过。

最终正式包 IPC／本地 Core RPC 冒烟均 terminal exit 0（`.cache/global-dictation-cancel-ipc-final-689.log`、`.cache/global-dictation-cancel-core-final-689.log`）。Core 使用回环 Responses 夹具，没有访问真实服务或个人凭据。没有 Rust 源码变化，不重复称已重跑 Rust 全套。

## 冻结全量与剩余验收

上一阶段提交 `1f6b24f8efb18c5e888ece26f441b64073f407fc` 已在 2026-10-09 02:00:18 CST 启动冻结全量，实际执行句柄 70015，Swift 子进程 76222。捕获 1,468 个源路径、87 个源夹具及 180 个编译资源，使用 `native-ui-654`、保存的 helper 与参考 CSS；manifest、status 和日志为 `.cache/full-alignment-regression-688-{manifest,status}.json`、`.cache/full-alignment-regression-688.log`。本阶段使用已释放的 `native-ui-648`，不覆盖其测试执行文件／编译资源／helper／CSS 或原夹具。最终源码及正式构建之后再次核对原 87 个夹具、180 个编译资源、测试执行文件／helper／CSS 均未改变（`.cache/global-dictation-cancel-frozen-integrity-final-689.json`）；6 个原来源文件已经修改，不称全源码未变。原执行句柄仍明确报告运行中；该全量即使通过也不覆盖本阶段新源码，须等待实际句柄终态和工件审计。

仍需解锁后的真实跨应用 Esc、系统辅助功能状态、实录／转写／播放与取消历史、实际文字插入和完整双端页面验收。听写提示音、按住／双击免提、全命令映射／排序／描述、序列绑定录制／冲突／执行／搜索及矩阵其他缺口仍未完成。完整配对保持 **0/47**，不据本阶段功能回归换算开发百分比。
