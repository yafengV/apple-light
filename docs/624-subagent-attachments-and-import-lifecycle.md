# 子任务附件输入与导入生命周期

接续[子 MCP 时间线与 attention](623-child-elicitation-projection-and-attention.md)。子任务详情此前只接受文字；本阶段接入图片、文本、PDF 和文件夹快照，保留真实原生子回合的开始/引导语义。日期：2026-10-05。此阶段不是完整子会话或全部 UI 对齐完成。

## 参考依据

只读取本机 `/Applications/ChatGPT.app/Contents/Resources/app.asar` 的静态工作台资源，不读取个人认证、配置或历史。版本沿用 26.930.21537、build 12776。`local-conversation-subagents-panel-tab-7e63a07a2817.js` 为 7,668 字节，SHA-256 `621391746fc0cf3ac5ea7f04b91ab09f39a14c3c1a6597300d32266cc9374a5b`。详情实际使用 `local-conversation-thread-3f5a28c45846.js` 导出的 `k` 组件，并传入子 conversationId、hostId、canInteract、返回及后台代理打开回调。

这证明详情复用会话渲染器及按子线程交互的结构，不证明所有附件格式、输入菜单、历史卡片和前台行为已一致。本阶段复用 ShipiOS 主输入区已有的图片/文件控件和导入规则，继续保留其已知格式与大小限制。

## 实现明细

| 内容 | 当前实现 | 证据/边界 |
| --- | --- | --- |
| 输入来源 | 子输入区加号、所属窗口选择面板、图片/文件快捷命令、原生输入器粘贴、拖入图片或本机文件 | 原生窗口内控件和共享输入器；实际选择面板、粘贴/拖放及前台焦点还需实操 |
| 附件草稿 | 每个详情状态独立持有图片/文件，复用缩略图、删除和预览入口；发送失败保留 | 状态测试及实际子任务集成；返回/换子任务会清空当前草稿，不宣称完整冷草稿恢复 |
| 混合导入 | 最多 8 张图片和 8 个文件；单批错误或溢出只回滚本批新副本 | 状态测试，不清除原有草稿附件 |
| 导入生命周期 | 选择和导入分别有代际；换子任务、清空后迟到回调不能污染新草稿或清除新导入状态 | 两项延迟 provider 测试；超时默认 20 秒，取消/超时释放等待，迟到完成只处理一次 |
| 原生提交 | 私有 RPC 严格解析根/子身份、文字、图片和暂存文本；先核验实际后代，再读取附件；由 Core 开始空闲子回合或准确引导活动回合 | 图片+文件、仅图片、仅文件、活动引导、PDF/文件夹四项实际 spawn 集成 |
| 隔离 | 不能以父线程或另一根的子线程作为附件目标；错误回合及变更的图片快照被拒绝；父回复不变 | 实际 Core、HTTP 请求及原生持久历史检查 |
| 数据量 | 原提示最多 48,000 UTF-8 字节；图片沿用最多 8 张/合计 32 MiB；文本/PDF/文件夹沿用共享附件限制及大文本暂存 | 不把大图片或文件文本直接塞进普通 RPC 帧；暂存文件在成功/失败后释放 |
| 历史图片 | 读取原生 user_message.local_images 及 UserMessage.local_image，图片单独输入不丢失，重复呈现族不重复显示；仅允许工作区内实际图片文件 | 实际原生历史及外部/符号链接路径拒绝测试；名称暂为通用“图片”，没有持久原名称/哈希证明 |

子文件历史目前仍展示模型输入的参考文本，尚未恢复精确文件附件卡片。远程/内联图片、更多二进制格式、完整子工具呈现、全部输入菜单与冷恢复不计为完成。子附件草稿清除/移除后的磁盘回收与跨父子引用注册也还需完善，不能把共享导入器接入称为完整附件生命周期。

## 当前测试与全量边界

新附件专项 13 项通过，0 失败/跳过，6.205 秒，`.cache/subagent-attachments-expanded-final-624.log`。包含四项真实 Core spawn 集成、混合导入/回滚、失败保留/确认清理、迟到导入、超时/取消、路径归属与隐藏原生宽窄输入器。最后补齐图片/文件命令及实际清空命令后，扩大关联集 **199 项通过，0 失败/跳过**，41.452 秒，terminal exit 0，`.cache/subagent-attachments-final-associated-624.log`。集合互有重叠，不累加。

Rust 工作区 **186 项通过，0 失败/忽略**；fmt、Clippy `-D warnings` 通过。日志分别 `.cache/subagent-attachments-rust-624.log`、`.cache/subagent-attachments-clippy-624.log`。固定 Core 五文件/781 上游文件及 MCP 四文件/51 上游文件的补丁回放、清单与字节审计通过，`.cache/subagent-attachments-core-source-624.log`、`.cache/subagent-attachments-mcp-source-624.log`。

早前全量 handle 24574 现已确认终态 exit 1：**2,668 项 Swift，2 项跳过，2 项失败（1 项 unexpected）**，4,560.284 秒，`.cache/full-alignment-regression-621.log`。失败为 BrowserTests.testClearBrowserDataRespectsSelectedHistoryRangeAndCookieType 的清理后历史断言、WorkspaceFileSearchSessionTests.testPartialResultsKeepAWorkingSearchAlive 的超时。该测试二进制/固定 helper 来自第 621 篇，不覆盖第 622—624 篇；之前“仍在运行”是历史记录，不能继续当作当前状态。

这两项连同搜索全组在正确本机环境单独复测 **7 项通过，0 失败/跳过**，2.331 秒，`.cache/alignment-failure-reproduction-native-624.log`。首次受限环境因本机 HTTP 夹具未能启动而失败/跳过，日志保留；正确环境通过不能把原全量失败改为通过，也不能证明时序问题已经修复。后续应继续定位并以最新源码全量检验。

正式包 Agent 同组 **199 项复测通过，0 失败/跳过**，40.423 秒，terminal exit 0，`.cache/subagent-attachments-bundle-associated-624.log`；与前述 199 项重叠，不累加。`script/build_and_run.sh` 构建/启动 exit 0，Swift 构建 2.65 秒，`.cache/subagent-attachments-formal-run-624.log`。严格深度签名、包内 IPC 与 Core RPC 冒烟均 exit 0，分别 `.cache/subagent-attachments-bundle-signature-624.log`、`.cache/subagent-attachments-bundle-ipc-624.log`、`.cache/subagent-attachments-bundle-core-rpc-624.log`。

重新绑定最新 `dist/ShipiOS.app` 的前台检查仍返回 Mac 锁定，工作区可交互未验证；隐藏窗口与构建启动不代替前台检查。完整双端配对保持 **0/47**。全部[29 项核心要求与 47 类验收面](599-core-function-parity-matrix.md)仍按原范围推进。
