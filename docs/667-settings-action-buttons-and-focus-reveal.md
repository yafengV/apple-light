# 设置动作按钮与键盘焦点显示

> 字号基准更正：本篇提取器读取了根主题值，漏掉 Electron 后续覆盖。桌面标签／按钮实际为 13 点、说明为 12 点；当前共享实现及独立完整 CSS 验证见[第 669 篇](669-settings-desktop-typography-cascade.md)。本篇原验证结果作为历史记录保留。

日期：2026-10-08。继续全部 UI／交互与核心功能对齐，补齐设置共享动作按钮的明确尺寸、颜色和焦点差异。

## 参考与实现

参考仍固定 Codex 26.930.51102 / build 13100 的公开共享 JS／CSS，摘要分别为 `eb2500c5398279d4fbf5c71d7ce982d54631660907761740199f6c22591d71ab` 与 `4ea4b25e3f4f3225a3bf212fa767afe7655b16bbd5919ebf4fb12c656f974720`。`script/extract_settings_action_buttons.cjs` 校验摘要，读取实际按钮类表并执行 `dli` 按钮组件，提取 secondary／ghost 的启用／禁用四种树。没有执行网络代码、私人配置或按钮外部回调。

公开通用文件夹组件已明确更改按钮是 secondary／toolbar、恢复按钮是 ghost／toolbar；公开许可入口也使用 secondary／toolbar。桌面 toolbar 高 28 点、左右 8 点内边距另含 1 点透明边框、12 点文字、18 点行盒；禁用透明度 0.4，焦点 ring 2 点，圆角基础值 10 点。secondary 使用文字色的 5% 底色、悬停 10%；ghost 平时透明、文字使用第三层颜色，悬停引用主题按钮背景角色。参考夹具为 `settings_action_buttons_reference_667.json`。

- 共享 `SettingsActionButtonStyle` 的中性动作改为明确的 toolbar 呈现；文件夹恢复按钮显式使用 ghost。保留真实 Button 绑定、名称和动作，标签单行、不因窄空间自动换行。
- 原有破坏性按钮继续原生 bordered 呈现及删除语义；没有将删除变成中性按钮。它们的参考变体尚未映射，不能视为已对齐。
- 保留 Tab、Shift-Tab、无修饰空格／Return 与禁用保护。原生检查暴露“焦点可以到离屏按钮但文档不滚动”：为按钮增加稳定 UUID，由所在页面的现有 ScrollViewReader 按最小距离显示目标。回调先核对当前目的地及页面，不增加滚动容器或新窗口。
- 焦点轮廓在布局外绘制，不改变按钮尺寸，禁用时不绘制。颜色继续来自独立主题角色。

SwiftUI 当前使用 continuous 圆角，参考 Chromium 支持 superellipse 时还会将半径系数改为 1.25。本阶段修正基础尺寸，没有证明精确 corner-shape 一致；primary／danger、其他尺寸、加载态、强制颜色、Space 释放／长按语义及全部焦点来源仍需继续核对。

## 自动化验证

最终扩大 **461 项、0 失败／跳过**，132.822 秒，日志 `.cache/settings-actions-focus-final-expanded-667.log`。覆盖设置、外观、桌面命令、恢复、归档和快捷键。新增三项：实际 Button 的两种方向几何／字号、真实离屏位图的默认／悬停／禁用透明度、焦点轮廓在布局外且禁用隐藏。

早期关联 15 项有六条像素断言失败，日志 `.cache/settings-actions-associated-667.log`。诊断确认缓存位图是 calibrated RGB；先将像素转为 sRGB 再直接比较原空间透明度，会引入 ICC 曲线偏差。改为在缓存自己的 RGB 空间比较，保留原 2/255 精度和公开透明度，三个专项通过（`.cache/settings-actions-color-diagnostic-667.log`），没有改生产颜色掩盖断言。随后新增外侧轮廓检查时局部变量 pixel 遮住同名方法，首轮扩大编译失败（`.cache/settings-actions-final-expanded-667.log`）；改用 self.pixel 后最终完整扩大通过。原生发现的焦点滚动问题也在最终版本复验，不把早期结果当最终通过。

提取结果重复生成逐字节一致；篡改 CSS 摘要被拒绝。已检查最终通用页离屏图，次要动作采用中性文字和明确高度。最终页面／子页离屏图位于 `.cache/settings-actions-focus-final-667-snapshots`；这些图片不等于双端交互验收。

## 原生验证

通过标准 `script/build_and_run.sh` 启动自有 `.cache/settings-actions-native-667/Data`，没有复制用户 API／凭据。

1. 真实从设置搜索开始 Tab 39 次，到达更改按钮。修复前焦点已到按钮、内容滚动值仍为 0，截图中按钮离屏；修复后内容滚动值为 0.3667747914735867，实际按钮和焦点轮廓可见。
2. 更改按钮的空格和 Return 均打开系统文件夹 sheet，Escape 取消后焦点回原按钮。Tab 到相邻 ghost 恢复按钮、Shift-Tab 返回更改再 Tab 回恢复，Return 恢复默认，按钮消失、JSON 自定义目录为 nil；后续焦点进入弹出窗口快捷键。
3. 工作树页默认目录的恢复按钮真实显示 disabled；Tab 路径由选择文件夹直接到自动清理开关，跳过禁用按钮，没有改变目录或偏好。
4. 最终版本实际点击 24 个设置导航页，逐次核对 heading 和主窗口 ID main；额外切换插件的 MCP／技能子页。
5. 设置搜索粘贴“开源许可”，Down／Return 定位到通用页末端。查看按钮在同一主窗口打开许可页，返回按钮先回通用；清空搜索后继续切页，Escape 最后回原任务输入。中文草稿“设置卡片原生验收草稿667”保持，实际输入焦点恢复。

标准脚本重启后，原任务与中文草稿保持，默认 Projectless 目录恢复、恢复按钮仍隐藏；同窗口设置返回后任务输入框实际取得焦点。构建／重启日志 `.cache/settings-actions-{native-build,focus-native-build,native-restart}-667.log`。最终通过标准脚本恢复默认工作区 other，实际任务输入框取得焦点，日志 `.cache/settings-actions-default-run-667.log`；原生观测汇总保存在忽略目录 `.cache/settings-actions-native-evidence-667.json`。原生按钮路径通过不代表鼠标实际悬停入口、所有控件和每页全部状态都通过；悬停像素目前为共享绘制状态验证。

## 完整性与剩余范围

保存 helper SHA-256 为 `1f6034fee07daf289b1764d60e58cf1ccea97b59097798778d8efffbe6e52532`。IPC／捆绑 Core 本地回环服务均 exit 0，日志 `.cache/settings-actions-{ipc,core}-667.log`。最终严格深度签名验证 exit 0，保存 helper 与当前包内 helper 的 CDHash 相同，日志 `.cache/settings-actions-final-signature-667.log` 与 `.cache/settings-actions-code-equivalence-667.json`。没有 Rust 源码改动，不声称重跑 Rust 全套或真实用户服务。

第 666 篇提交 9336030 的完整回归继续独立运行，使用冻结 native-ui-648；本阶段使用 native-ui-654。其 70 个源夹具（65 个测试夹具及 5 个工程／内容夹具）、163 个包资源、测试执行文件及保存 helper 摘要均复核未改；工程／内容夹具在 runner 的 sourceSha256 中也于启动前验证，补充清单为 `.cache/full-alignment-regression-666-fixture-audit.json`。未将运行中的结果计为通过，且该回归不覆盖本阶段。

全部按钮变体与精确视觉、所有字段／开关的焦点自动显示、每页全部状态与交互、真实服务、macOS 14 实际运行及完整双端配对继续未完成。Codex 窗口操作此前受工具安全限制，未绕过；公开组件证据不能代替双端页面验收。完整范围仍为 21 个主页面／交互类别、26 个设置验收面、29 项核心功能，完整配对 **0/47**。见[完整矩阵](599-core-function-parity-matrix.md)。
