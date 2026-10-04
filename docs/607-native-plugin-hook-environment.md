# 原生插件 Hooks 环境、资源快照与持久数据

接续[第 606 篇](606-hook-settings-review-and-session-bindings.md)。普通 Responses 会话中的已安装插件 Hooks 现由固定版本 Core 的原生插件加载器发现和执行，不再作为 User 层事件声明执行。设置审阅仍在所属主窗口内；本阶段补的是运行能力，不代表 Hooks 整页或全部 UI 已完整配对。

## 对齐内容与实际边界

| 内容 | 当前行为 | 验证 |
| --- | --- | --- |
| 原生来源 | 设置查询返回 Core 的 `HookSource::Plugin` 和 native plugin ID；运行时通过 private `PluginStore`、插件配置和原生加载器加载 | 实际 Agent 查询、原生 loader 与应用会话 |
| 环境变量 | 原生 Core 提供 `PLUGIN_ROOT` / `PLUGIN_DATA` 及 `CLAUDE_PLUGIN_ROOT` / `CLAUDE_PLUGIN_DATA` 别名 | shell 处理器核对别名一致、从 `$PLUGIN_ROOT/scripts/start.sh` 启动并读取插件资源 |
| 跨任务持久数据 | 各任务私有 Core home 的插件 data 入口指向 ShipiOS 自己的 `Hooks/PluginData`；每插件独立、安装 ID 稳定 | 连续会话、另一无项目任务和新 WorkspaceStore 恢复后，计数依次为 1、2、3、4；安装包没有运行数据 |
| 资源更新 | Swift/Rust 共同核对资源路径、类型、权限位、大小及内容的 SHA-256；绑定进入既有服务身份，资源变化重建 Core 并恢复原线程 | 仅资源内容变化，Hook 定义不变，第二轮读取新内容；原线程 ID 保持 |
| 信任迁移 | 保留设置的 source ID、相对 handler key 和决定；翻译成 Core 的原生 plugin key，继续由 Core 核对定义 hash | User/Plugin 同一声明 hash 相同；已信任/禁用的决定保留；既有修改、批量原子保护测试 |
| 便携格式与多个来源 | 固定上游的 portable loader 尚不加载 Hook 扩展；宿主将已选中的原始定义投影到私有 legacy manifest，多文件及多个 inline source 仍属于一个插件 | 两个 portable inline SessionStart 同时执行，旧 legacy 声明不执行；原安装清单未修改 |
| 路径和资源限制 | RPC 仅接受安装 ID 和摘要；根目录由 Agent 自身数据路径决定，拒绝自定义根路径、链接、特殊文件、过期摘要和意外 data 绑定 | 真实 RPC 的过期摘要拒绝、链接/权限位测试、native store 路径与数据绑定测试；最多 2,000 文件、50 MiB，另设目录数量/深度上限 |
| 其他组件 | Hook 投影明确指定空技能/命令/MCP/apps，避免这个适配层再次自动发现其他组件；既有宿主管理路径保持其独立职责 | 原生 manifest 路径检查与真实 Core 会话；不据此宣称插件 MCP/OAuth 全生命周期完成 |

本阶段没有改写用户命令，没有在外层 shell 手动导出环境来模拟 Plugin 来源，也没有读取个人 Codex 的配置、插件、登录或会话。native ID 对宿主安装 ID 做可逆编码，避免 Codex 名称语法与宿主名称语法的碰撞。

资源目录是任务拥有的运行快照。其普通资源内容和可执行位保留；运行清单由宿主生成，portable 根清单不会原样暴露在快照根目录。依赖原始清单位置/内容的处理器仍需进一步适配。这与原安装目录分开，原清单不被改写。每次新的 Core 启动需要准备资源快照，大小/启动耗时和完整插件包兼容性继续属于后续验收。

资源摘要用于快照一致性和刷新，不等于 Core 的信任 hash。原生信任 hash 覆盖 Hook 声明，不覆盖它引用的脚本内容；本阶段保持原生语义，不能把脚本变化描述为自动撤销信任。

## 验证记录

- Rust 全工作区最终 **167 项通过**，包含 vendor sandboxing 106 项及 ShipiOS 61 项；fmt、Clippy 全目标 `-D warnings` 通过。普通沙箱下第一次全量遇到 4 项已有 Seatbelt 测试的 `sandbox_apply: Operation not permitted`，在获准的执行环境重新完整执行后通过，不隐去首次失败。日志 `.cache/hook-plugin-workspace-tests-final.log`、`.cache/hook-plugin-clippy-final.log`。
- Hooks、启动取消、插件 Hook catalog、插件设置导航和设置导航 **43 项通过，0 失败/跳过**，27.728 秒。包含 12 项 Hooks，其中新增 3 项实际环境/资源/恢复、便携多个来源及边界测试。日志 `.cache/hook-plugin-related-swift.log`。
- 初期 Swift 资源遍历的目录尾斜杠与 Rust 路径格式不一致，随后配置表插入缺少键导致 Agent 退出，均由实际测试发现并修复；设置查询、真实四轮会话和原始信任/启停复测通过。第一次全组的旧测试直接索引空数组而退出，已改为 XCTUnwrap 以保留有用的失败。失败日志保留，不记为通过。

- 更广回归 **111 项通过，0 失败/跳过**，235.350 秒：7 项 CodexNativeFork、86 项 ModelTransport、4 项 PluginDetailNavigation、14 项 PluginTests。与 43 项的测试类不重叠，本阶段共 154 项不同 Swift 用例通过。日志 `.cache/hook-plugin-session-regression.log`。
- 最终源码通过指定独立缓存的 `script/build_and_run.sh` 构建和 LaunchServices 启动，严格深度签名与实际捆绑 Agent IPC 冒烟通过；日志 `.cache/hook-plugin-app-run.log`、`.cache/hook-plugin-signature.log`、`.cache/hook-plugin-ipc-smoke.log`。正式捆绑 Agent 的 12 项 Hooks 和 4 项启动取消复测 **16 项通过，0 失败/跳过**，27.319 秒，见 `.cache/hook-plugin-bundled-tests.log`；与 154 项重叠，不重复计数。
- 最新应用前台检查仍返回 Mac 锁屏、自动解锁失败。没有取得工作区可交互或本阶段 Hooks 页前台证据，不将启动成功、测试进程或隐藏窗口当作前台验收。
- 最终捆绑 Agent 对包含重音字母、中文与 emoji 文件名的正常资源查询也通过；随后同一用例验证过期摘要拒绝和可执行位变化，见 `.cache/hook-plugin-unicode-resource-test.log`。这项与上述用例重叠，不新增测试数量。

## 保留全量回归的实际终态

session 57933 的 `script/test.sh` 已确认 **exit 0**。它覆盖提交 **`f572ecf`**：163 项 Rust、2,574 项 Swift，Swift 0 失败、2 项跳过，真实 Agent IPC 冒烟通过；Swift 耗时 4,541.421 秒。日志 `.cache/full-alignment-regression-605.log`。

两项跳过均为 RealtimeVoiceWireTests 的本机 WebSocket 音频预览夹具，未提供 `SHIPIOS_VOICE_PREVIEW_FIXTURE_URL`。不能把跳过当成语音实测通过。此全量也不包括第 606/607 篇的新源码；旧提交 `f96b997` 的失败记录仍保留。

## 仍未完成

- 用户、项目和管理来源，配置层覆盖与冲突；全部来源的前台审阅。
- PreToolUse/Permission/PostTool、Compact/Interrupt/Subagent 等其余生命周期，MCP/async/超时/错误隔离、执行统计和审计。
- 运行中立即停用及旧会话 SessionEnd 收尾：配置仍按会话启动快照执行，下一轮重建不等于所有事件热更新。
- 原始插件清单资源兼容性、完整包及大包启动性能、其他组件/OAuth 生命周期。
- Chat Completions 的原生 Hooks，以及用户实际 API/GitHub、前台按键/焦点/恢复与同版本 Codex 的完整操作配对。

完整页面配对保持 **0/47**，29 项核心要求仍有其各自未完成的边界。详细范围继续以[完整矩阵](599-core-function-parity-matrix.md)为准。
