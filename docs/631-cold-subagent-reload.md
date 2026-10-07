# 子会话冷恢复与无父回合连接

接续[第 630 篇](630-subagent-draft-lifecycle.md)。日期：2026-10-07。本阶段处理应用重启后的子会话加载、原线程续聊与草稿/附件恢复，不代表所有子功能或完整 UI 对齐完成。

## 参照与运行时边界

本机公开 Codex 静态资源版本为 26.930.51102 / build 13100，三个资源的字节数及 SHA-256 见第 630 篇。本阶段读取同一子任务面板资源：详情仍使用公共会话组件，并以 `canInteract === true` 控制输入；另一个后台会话标签入口显式使用 `canInteract: false, shouldResume: false`。随后从实际安装 app.asar 重新读取并核对 app-primary-c0280d43ce72.js，2,328,172 字节，SHA-256 `234429db84d9319850ff0766a4a5052a9e898bfa0611883633f80018080dd6c0`，与缓存逐字节一致。该路径在实际 collab spawnAgent 时赋予 canInteract，后续活动保留已有值，单独背景活动默认不赋予；公共会话 Hj 默认 shouldResume 为 true，按可交互及会话可用性启动恢复。由此支持实际 spawn 冷子会话的恢复方向，不能推断任意背景记录均可编辑；已关闭线程的恢复失败/输入呈现仍须进一步配对。CUA 禁止操作 Codex 自身前台，没有绕过；下面前台证据只属于 ShipiOS。

仓库固定 Core 为 `50d77959bf927293c4b5ddcca81d05331ae582ea`。该版本 MultiAgent 默认开启，MultiAgentV2 默认关闭。原公开 ensure_multi_agent_v2_child_loaded 只支持 V2，不能直接用于当前实际 spawn 的传统子线程。新增公共 ensure_child_loaded：传统线程经真实父 AgentControl 的 resume_agent_from_rollout 恢复；V2 委托原生既有 API。本阶段实际运行验证传统路径，不能将其描述为 V2 全部场景也已测试。

## 实现

| 行为 | 实现及边界 |
| --- | --- |
| 父连接 | connectOnly 复用原会话恢复通道，resumeOnly 强制要求已存历史；不提交空消息、不整理上下文、不新增父运行记录 |
| 父子身份 | Agent 验证 task/root；DescendantSource 验证真实子树和完整祖先链；Core 再验证实际存储来源、直接父线程及其存活状态，拒绝根线程和外部线程 |
| 传统记录兼容 | 部分原生记录的 parent_thread_id 列为空，实际 SessionSource 仍保存父身份；允许该来源回退，明确父列与来源冲突则拒绝 |
| 配置归属 | 从实际父会话构建原生恢复配置，保留子线程已存模型/推理与 provider；不接受宿主提供的子配置覆盖 |
| 多层与并发 | 按祖先顺序加载；克隆的 DescendantSource 共用互斥 gate，两个窗口请求不会重复创建子线程 |
| 空闲状态 | 仅对明确由本次冷加载的线程追踪恢复身份；恢复后的原生队列可能处于 PendingInit，宿主按真实持久的最后终态显示完成/失败/中断，不篡改原生 AgentStatus，不伪造回合或触发旧完成通知 |
| 详情导航 | 冷详情先恢复原父连接、加载子线程，再读取完整历史；已有已关闭状态只连接父并读取历史，不自动恢复子线程或显示输入器 |
| 草稿与附件 | 延续第 630 篇的 task/root/child 作用域，恢复原文字、图片、文件；提交后以实际回合的持久历史匹配原名和引用 |
| 迟到状态 | 若 monitor 已发布更新的 loaded 状态，加载 RPC 的较早结果不覆盖它；回调继续核验原 root 和 child |

闭合状态的专项测试预置持久 UI 观察值，再通过实际 Core 读取冷历史。它证明导航不会自动重启已关闭子线程，不是原生 close_agent 全生命周期的集成证明。

## 来源审计与初步验证

新增 Core thread_manager.rs 后，独立补丁明确为六文件。Python 3.12 审计固定版本的 781 个上游文件、补丁重放及 manifest 均通过，日志 `.cache/child-reload-source-audit-final-631.log`。新增补丁段采用零上下文生成，避免上下文空行在 git diff --check 中显示尾随空格；原有五文件补丁保持。来源审计不代替行为测试，上游 Core 全套测试不属于宿主 workspace 测试范围。

真实原生冷恢复专项通过：`.cache/child-reload-native-final-631.log`，1 项、0 失败，1.03 秒。实际完成父/子/孙后关闭原会话，恢复同一 root，并发加载孙线程，子和孙身份保持；加载前后 HTTP 请求数相同，实际子续聊仍写入子历史。

第一次集成在附件历史断言失败：`.cache/child-reload-integration-631.log`，1 项、2 条断言失败。原因是恢复后的旧 completed 状态尚未切到新回合，测试立即读取了旧历史；修改为等待本次接受 turnID 的真实 task_complete 事件，保留原附件断言。随后原专项通过，`.cache/child-reload-integration-fixed-631.log`；加入已关闭导航边界后的 2 项专项通过，`.cache/child-reload-cold-and-closed-631.log`，0 失败/跳过，2.436 秒。

Rust fmt、Clippy（-D warnings）、workspace 测试及 Agent 构建同一串行命令 exit 0。187 项 Rust、0 失败/忽略，日志 `.cache/child-reload-rust-631.log`；其他日志为 child-reload-rust-fmt-631.log、child-reload-clippy-631.log、child-reload-agent-build-631.log。第三方 future-incompatibility 及链接体积提示保留，不误称无警告构建。

扩大关联初轮 282 项在 318.750 秒结束，2 项失败：父会话仍运行时，子完成和子详情 Stop 两项未发现活动子任务，日志 `.cache/child-reload-associated-631.log`。这是实际状态回归：新 spawn 的 PendingInit 子任务也被读取了继承历史，可能误标为已完成/中断，使 monitor 提前休眠。修正为只给明确冷加载且原先未加载的线程使用历史终态投影；原始新建队列保持 PendingInit。原两项断言继续保留，没有通过加长等待掩盖回归。

恢复身份保护修正后的 Rust fmt、Clippy、workspace 187 项及 Agent 构建再次同一命令 exit 0，最终日志为 `.cache/child-reload-rust-fmt-final-631.log`、`.cache/child-reload-clippy-final-631.log`、`.cache/child-reload-rust-final-631.log`、`.cache/child-reload-agent-build-final-631.log`。两轮 Rust 集合重叠，不累加为 374 项。

限制到冷加载身份后，原两项父子隔离用例通过；但四项联合专项中的冷恢复出现 4 条断言失败，日志 `.cache/child-reload-final-focused-631.log`。后台 monitor 和 RPC 原先分别调用 descendant_source()，不是同一实例的克隆，因此 monitor 没有恢复身份，可能把已恢复空闲线程继续显示为正在启动。继续修正为同一根会话的 RPC 与 monitor 共用 DescendantSource 克隆；冷祖先身份在 Core 发布创建事件前登记，snapshot 在读取每个实际线程时查询共享身份，避免过早截取身份集合。首次两项集成和原生专项通过不能抵消这些扩大验证失败。

传统原生 resume_agent 还会自动加载该子线程的开放后代。共享身份登记因此覆盖被恢复的冷祖先及其已存子树，排除调用前已加载线程；不会把其他根或新创建的同级线程标为冷恢复。原生专项最终同时覆盖直接加载子线程（原生自动恢复孙线程）和直接加载孙线程（宿主按祖先顺序恢复），并使用两个 DescendantSource 克隆并发请求。

## 最终 Agent 与正式包

最终 Rust 串行检查及构建 exit 0，187 项、0 失败/忽略；日志为 `.cache/child-reload-rust-fmt-final3-631.log`、`.cache/child-reload-clippy-final3-631.log`、`.cache/child-reload-rust-final3-631.log`、`.cache/child-reload-agent-build-final3-631.log`。上述多轮集合重叠，不累加。

最终重点复测 4 项、0 失败/跳过、7.421 秒：`.cache/child-reload-final3-focused-631.log`。保留原两个父运行期间的子任务测试，另有冷子草稿与附件续聊、已关闭记录只读历史两项。

使用 script/build_and_run.sh --app --data-root /private/tmp/shipios-ui-631/Data 启动最终正式包，exit 0、Swift 构建 0.88 秒：`.cache/child-reload-final3-formal-run-631.log`。严格深度签名、包内 IPC、Core RPC 冒烟均 exit 0：`.cache/child-reload-final3-signature-631.log`、`.cache/child-reload-final3-ipc-631.log`、`.cache/child-reload-final3-core-rpc-631.log`。固定最终 helper 与正式包 Agent SHA-256 相同：`4e138c6fa0a0c363497fb0b5b8d6d0a48855955edbc773938fa1112c683b44aa`，记录 `.cache/child-reload-final3-agent-shas-631.log`。

## 原生前台边界

在初版正式包中，实际创建父任务和 Raman 子线程，父回复完成；通过摘要和子列表进入详情，输入中文/emoji 草稿，并用原生面板导入 cold-picture.png 与 cold-reference.txt，两类卡片和原草稿可见。重启前独立测试目录的 workspace.json 已存该草稿；本机夹具请求为 4 条，记录 `.cache/child-reload-before-ui-631.json`。

最终正式包启动后，CUA 返回 Mac 已锁屏且无法自动解锁。已请求用户手动解锁；没有尝试绕过。在该次尝试时尚未取得最终冷详情/续聊的前台证据；后续解锁后的实际验收见下文，构建和自动测试不能替代它。

最终扩大关联 **282 项、0 失败/跳过、295.030 秒**，terminal exit 0：`.cache/child-reload-final3-associated-631.log`。覆盖父子线程、草稿/附件、两种协议会话、恢复/删除/侧聊、分叉与工作树、启动取消、Hooks 和输入命令。

正式包 Agent 专项 **17 项、0 失败/跳过、10.918 秒**，terminal exit 0：`.cache/child-reload-final3-bundle-631.log`。为 9 项草稿和 8 项实际 Core 附件集成，含新冷恢复与已关闭记录导航。与关联集合重叠，不累加。

锁屏后来解除，重新使用 CUA 成功检查最终正式包，前台记录继续如下：

1. 重启后的原父任务及子概览恢复，父历史仍只有原运行，原回复保持。
2. 点击同一 Raman 子线程，原持久历史、中文/emoji 草稿、cold-picture.png 与 cold-reference.txt 卡片均恢复，发送按钮可用，没有一直停在 loading。
3. 打开冷详情前后本机夹具 HTTP 均为 **4 条**，父 runIDs 相同：`.cache/child-reload-before-ui-631.json`、`.cache/child-reload-after-ui-631.json`。
4. 在子输入器按 ⌘Enter，输入和两类草稿卡片清空；子历史显示原提示、原附件名和 Child followup only，父回复保持。请求增加到 **5 条**，父 runIDs 不变，子草稿为 0：`.cache/child-reload-after-send-ui-631.json`。
5. 返回子列表再进入同一详情，实际新增子历史和附件卡片保持，输入为空。

只使用自有本机夹具与独立临时数据；固定回复不证明真实模型的自主委派能力，也没有访问用户 API 凭据。

## 原全量终态与剩余范围

第 627 篇固定提交 `31d2b43` 的原全量 handle 72759 已在 2026-10-07 12:04 CST 结束，exit 1。Swift **2,714 项、2 项跳过、5 条失败记录（其中 1 条 unexpected）**，4,583.286 秒；实际为三个失败用例：AppearanceThemeImportTests 通知点击两条断言、PullRequestCodeHeaderTests 文件/评论行导航两条断言、WorkspaceFileSearchSessionTests 进度续期一条异常。Rust 186 项及 fmt/Clippy 通过，Swift 失败后 runner 未执行末尾 IPC。日志与状态 `.cache/full-alignment-regression-627.log`、`.cache/full-alignment-regression-627-status.json`；此前“仍运行”是当时状态。该固定全量不覆盖第 628—631 篇，不能被当前 282/17 项通过抵消。

继续保留：V2 实际 host 恢复、已关闭子线程与完整 canInteract/恢复失败呈现的精确配对、所有子权限/提问/工具/输入命令、全部跨窗口运行竞争、精确头像/布局/焦点、更多附件格式、真实用户服务及桌面路径读取停滞根因。全产品最新源码全量、47 类页面完整双端配对和矩阵其余 29 项核心要求仍未完成；完整配对保持 **0/47**。

6. 完成验收后，经同一正式脚本恢复默认工作区，exit 0、Swift 构建 0.85 秒，`.cache/child-reload-final3-default-run-631.log`。CUA 实际确认 other 工作区可交互、没有持续 loading；⌘, 在 ID main 打开设置，Esc 返回 other 并恢复任务输入焦点。自有回环验收服务器随后正常由 Ctrl-C 关闭。

最终来源复审仍通过：`.cache/child-reload-final3-source-audit-631.log`。针对原全量三个失败用例所在组，当前源码 38 项复测、0 失败/跳过、40.865 秒、terminal exit 0，`.cache/full-failures-baseline-632.log`；该专项通过不改变原全量终态，整套负载下 PR 导航和搜索期限仍须继续核验。
