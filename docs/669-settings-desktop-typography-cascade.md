# 设置文字的桌面 CSS 覆盖规则

日期：2026-10-08。继续全部 UI／交互与核心功能对齐，纠正第 666／667 篇提取器只读取根主题变量、漏掉 Electron 后续覆盖的错误。

## 已确认的问题与修正

固定参考为公开资源 Codex 26.930.51102 / build 13100，不表示当前安装版本。共享 CSS SHA-256 为 `4ea4b25e3f4f3225a3bf212fa767afe7655b16bbd5919ebf4fb12c656f974720`。组件来源 SHA 同时记录在新增 `settings_desktop_typography_reference_669.json`。

根 `@layer theme` 定义 `--text-sm:12px`、`--text-xs:11px`；后续 `[data-codex-window-type=electron]` 将它们覆盖为 13px／12px。之前取首次出现值的做法不适用于桌面端。完整参考 CSS 的 WebKit 实际计算样式已确认这一差异。

| 使用位置 | 根主题值（之前误用） | 桌面实际值 |
| --- | --- | --- |
| 默认设置标签 | 12 点 | 13 点 |
| 默认设置说明 | 11 点 | 12 点 |
| 普通动作按钮文字 | 12 点 | 13 点 |
| 默认标签行高 | 120/7 点 | 130/7 点，约 18.571 |
| 说明行高 | 16 点 | 16 点 |
| 工具栏按钮行高／高度 | 18／28 点 | 18／28 点 |

共享 `SettingsRowTypography` 和 `SettingsActionButtonMetrics` 使用桌面值；各页面通过已有共享标签／按钮继承。没有根据这两个变量猜测其他字号，也没有变更 API 服务、个人配置或签名策略。

提取器共用 `reference_desktop_typography.cjs`，区分根默认与桌面覆盖。缺少覆盖或出现多个候选时失败；输入公开资源仍严格校验 SHA。新夹具由实际行／按钮组件输出及 CSS 规则合并，重新执行三步提取后逐字节一致。旧 666／667 夹具保留为历史材料，不再用于当前默认行／按钮测试；第 666 篇全量仍使用原冻结资源。

## 自动化验证

新增独立 WebKit 用例分别计算无桌面属性和 Electron 文档的标签、说明及按钮 font-size／line-height。设置 `SHIPIOS_REFERENCE_CSS` 时直接加载完整固定 CSS 并核对 SHA；未设置时加载夹具保存的实际相关规则。它不使用原生生产常量计算浏览器期望值。

修复前 `.cache/settings-desktop-typography-before-669.log`：8 项、6 条断言失败，完整 CSS 用例本身通过，明确暴露原生字号及按钮宽度差异。修复后 `.cache/settings-desktop-typography-final-669.log`：8 项、0 失败／跳过。原生断言继续覆盖实际布局、双方向、宽度边界、换行、字体行高、像素状态与焦点轮廓。

扩大 `.cache/settings-desktop-typography-expanded-669.log`：**476 项、0 失败／跳过**，136.013 秒，2026-10-08 17:34:45.773 终态通过。覆盖 Settings／Appearance／DesktopCommand／Restoration／Archived／Shortcut／Personalization 关联；不把此筛选回归称为全部功能测试。通用和 Git 页的原生离屏渲染截图已查看，未见本次字号造成的重叠；截图不代替真实窗口交互。

## 正式包与原生交互

按 `script/build_and_run.sh` 启动自有 `.cache/settings-typography-native-669/Data`，只从自有前阶段复制工作区 JSON，没有复制 API 配置或凭据。

- 实际点击 24 个设置导航页，检查内容标题／分区及窗口 ID main；插件技能／MCP 两子页分别切换并显示各自内容。这个验证覆盖导航，不代表每页所有状态或全部视觉已对齐。
- 通用页从搜索起经过 24 个导航项及八个控件，音频开关仍滚入视口并显示焦点轮廓；没有切换音频开关或请求音频权限。默认标签与说明按新字号换行。
- Git 页从分支前缀经八次 Tab 到目录选择，跳过禁用保存；Return 打开系统目录 sheet，Escape 取消后回到原按钮。Shift-Tab 回到 PR 监控编辑器，在自有夹具输入“设置字号验收669：中文换行、选区和键盘滚动。”，自动保存／JSON 均确认；反向七次 Tab 后原分支前缀选区及焦点轮廓可见。
- 同一条 Git Tab 路径仍跳过原生 Picker“默认合并方式”，这是已观测的剩余差异，本阶段没有称其通过。
- API 页只验证空输入与焦点：从基础地址依次 Tab 到模型、语音模型、协议和空密码框；Return 打开协议菜单，Escape 取消后保持菜单焦点。未填密钥、保存配置或调用服务，离开后无虚假未保存拦截；自有目录没有 model.json。
- 个性化多行编辑器 Shift-Tab 跳过禁用保存回到建议开关，Tab 返回编辑器；没有插入制表符。
- 搜索“开源许可”，点击实际结果后定位页底，再打开同窗口许可内容；Escape 先清除搜索，返回按钮回到通用，随后 Escape 回原任务输入和中文草稿。搜索框直接 Return 本次未激活结果，未计为通过路径，完整键盘语义仍需按参考核对。
- 标准脚本重启后任务、草稿“设置焦点原生验收草稿669”和自动保存的中文指令仍在；编辑器点击／Tab 可继续移到目录按钮，Escape 同窗口返回实际任务输入焦点。
- 最终标准脚本恢复默认工作区 other，实际点击输入、进入设置、Escape 返回后输入框持有焦点；没有停在恢复 loading。

构建／重启／默认恢复日志 `.cache/settings-typography-{native-run,native-restart,default-run}-669.log` 均 exit 0。原生观测摘要 `.cache/settings-typography-native-evidence-669.json`。

## 完整性与旧全量状态

保存正式 helper SHA-256 `76055e2930010d5a0dd8ed5eca943a6214258914a3ddf7b677d7c372d8a2c442`。IPC 与正式包 Codex Core 本地回环夹具均 exit 0，日志 `.cache/settings-typography-{ipc,core}-669.log`，覆盖事件／取消／持久化和批准／追问／引导／工作区写入／隔离及凭据清理。最终正式包严格深度签名通过；保存／包内 helper 的 CDHash 相同，见 `.cache/settings-typography-final-signature-669.log` 与 `.cache/settings-typography-code-equivalence-669.json`。没有 Rust 源码改动，不声称重跑 Rust 全套或真实用户服务。

第 666 篇提交 9336030 的全量仍使用冻结 native-ui-648，原 handle 94550 确认 live，本阶段使用 native-ui-654。再次核对 70 个源夹具、163 个包资源、测试执行文件和保存 helper 均未改；不重启或覆盖其缓存，不把运行中结果计为通过，它不覆盖第 667—669 篇。

## 保持的验收边界

本阶段只纠正已证实的共享文字尺寸，不证明全部字体视觉一致。参考 CSS 常规字重为 430、现有原生 regular 字重仍需核对；精确字形、紧凑分支、控件与弹层样式、全部焦点来源、macOS 14 实际运行及每页所有行为仍待继续。Codex 窗口操作此前受工具安全限制，没有绕过。

完整范围保持 21 个主页面／交互类别、26 个设置面及 29 项核心功能，完整双端配对仍 **0/47**，不是代码完成比例。详见[完整矩阵](599-core-function-parity-matrix.md)。
