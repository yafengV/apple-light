# Core 特殊路径沙箱与命令启动失败

2026-09-28。第 349 阶段发现的两项缺陷现已修复：Core 在含双引号的项目目录启动命令会生成无效 Seatbelt 规则；进程创建或参数处理在标准命令 begin/end 事件之前失败时，会话没有失败命令卡片。

## 沙箱规则修复

固定 Codex 源码 `50d77959bf927293c4b5ddcca81d05331ae582ea` 中 `codex-rs/sandboxing/src/seatbelt.rs` 将 regex 路径插入 SBPL 的 `#"..."` 字面量，反斜杠不能在该字面量内安全表示路径中的双引号。真实命令返回退出码 65 和 `sandbox-exec: unbound variable`。直接替换为通配符会扩大权限，取消沙箱也不符合原有行为。

ShipiOS 现通过 Cargo patch 只携带该沙箱组件的本地副本，版本及其余 Codex 依赖仍固定在同一上游提交。含引号、换行或回车的 regex 经独立 `-D` argv 参数传入，由 `(regex (param ...))` 使用；常规规则保持原有格式。元数据保护、不可读 glob 以及保护祖先目录的 unlink 规则均处理相同边界，不改变权限范围。regex 参数名称带来源前缀，避免读、写与 glob 规则冲突。

本地组件保留上游完整源文件和测试，仅 `seatbelt.rs`、`seatbelt_tests.rs` 有源代码差异；清单将原有工作区依赖改为显式固定版本，并纳入项目工作区测试。原始 LICENSE、NOTICE 保留在组件内，也随应用的 Licenses 资源分发。维护说明见 `vendor/codex-sandboxing/README.md`，精确补丁见 `upstream/codex-sandboxing-seatbelt.patch`。额外三处测试格式化引用调整用于当前 Clippy；其他源文件未经修改。

新增实际 Seatbelt 回归对含引号、中文、反斜杠和换行的目录执行命令：普通文件可写，首次创建 `.git`、`.codex`、`.agents` 被拒绝，受保护 `.env` 文件既不能读取也不能覆盖，文件内容保持不变。两种会话协议均以带双引号的长目录运行 21 项技能目录集成回归，并读取外部符号链接的真实指令；Core 不再降级到不带引号的测试目录。依赖树确认 Agent、Core 及 Exec Server 实际使用本地修补组件。

## 命令启动失败的时间线

Swift 现从 Core 的真实 `raw_response_item` 中为 `exec_command` 调用保留命令卡片，即使其后没有标准 begin/end 事件。标准事件和原始结果仍按 call ID 合并在同一行，重复事件不添加卡片，不将其他工具的结果绑定到该命令。

原始结果的退出码仅从 Core 在 `Output:` 之前生成的固定头部读取，命令输出中的相同文字不会覆盖状态。运行中的 session 结果保持运行态；明确退出码决定成功/失败，参数及进程创建错误的原始文字可直接进入失败卡片。拒绝状态不被迟到的结果改为成功。卡片、输出和会话顺序随任务保存，主窗口及独立任务窗口复用原有展示组件。

四项新增状态回归覆盖没有生命周期事件、重复结果、其他工具/未知 call ID、参数错误、受信头部、输出中的伪状态、拒绝保护及交互命令未完成。真实 Core 请求另外向不存在的目录启动命令，确认失败卡片、错误输出和单条时间线持久化；模型继续正常回复，整体回合可成功而单次命令明确失败。

## 验证与边界

204 项 Core、技能及相关会话定向 Swift 回归通过，日志 `.cache/seatbelt-command-regression.log`。应用由 `script/build_and_run.sh --build-app` 构建，并通过严格签名检查；`cargo fmt --all --check` 和工作区所有目标 Clippy（拒绝警告）通过。完整 Rust 工作区 142 项测试通过，其中沙箱组件 106 项；日志 `.cache/seatbelt-workspace-tests.log`。依赖图日志为 `.cache/seatbelt-dependency-tree.log`，构建与 Clippy 日志分别为 `.cache/seatbelt-quoted-build.log`、`.cache/seatbelt-clippy.log`。

本阶段使用临时文件、本机模型和 MCP 夹具，不使用用户凭据；未重跑整个 Swift 产品测试集，也没有取得新的原生页面配对证据。此前桌面锁定导致自动审批拒绝打开 ShipiOS，仍待手动解锁，未绕过限制。完整 Codex 配对保持 0/45；其他工具生命周期边界、在线目录、OAuth、远程能力及每个页面的原生视觉/交互继续待完成。
