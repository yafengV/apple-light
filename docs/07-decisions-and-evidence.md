# 决策记录与来源

更新：2026-09-16。本文区分原用户意图、对话中助手建议和本次整理补充，避免把讨论直接变成实现承诺。

## 1. 对话来源与演变

来源：[赚钱项目建议](chatgpt-conversation://6aaa387e-5e60-83ee-a9bb-31cbc449ec8f)，ID `6aaa387e-5e60-83ee-a9bb-31cbc449ec8f`。本次通过任务读取接口取得全部 7 轮，返回无后续分页、无附件。

| 顺序 | 用户问题 | 对话带来的信息 |
| --- | --- | --- |
| 1 | 结合经历寻找赚钱项目 | 助手提出 iOS Agent、QA、审核、Skills 和企业服务；另有 ASR 等候选 |
| 2 | iOS 开发上架一条龙是否有市场、如何收费 | 用户明确探索该产品；助手提出本地运行、发布优先 MVP 与价格实验 |
| 3 | 是否开源 | 助手建议开源核心与商业增强，用户未明确选择许可证 |
| 4 | 产品必然涉及 AI 改码，能否复用 Codex/Claude | 用户明确要求复用成熟内核以降低成本；助手提出运行时抽象与领域状态机 |
| 5 | 查看开源 Codex 的定制程度 | 助手从 App Server 进一步提出 core + extension 路线 |
| 6 | 更倾向内嵌 `codex-core + extension-api`，是否可完全隔离 | 用户明确技术偏好，并要求模型、系统配置等独立 |
| 7 | Codex mac 客户端是否 Swift 原生 | 助手提出 ShipiOS 使用 SwiftUI/AppKit + Rust 独立进程 |

原对话对用户经验的描述来自助手上下文总结；可作为方向背景，不作为已核实履历。ASR Gateway、婚礼/情侣 App、股票分析等候选未纳入 ShipiOS 主线。

## 2. 决策登记

| ID | 事项 | 状态 | 当前处理 |
| --- | --- | --- | --- |
| D-01 | iOS 开发与发布一体化方向 | 用户明确探索方向 | 作为项目愿景 |
| D-02 | 复用成熟 Coding Agent | 用户明确要求 | 不自建通用 Agent loop |
| D-03 | 独立 host 内嵌 Codex Core + 扩展 | 用户明确偏好，技术待验证 | P0 优先验证，不默认改为外部 CLI |
| D-04 | 与个人 Codex 配置/模型/状态独立 | 用户明确需求 | 以隔离矩阵验收，避免绝对化表述 |
| D-05 | SwiftUI/AppKit + Rust | 对话建议 | 暂作目标架构，P0 验证桥接和分发 |
| D-06 | IPC：UDS / stdio / XPC | 未定 | 本次建议 stdio 先行，UDS 留作多客户端演进 |
| D-07 | 编码优先还是发布优先 MVP | 对话建议存在变化 | 本次建议先做共同验证基础，再接发布试点 |
| D-08 | Open Core 与许可证 | 未定 | 保留候选边界，不创建许可证 |
| D-09 | 本地优先、用户承担模型费用 | 对话建议 | 作为商业假设；认证与使用条件另行验证 |
| D-10 | Claude 与其他模型/运行时 | 后续候选 | 保留接口，不承诺首版多 Provider |
| D-11 | 自动提审与人工授权边界 | 对话建议 | 授权绑定具体对象和材料，恢复不盲目重试 |
| D-12 | 产品名 ShipiOS | 暂定 | 当前目录 `apple-light` 不重命名 |

## 3. 本次技术核对

**后续实施更新**：以下表格保留初次网页核对的历史。2026-09-16 已下载并固定 `50d77959bf927293c4b5ddcca81d05331ae582ea`，确认扩展 API 实際路径为 `codex-rs/ext/extension-api`，且 `core-api` 导出 `ExtensionRegistryBuilder`。此前获取失败属于路径/网页核对限制；当前源码审计见 [实现报告](08-local-prototype.md)。

这是有限的文档/源码浏览核对，不是编译、运行或完整源码审计。下列链接包含滚动更新页面；尚未固定 commit，不构成长期兼容性依据。

| 主题 | 本次观察 | 对开发的影响 |
| --- | --- | --- |
| App Server | 官方文档描述协议、stdio 和会话操作；明确实验性限制 | 可列为备选，需固定版本集成测试 |
| 配置来源 | 官方列出项目、用户、系统等配置层与管理约束 | `CODEX_HOME` 不能独自保证全部隔离 |
| 状态目录 | 官方说明本地状态以 `CODEX_HOME` 为基础，认证可用文件或系统凭据存储 | 存储与认证后端分别测试 |
| core-api | 浏览到的源码存在基于 core 的线程管理 facade | 支持进一步做内嵌 PoC，不等于全部扩展承诺成立 |
| extension-api | 本次尝试的源码地址获取失败；core-api 页面未匹配到 `ExtensionRegistry` | 不据此断言接口不存在，也不写成已确认；P0 审计实际 workspace |
| 许可证 | Codex 主仓库 LICENSE 标示 Apache-2.0 | 产品分发仍须核查实际依赖及 NOTICE |

直接来源：

- [Codex App Server](https://learn.chatgpt.com/docs/app-server)
- [Config basics](https://learn.chatgpt.com/docs/config-file/config-basic)
- [Advanced Configuration](https://learn.chatgpt.com/docs/config-file/config-advanced)
- [Codex core-api 源码](https://github.com/openai/codex/blob/main/codex-rs/core-api/src/lib.rs)
- [待核对的 extension-api 路径](https://github.com/openai/codex/blob/main/codex-rs/extension-api/src/lib.rs)（本次获取失败）
- [Codex LICENSE](https://github.com/openai/codex/blob/main/LICENSE)

## 4. 对原讨论的校正

| 原讨论表述 | 文档中的处理 |
| --- | --- |
| “可定制 60–70%、80%、90%+、100%” | 无量化口径，删除百分比，只比较控制边界与维护成本 |
| “Extension API 可直接提供所有 Contributor” | 接口列表作为待核查线索，不能直接写依赖或实现 |
| “完全隔离”“唯一共同点是源码” | 改成配置/状态隔离目标；操作系统、工具链与策略仍共享 |
| “本地运行所以代码和凭据都不离开机器” | 明确代码/日志/截图可能发送给模型，凭据分作用域处理 |
| “ChatGPT/Claude 订阅可以直接用于产品” | 标为认证与商业使用条件待验证 |
| “配置 provider 就能换任意模型” | 区分模型协议与 AgentRuntime，逐个验证兼容性 |
| “Codex mac 客户端是 Electron + React” | 原对话结论未在本次独立核验，且不作为 ShipiOS 技术选型前提 |
| “竞品价格证明用户愿意为本项目付费” | 竞品仅为研究线索，实际意愿需访谈与付款证据 |
| “上架就绪百分比 / 十分钟上架” | 改成具体检查项、范围、耗时实测与未覆盖项 |

## 5. 待定问题与决策时点

| 问题 | 必须定案前 | 需要的依据 |
| --- | --- | --- |
| 固定哪版 Codex，扩展入口是什么 | P0 结束 | commit、编译结果、最小工具注册示例 |
| 内嵌方案是否需要补丁、是否采用备选 | P0 结束 | 接口缺口与持续维护成本 |
| 认证方式和 Keychain 接入路径 | M1 接入真实模型前 | 技术实测及适用服务条件 |
| 支持的 macOS/Xcode、机器架构与项目类型 | M1 发布前 | fixture 和真实项目兼容性报告 |
| 首个付费闭环是 QA 还是发布 | 试点招募前 | 客户任务频率、痛点、预算 |
| 产品名称、公开仓库、许可证、客户端开源与否 | 首次公开分发前 | 品牌与依赖检查、商业策略 |
| 日志保存、模型数据流和案例复用 | 外部试用前 | 数据说明与客户授权范围 |
| 是否拓展云端、真机、Claude、企业版 | 后续阶段 | 重复需求、收入与实现成本 |

决策变更时记录日期、依据、替代方案和影响的文档；不要直接删除旧的用户偏好。新开发任务应优先读取 README、目标文档和最新决策记录。
