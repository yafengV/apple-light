# 浏览器网站权限

2026-09-17。本轮继续补齐主窗口“浏览器”设置，在同一页面中加入“历史与数据 / 权限”二级切换。应用仍只有主 `WindowGroup`，不会为设置创建第二个窗口。

## 对照依据

OpenAI 当前帮助文档说明，桌面内置浏览器在 Agent 首次使用新网站时会请求访问授权，并可在设置中管理允许和阻止的网站。站点工具文档进一步给出 `Browser settings > Permissions` 路径。参考：

- [Using the built-in browser in the ChatGPT desktop app](https://help.openai.com/en/articles/20001277-using-the-built-in-browser-in-the-chatgpt-desktop-app)
- [Using site tools in the ChatGPT desktop app](https://help.openai.com/en/articles/20001423-using-site-tools-in-the-chatgpt-desktop-app)

文档确定了权限页和站点规则职责，没有给出当前用户版本的像素尺寸、控件顺序或全部默认值。

## 已实现

- 浏览器设置顶部增加“历史与数据 / 权限”切换，两个子页仍在主窗口设置内容区。
- 默认 Agent 网站访问可选择“每次询问 / 允许 / 阻止”。
- 可输入域名或 http/https URL 添加允许或阻止规则；保存时只保留规范化的小写主机名，不保存路径、查询参数或凭据。
- 单站规则可立即改为允许、阻止或恢复默认，也可删除。
- 规则写入 ShipiOS 独立 `workspace.json`，旧工作区迁移为“每次询问”且没有单站规则。
- 权限解析接口按完整主机名匹配单站规则，再回退到默认策略；无有效主机名的 URL 安全地视为阻止。
- 页面明确区分 Agent 控制和用户手动浏览：地址栏手动打开网站不会被未来 Agent 权限规则拦截。

ShipiOS 尚未接入浏览器 Agent 工具循环，因此当前规则先构成权限存储与决策边界，不声称已经出现 Codex 的实际网站访问请求弹窗。加入空弹窗或让手动浏览误用 Agent 权限都会形成错误交互，本轮没有这样处理。

## 验证

13 项浏览器测试与 7 项设置路由测试通过，覆盖：

- 域名/URL 规范化、非法协议与内嵌凭据拒绝；
- 默认策略和单站覆盖解析；
- 添加、修改、恢复默认、重启持久化及旧 JSON 迁移；
- 真实 WebKit 浏览、历史、Cookie 清除、弹出窗口与标签生命周期无回归；
- 设置分类仍在同一主窗口保留活动工作区和返回目标。

随后完成全量回归：288 项 Swift 测试、12 项 Rust 测试、Rust fmt/Clippy 与真实 IPC 冒烟均无失败。日志位于 `.cache/browser-permissions-full-tests.log`。

## 仍待配对

- 浏览器 Agent 发起访问时的授权 sheet、一次允许/始终允许选择、取消与焦点恢复；
- 站点工具发现、工具清单和“启用站点工具”开关的真实执行效果；
- 企业策略导致设置不可用时的锁定状态；
- 子页样式、行高、菜单、键盘顺序和动画的当前 Codex 原生配对。

macOS 当前锁屏，二级切换、添加规则、行内 Picker、删除按钮和错误状态的可见验收等待解锁。
