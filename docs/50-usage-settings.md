# 主窗口用量设置与真实 token 统计

2026-09-17。本轮在主窗口设置中加入“用量”分类。它和现有设置共用 `AppContentView`，不会创建独立窗口；从菜单或 `⌘,` 进入设置后，返回、Esc 与历史导航仍回到原工作区。

## 对照依据

OpenAI 当前帮助文档 [Reviewing work and Codex usage and using personal analytics in ChatGPT desktop](https://help.openai.com/en/articles/20001478-reviewing-work-and-codex-usage-and-using-personal-analytics-in-chatgpt-desktop) 描述了桌面端 `Settings > Usage & billing` 的时间范围、历史用量、高用量会话，以及从记录查看会话模型、推理强度与速度等明细。

ShipiOS 使用用户自行配置的独立 API 服务，不能权威读取服务商余额、额度或账单。因此本页只显示模型流式响应实际返回的 token 统计，不猜测价格、余额或限额。

## 已实现

- 设置侧栏增加“用量”，仍在同一个主窗口内切换。
- 7 天、30 天与全部时间范围；总计、输入、输出 token，以及按日柱状图。
- 最近十次已记录会话，显示任务、项目、模型、推理强度、时间和总 token；展开后显示输入/输出、缓存输入、推理输出与实际耗时，再通过“打开会话”退出设置并定位到原任务和原轮次。
- 当前范围内按任务聚合的前五项，显示会话数和 token 总量；点击后回到该任务。
- 在“模型与 API”中提供“记录服务返回的 token 用量”开关。启用后请求发送 `stream_options.include_usage`，并继续读取 `finish_reason` 之后的 usage 数据块。
- 新配置默认请求 usage；旧配置迁移时保持关闭，避免不支持 `stream_options` 的兼容服务在升级后突然失败。
- 输入、输出、缓存输入与推理输出统计随会话执行记录写入 `workspace.json`。归档任务删除时，对应会话和用量记录一并消失。
- 页面显示“已记录会话 / 已完成会话”覆盖率，并明确标注未返回 usage 的服务或旧会话不会进入图表。

## 验证

定向测试覆盖：

- Chat Completions 与 input/output 两组 usage 字段解析；
- usage 数据块位于 `finish_reason` 之后时仍能读取；
- 开关启用/关闭后的真实请求体，以及旧配置迁移；
- 多轮记录按任务聚合、排序与可选明细字段；
- 本地 HTTP fixture 返回 49 tokens 后，Store 将结果持久化，重载仍一致；
- 从用量记录跳回原任务和原轮次，设置页不产生独立窗口；
- 新会话将请求所用的推理强度写入执行记录，重载后明细不依赖当前模型设置；旧记录安全回退到“服务默认”；
- 不返回 usage 的兼容服务继续正常完成会话。

完整回归通过：286 项 Swift 测试、12 项 Rust 测试、Rust fmt/Clippy 与真实 IPC 冒烟均无失败。日志位于 `.cache/usage-settings-full-tests.log`。

## 仍待配对

- 独立 API 服务没有统一的价格、余额、额度重置时间或订阅计划接口；这些内容应由服务商提供，当前页面不会生成看似精确的估算。
- 当前记录从启用开关后的新会话开始，无法还原旧请求未返回的 usage。
- 模型、推理强度与实际会话耗时已有请求级数据；速度档位尚未成为 ShipiOS 的独立配置，因此没有伪造该字段。
- 图表尺寸、行高、悬停、键盘焦点、加载/错误状态和动画仍需与用户当前 Codex 版本逐项原生配对。

macOS 当前再次处于锁屏状态，新增页面的可见布局、时间范围切换、图表悬停及两类跳转仍等待解锁后原生验收。自动测试证明数据与路由行为，不能替代视觉配对。
