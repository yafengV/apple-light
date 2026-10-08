# 语音与通用快捷键页共享命令映射

日期：2026-10-09。范围为 S13 快捷键及语音设置，不代表整页或全部 Codex UI 已完成配对。

## 参考与已确认缺口

当前 Codex 26.930.51102／13100 的本地公开资源中，三个命令 `globalDictationHold`、`globalDictationSingleTap`、`realtimeVoice` 均声明 `shortcutScope: os-global`、`allowsBareModifiers: true`。`script/extract_voice_command_registry.cjs` 校验 initial bundle SHA256 后，只在空 VM 中求值这三个实际对象字面量；输出新夹具 `voice_command_registry_reference_686.json`。未访问 Codex 私人状态、DOM、原生桥接或网络。该夹具只能证明命令标识、作用域与录制能力，不能证明新版通用设置整页布局／交互。

当前语音组件 `an` 使用 `set-codex-command-keybinding` 更新 `realtimeVoice`，并刷新共享 `codex-command-keymap-state`；按住／单击听写更新后也失效共享命令映射。通用页同值取消并不重复保存的依据仍是已核验旧版 26.908.70816／9275 回调，不能升级成新版整页验收结论。

原实现没有把三个全局语音命令列入通用快捷键页。语音页会检查普通命令，普通命令却不能发现语音绑定，因此存在反向冲突。新增红测试确认：2 项出现 5 个断言失败（三个命令缺失、冲突未抛错、错误新绑定被接受）。日志 `.cache/voice-command-keymap-red-686.log`；外层旧命令尾部输出使 shell exit 为 0，不把这个外层退出码记作测试通过。

## 实现

- 命令表补齐三种全局语音命令及系统级／裸修饰键能力。通用页直接投影 `VoicePreferences`，编辑／清除／恢复调用相同保存与原生注册事务，不另存一份语音绑定；语音页改变后标签、按键搜索、重置可用状态同步更新。
- 普通与语音命令双向冲突检查；模型保存入口也检查，不依赖某个页面先验证。裸修饰键的相同组合及子集重叠不可同时分给不同语音模式。恢复单命令默认、数字键目标变化也不能新引入语音冲突。
- 通用页为三种语音模式接入修饰键按下／松开录制，保护会话 ID、取消与旧回调；系统级命令不能追加第二个别名。通用页同值仍取消而不重试注册，语音页沿用指定模式同值重试。
- 通用页显示同一模式的注册错误。三种全局语音命令仅由应用运行时登记，不在本地键盘桥接／命令菜单再执行一次，避免重复触发和把裸修饰键误当空格快捷键。
- `WorkspaceLibrary.shortcutPreferences` 保存通用命令快照，语音字段继续由原有 `voicePreferences` 持有。应用恢复兼容旧 `shortcuts.json`；第一次成功保存将现有快照纳入工作区，旧文件保持原字节。迁移后只认工作区内快照，忽略旧文件后续变化；读取失败保留最后可用快照并阻止覆盖。
- “恢复全部默认”在同一次工作区原子写入中清除三种语音绑定与通用自定义／链接偏好，同时保留数字键目标和语音词典、模型等非快捷键字段。宠物／弹出窗口候选与语音候选均在该保存前准备，保存失败不会提交候选或发布新内存状态。未恢复工作区的独立快捷键对象继续使用旧单文件存储。

## 验证记录

首轮原生专项 **66 项、0 失败／跳过**（`.cache/voice-command-keymap-focused-native-686.log`）。前一次受限运行 66 项有 14 个断言失败，全部来自 Carbon 探测找不到任何可登记组合；在可访问系统服务的环境重跑同一已编译执行文件后全部通过，不能隐去受限运行失败。

新增真实 Carbon 事务与原生页面录制检查后，85 项运行有 1 个失败：测试错误地从 NSView 子视图查找 SwiftUI 文本可访问性元素；改用 AX 子树后也未在隐藏窗口获得该文本（`.cache/voice-command-keymap-focused-release-686.log`、`.cache/voice-command-keymap-ax-diagnostic-686.log`）。未把缺失的 AX 树描述为文字已经验收。

最终改为检查实际原生录制框输入、模式值、活动计数和语音页仅在绑定存在时出现的原生清除控件，并导出真实页面渲染。修饰键补充前专项 **85 项、0 失败／跳过，7.416 秒**（`.cache/voice-command-keymap-focused-verified-686.log`）。20 项新增命令映射测试涵盖双向冲突、裸修饰键录制／重叠、旧会话、无别名、同值无操作、单项／全部恢复、磁盘失败、旧配置迁移、重开、规范文件读失败／修复、默认／数字目标冲突、本地重复触发隔离，以及真实 Carbon 登记／释放和保存失败保护。实际渲染图 `/tmp/shipios-voice-keymap-686.png` 已查看，按住听写行显示通用页刚保存的 `⌃`，编辑和清除控件均出现；仅证明隐藏页面渲染结果，不是前台配对。

上述版本扩大回归 **678 项、0 失败／跳过，219.421 秒**（`.cache/voice-command-keymap-expanded-686.log`）。随后复查并补充一个边界红测试：已登记组合通过绑定回调到达通用录制框，发生冲突后松开修饰键，错误地保存成裸修饰键；1 项有 3 个断言失败（`.cache/voice-command-keymap-modifier-release-red-686.log`）。现已统一清空组合输入的修饰键累积状态，保留冲突录制会话和原绑定；修复后另行执行专项和扩大回归，不能用前述 678 项证明新修复已验证。

最终代码专项 **86 项、0 失败／跳过，7.503 秒**（`.cache/voice-command-keymap-focused-modifier-final-686.log`）；其中本阶段新增 21 项测试。正式 `script/build_and_run.sh --app` 构建与启动命令 exit 0（`.cache/voice-command-keymap-build-run-686.log`）。App／helper 均使用 Apple Development，主应用代码改变而指定要求与重建前相同，分别通过旧要求和严格深度校验；helper CDHash 与冻结验证 helper 相同（`.cache/voice-command-keymap-code-equivalence-686.json`）。正式包 IPC 与 Core RPC 本地冒烟均 exit 0（`.cache/voice-command-keymap-ipc-686.log`、`.cache/voice-command-keymap-core-686.log`）。再次 CUA 检查明确返回 Mac 锁屏，故正式启动命令不作为工作区可交互验收。

最终代码扩大回归 **679 项、0 失败／跳过，220.255 秒**（`.cache/voice-command-keymap-expanded-final-686.log`）。本结果包含修饰键释放修复，区别于修复前的 678 项；仍是关联范围，不能替代全部测试或前台配对。

## 尚未完成

Mac 当前锁屏；本阶段新增前台工作区、两页实际切换、系统键盘全局投递、按键搜索对裸修饰键的实际录入、不同输入布局／Fn、精确视觉与新版通用页完整配对仍未验收。测试中的裸修饰键查询直接进入搜索状态方法，不能把它当作实际按键搜索控件已捕获裸修饰键。隐藏窗口直接调用录制框或访问自有控件 AX 树不能替代前台或 OS 注入验收。

裸修饰键权限／监视器完整事务、不同全局命令之间在同次批量重置中的组合转移，以及完整语音链路仍需继续核对。未调用真实模型服务、麦克风或新增系统权限。完整双端配对维持 **0/47**，不能把测试数换算为实现百分比。

第 685 篇冻结全量仍使用 native-ui-648；本阶段只使用 native-ui-654，不修改其原 85 个源夹具／178 个编译资源、执行文件、helper 或 CSS。原句柄在本阶段结束前仍确认存活；运行中完整性核对见 `.cache/voice-command-keymap-frozen-integrity-686.json`，原 85 个源夹具、178 个编译资源与执行文件／helper／CSS 均未改变。这不是全量终态验收，其终态结果不覆盖本阶段代码。
