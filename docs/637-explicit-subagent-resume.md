# 子会话明确重新开放后的空闲状态与续聊

日期：2026-10-07。接续[第 636 篇](636-closed-subagent-lifecycle.md)保留的明确 resume_agent 缺口。47 类页面、29 项核心要求保持，完整双端配对仍 **0/47**。

## 参考与实际失败

参考本机 Codex 26.930.51102 / build 13100 已提取的公开 app-primary-c0280d43ce72.js，SHA-256 234429db84d9319850ff0766a4a5052a9e898bfa0611883633f80018080dd6c0 再次核对一致。参考投影会让 resumeAgent 替换此前 closeAgent；运行时 idle 投射为 completed。因此明确恢复后的空闲子会话应重新出现并可输入。公开代码研究不替代 Codex 前台完整操作证据。

扩展实际 Core 夹具执行 spawn_agent → close_agent → resume_agent，恢复参数使用原生要求的 id，不是关闭工具的 target。使用第 636 篇精确正式包 helper，旧生产代码稳定出现 **1 项、3 条断言失败、0 unexpected、exit 1**：状态仍 pendingInit、working 为 true、保留草稿无法发送。日志 `.cache/resumed-child-before-637.log`。复现前没有调用自动加载 RPC，避免旧加载注册掩盖真实工具恢复问题。

## 修复

- 在现有 ExtensionRegistry 安装 NativeResumeObserver，仅使用 Core 的 ThreadLifecycleContributor.on_thread_resume 回调，在实际 thread_store 中写入运行时私有标记。
- DescendantSource 对有原生恢复标记且仍 PendingInit 的线程，使用已有持久历史终态投影。保留自动加载前的原有注册保护；不更改原生 AgentStatus、完成监听、模型、权限、线程 ID 或图边。
- 标记属于本次线程运行时，既不持久化也不来自模型工具参数。新 fork 即使继承父线程的 completed 历史，仍保持 pendingInit；恢复后的真实 Running 状态优先于旧历史。
- 现有子详情、列表和草稿共享机制直接使用修正后的状态，无需伪造父回合或清空历史。

## 自动验证

原生专项使用真实 Core 线程和持久历史，验证新 fork 不误用父终态、绕过宿主自动加载注册的原生恢复仍投射 completed、不新增 HTTP 请求、恢复后的真实运行覆盖旧历史。**1 项通过、0.98 秒、exit 0**，日志 `.cache/resumed-child-native-637.log`。

Swift 两项新增集成分别覆盖同进程与关闭后重启：实际恢复、同一根/子身份、原草稿、实际子续聊、准确新回合完成事件，以及不新增父 run。连同既有关闭/跨任务隔离，初次 **4 项通过、12.358 秒**，日志 `.cache/resumed-child-focused-637.log`。

前台重复关闭暴露夹具重复使用旧 call_id，旧工具输出会被误认为本轮执行结果；修正为带当前用户消息数量的调用 ID，并增加重复关闭和明确恢复断言。更换服务后对旧任务的关闭尝试也不作为成功证据；最终前台新建同配置任务重新验证持久图状态，详见下节。未修改生产工具来迁就夹具。

最终 Rust fmt、Clippy -D warnings 及 workspace **189 项、0 失败/忽略、exit 0**，日志 `.cache/resumed-child-fmt-637.log`、`.cache/resumed-child-clippy-637.log`、`.cache/resumed-child-rust-637.log`。Core 781 文件/六文件补丁、MCP 51 文件/四文件补丁来源审计通过，日志 `.cache/resumed-child-core-source-audit-637.log`、`.cache/resumed-child-mcp-source-audit-637.log`；本阶段没有 vendor 或依赖版本变化。

相关 Swift 集合初次 101 项通过；正式签名包精确 helper 同组 101 项通过；夹具和重复调用断言最终更新后，同一正式 helper **101 项、0 失败/跳过、44.247 秒、exit 0**，日志 `.cache/resumed-child-final2-bundle-associated-637.log`。各次集合重叠，不累加。最后 helper SHA-256 bb0215ed9a87f350fcb865bdf761b926a3f471061a37f69e8dce2aad5a6ea47d，与默认工作区恢复后的正式包仍一致，见 `.cache/resumed-child-restored-agent-shas-637.log`。

## 正式包与可见交互

使用 script/build_and_run.sh --app --data-root /private/tmp/shipios-ui-637/Data。首次 SwiftPM 等待相关测试释放缓存后完成构建；等待期间过早绑定应用产生默认实例，随后通过正式脚本重新启动隔离根。一次签名检查与脚本重签名重叠而失败，日志 `.cache/resumed-child-signature-637.log`；该检查不计通过。脚本完成后严格签名、固定 helper IPC/Core RPC 冒烟均终态通过，日志 `.cache/resumed-child-final-signature-637.log`、`.cache/resumed-child-final-ipc-637.log`、`.cache/resumed-child-core-rpc-637.log`。

首个隔离任务实际完成关闭 → 明确恢复，详情出现原草稿“resumed-child-followup 保留恢复草稿🙂”，发送后得到 Resumed child followed up；列表活动 0、已完成 1。此后重复调用发现上述夹具问题，重复关闭不计成功。

最终夹具仅绑定 127.0.0.1:59956，设置中的 Key 留空。新建最终任务 558E77CA-C781-43AC-B8B5-1EA63D2FCAC5，根 01a114fc-eec4-7527-8f27-7d0d025ae0e7，子 01a114fc-ef99-746e-b22d-c52de82c7c9f。实际关闭后输入器消失，独立 workspace.json 确认 shutdown、loaded:false、原草稿保留。

通过正式脚本重启同一根，前台列表活动 0、没有已完成子项；HTTP 请求 **10→10**，父两个 runIDs 保持。记录 `/private/tmp/shipios-ui-637/before-restart.json`、after-restart.json。父输入实际执行 resume_agent 后，同一子线程重新显示已完成 1；详情恢复原历史和“resumed-child-followup 重启后保留草稿🙂”，发送按钮可用。点击发送得到实际子回复，草稿清空。父 run 数仍为三（spawn、close、resume），请求 14，记录 after-resume-send.json；子发送没有生成第四个父 run。

最后使用正式脚本恢复默认根，Swift 0.15 秒、exit 0，日志 `.cache/resumed-child-default-run-637.log`。实际 other 工作区无持续 loading、输入可点击，⌘, 在 ID main 打开设置，Esc 返回并恢复原输入焦点。最终严格签名复核通过，本机夹具正常 Ctrl-C 停止。

## 未完成范围

第 635 篇固定全量的原 handle 30966 本轮再次确认为 live；其原 PID 91696/98053/98327 经进程检查仍存活，继续使用原二进制和 helper，不重启、不覆盖冻结缓存。Rust 已终态通过，Swift 尚无终态，不覆盖第 636/637 篇。

V2 完整路径、其他状态/权限/工具呈现、所有窗口和完整输入边界、真实模型/用户服务、以及所有页面 Codex 双端配对仍待完成。本阶段仅完成上述实际原生关闭后明确恢复链路，不将 101 项专项通过描述为全产品完整对齐或最新源码全量通过。
