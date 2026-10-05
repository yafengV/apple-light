# 子 MCP 请求投射、Activity 与通知定位

接续[子任务 MCP 详情交互](622-subagent-mcp-actions-and-forms.md)。此前父回合结束后，子请求只能在子详情操作，主时间线与 Activity 没有显示等待操作状态。本阶段将实际子 MCP 请求接到主窗口和独立任务窗口时间线，并联动侧栏、Activity、宠物及通知定位。完整 UI 配对仍未完成。

## 参考与实现范围

本机安装包为 `/Applications/ChatGPT.app`，版本 26.930.21537、build 12776，其 `Contents/Resources/app.asar` 包含 Codex 工作台资源。本阶段只读取安装包内静态模块，不读取个人 Codex 配置、认证或会话数据。

`project-child-elicitations-ab7ebbaebfd3.js` 的原始 `F` 函数处理根时间线的子 MCP 请求。模块 SHA-256 为 `33464c6a3248722495ae5b9b3d78b2fff0095ff83024fa12d49207ff3387f431`；函数 SHA-256 为 `ab259c2a4df346835c86e8e63d1fa68f19f62db2bb7916e5c44a1fe8fdca0529`。临时执行副本与安装模块函数逐字节一致，执行十组输入后取得结果，再与 Swift 实现比较。仅输入/结果与来源摘要进入测试夹具，参考 JavaScript 留在忽略的缓存中。

这十组覆盖普通已加载回合，不覆盖分页占位、语音或 compact Aeon 条目。读取参考代码和离屏渲染均不能代替实际双端交互验收。

| 对齐项 | 本阶段行为 | 验证边界 |
| --- | --- | --- |
| 主时间线子请求 | 按所属根/子身份投射工具审批、表单和 URL；复用子详情公共卡片与原始一次性回复 RPC | 实际 Core spawn 请求、状态及隐藏视图构建；前台未验收 |
| 独立任务窗口 | 按该窗口 taskID 投射，位置状态属于各窗口 | 两窗口投射状态独立测试和 TaskWindowView 隐藏渲染；实际多窗口交互未验收 |
| 固定位置 | 新请求位于最后普通回合后；已有请求保留首次锚点，新回合不会移动它。锚点移除时回退到此前仍可见的回合，否则置前 | 参考函数十组结果与 Swift 全部一致 |
| 没有普通回合 | 不新建首次请求条目；只保留此前已经投射且仍待处理的子条目 | 参考结果测试；不能把此分支描述为所有空历史都显示卡片 |
| 请求收尾 | pending/resolving 仍显示；resolved/expired 移除；字段草稿仍由公共卡片清除 | 共享状态与实际表单回答、URL 取消/停止验证 |
| Activity/侧栏 | 子命令/补丁/MCP 工具待批准显示 approval；子表单/URL 显示 elicitation。父回合完成后子工作仍计为运行 | 单元状态及真实子请求集成；侧栏通过公共 attention 状态使用该结果，实际布局/点击未验收 |
| 宠物 | 子请求等待显示 needsInput；仅子任务仍运行时保持 running；全部完成回到既有状态计算 | 最终状态测试与 PetTests；素材、动画和前台未完成 |
| 通知 | 原始子请求令牌去重，MCP 请求携带所属根/子/令牌。权限读取期间请求已结束时抑制迟到通知 | 注入的授权通知服务、实际 Core 请求与去重测试；不是系统横幅实测 |
| 通知定位 | 点击当前 MCP 通知打开所属父任务，主时间线定位准确子卡片；已结束/错误子/旧令牌回退到父回合，不能定位新请求 | 实际表单、工具和停止后新 URL 请求三项集成 |
| 所属与持久化 | 归档、冷子线程、根替换及损坏实时帧不产生投射/attention；断开清除去重集合。宿主令牌、答案和验证 URL 不写入 workspace JSON | 状态/实际请求测试；系统通知自身包含定位令牌，不泛称所有底层存储都没有令牌 |

命令/补丁审批会参与 attention 和通知，但本阶段根时间线投射仅包含 MCP 请求，与当前参考模块的 MCP 请求来源一致。命令/补丁通知仍定位父回合，不能描述为全部子审批都能准确打开子卡片。

## 验证记录

新增三项实际 Core spawn 集成：父回合结束后的子表单 attention/Activity/通知定位及回答；停止后旧 URL 通知与替换请求隔离及准确取消；MCP 工具 approval 分类、通知定位与拒绝不执行工具。父回复保持，实际服务器回复与 workspace 持久化边界均检查。

六项 attention/通知/隐藏视图用例覆盖父完成后的等待/提交/收尾、归档和错误帧、通知去重、部分/无效/同 UUID 大小写身份拒绝、权限读取期间收尾、主与独立任务窗口及宽窄卡片渲染。两项投射测试包含十组原始函数结果及窗口独立位置。隐藏视图尺寸检查不证明前台焦点、键盘或像素配对。

最初关联测试实际执行 47 项，一项失败：增量 SwiftPM 缓存没有复制新夹具，Bundle URL 为空。改为与项目其他集成夹具一致的源码相邻 Fixtures 路径；随后 51 项专项、160 项扩大集及正式包同组 160 项通过。各组有重叠，不累加。

最后补充宠物子工作状态后，当前 helper 最终 **165 项通过，0 失败/跳过**，40.272 秒，terminal exit 0，`.cache/child-projection-final-associated.log`。正式包 helper 同组 **165 项复测通过，0 失败/跳过**，35.274 秒，terminal exit 0，`.cache/child-projection-final-bundle-associated.log`；与前述 165 项重叠，不累加。

本阶段没有修改 Rust/Core/MCP 源码，因此不重复宣称新增 186 项 Rust 验证；该源码上一阶段的验证见第 622 篇。固定 Core 五文件/781 上游文件、MCP 四文件/51 上游文件回放及字节审计再次通过，分别 `.cache/child-projection-core-source-verified.log` 和 `.cache/child-projection-mcp-source-verified.log`。最初使用系统 Python 缺少 tomllib，随后缺少 upstream 参数，两次入口错误均保留日志；切换已有 Homebrew Python 3.14 并指定固定 checkout 后两项审计 exit 0。

最终 `script/build_and_run.sh` 构建/启动命令 exit 0，Swift 构建 2.48 秒，`.cache/child-projection-app-final-run.log`。严格深度签名、包内 IPC 与根 Core RPC 冒烟均 exit 0，分别 `.cache/child-projection-final-signature.log`、`.cache/child-projection-final-ipc.log`、`.cache/child-projection-final-core-rpc.log`。重新绑定最新正式包的前台检查仍返回 Mac 锁定，工作区可交互未验证；构建和启动成功不代替该检查。完整双端配对保持 **0/47**。

全量 handle 24574 保持原运行，固定第 621 篇 helper 与旧编译的统一来源测试二进制；它不覆盖第 622/623 篇。本轮确认原 `script/test.sh` 和 xctest PID 16273 仍存活，并只读采样其实际执行栈。日志暂未刷新不作为终态，不重启、不替换二进制、不宣称最新全量已通过。

## 剩余工作

1. 可交互前台、卡片标题/头像/尺寸/颜色、准确键盘与焦点、滚动跟随/暂停和通知横幅/点击的双端配对。
2. 分页占位、语音/compact Aeon 投射，其他 MCP 类型、OAuth/真实验证浏览器、空闲子服务器主动请求，以及其他权限请求。
3. 子命令/补丁通知的准确详情定位、附件、完整工具呈现、全部输入和冷恢复。固定 Core 的结构化提问仍只支持根线程。
4. 真实用户服务、系统通知、跨窗口字段草稿及全部[29 项核心要求、47 类页面](599-core-function-parity-matrix.md)的剩余内容。此次局部自动化通过不记为完整页面对齐。
