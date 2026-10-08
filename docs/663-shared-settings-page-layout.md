# 设置页共享标题、边距与分区间距

日期：2026-10-08。继续对齐全部页面；本阶段修正已有侧栏布局的设置页面容器，不表示所有设置页已经完成配对验收。

## 参考与边界

Codex 26.930.51102 / build 13100 的公开分发资源：

- `app-initial-f9b16fbf8fc7.js`，SHA-256 `22f3ea455585cfc0508e3d3627eac161c80c849c0aace3d76d09fdebaa0aeca3`。
- `app-shared-6fb15e58cd7f.css`，SHA-256 `4ea4b25e3f4f3225a3bf212fa767afe7655b16bbd5919ebf4fb12c656f974720`。

`script/extract_settings_page_layout.cjs` 固定两个摘要，执行实际 `rvs` 页面和 `Z_s` 标题组件，记录普通／紧凑、嵌入／独立、旧侧栏／Slate 八个布局分支的类名。普通、非嵌入、旧侧栏分支使用 `heading-lg font-normal`、`max-w-3xl`、`p-panel`、`pb-8` 和 `gap-10`；CSS 对应标题 24 点常规字重、内容最大宽度 768 点、外边距 20 点、标题与内容间距 32 点、分区间距 40 点。其他七个分支仅记录参考类名，没有把这些分支的尺寸声称为已实现。

夹具为 `apps/macos/Tests/ShipiOSTests/Fixtures/settings_page_layout_reference_663.json`。没有执行网络代码或读取 Codex 的账户、项目、历史和个人配置。直接用原生 UI 工具读取 Codex 窗口被工具安全限制拒绝，因此本阶段没有双端实际窗口配对；未尝试绕过限制。

## 改动

- 共用页面标题从 25 点半粗改为 24 点常规字重；表单页与滚动页共用字号和标题后间距。
- 外边距从 24 点改为 20 点，总视口上限从 816 点改为 808 点，内容基准仍为 768 点。
- 滚动页标题与副标题间距改为 6 点；标题顶边距与页面底边距跟随 20 点外边距。
- 滚动页直接子分区间距从 20 点改为 40 点；各具体分区内部的控件间距仍由所属页面定义。
- 保持主窗口内设置路由、页面保留、标题跟随滚动、搜索定位与短暂高亮、筛选控件吸顶及返回来源焦点。

这些改动只修正已有侧栏页面布局的明确差异。原生分组 Form 的卡片、内边距和行高仍有系统样式，不据此声称已与 Codex 像素一致。Slate 导航、紧凑／嵌入分支、逐页控件、全部状态和动效继续待核对。

## 验证

首轮布局专项 **9 项、0 失败**，16.570 秒，日志 `.cache/settings-page-layout-associated-663.log`。新用例读取实际参考夹具，在 700 和 400 点宽度测量原生视图的左右边距、顶部位置和分区间距，并检查单一滚动容器。既有用例覆盖全部 24 个导航页的初始渲染、MCP／技能子页、长列表、窄窗口、搜索定位、标题滚动与筛选吸顶。离屏图在 `.cache/settings-page-layout-663-snapshots`；已检查通用和外观图，没有把离屏渲染等同实际操作。

扩大首轮 **449 项有 1 条失败**：`ShortcutSettingsStateTests.testRowEditorRendersAtCommandWithoutAdditionalScrollContainer` 仍硬编码旧 24 点边距。原日志 `.cache/settings-page-expanded-663.log` 保留。该断言现读取同一公开参考夹具的 20 点边距，不从生产常量取得期望值；未放宽误差或跳过断言。完整复测 **449 项、0 失败／跳过**，132.735 秒，日志 `.cache/settings-page-final-expanded-663.log`。范围包括设置、外观、桌面命令、恢复、归档与快捷键。

参考重提取逐字节相同，修改过的 CSS 输入会被摘要校验拒绝，日志 `.cache/settings-page-reference-663.log`。正式构建通过，日志 `.cache/settings-page-native-build-663.log`。保存的 helper SHA-256 为 `ac04146563e88ba8b3891d9935df09133101594f673a7afa7a8546ac8b8057cb`；独立 IPC 和捆绑 Core 本地服务冒烟均 exit 0，日志 `.cache/settings-page-{ipc,core}-663.log`，严格深度签名 exit 0，日志 `.cache/settings-page-signature-663.log`。没有 Rust 代码变更，不声称重跑 Rust 全套。

原生应用使用独立 `.cache/settings-page-native-663/Data`，没有复制用户 API 或凭据。实际逐一点击 24 个设置导航页，确认主窗口 ID 始终为 `main` 且当前页标题出现在可访问树；额外操作插件内 MCP 和技能子页。搜索“底部面板”，Down／Return 后实际滚动到该开关；最初没有选中搜索结果时单独 Return 没有跳转，没有把它计为成功。返回按钮及再次进入后的 Escape 均回到任务输入，中文草稿“设置页面原生验收草稿663”和唯一任务保持。记录 `.cache/settings-page-native-evidence-663.json`。这些操作证明初始页面可切换与指定返回路径，不证明各页全部控件或全部状态已验收。

通过标准脚本重启独立实例后，恢复指示结束、任务与中文草稿仍在，实际设置往返与输入焦点再次通过，日志 `.cache/settings-page-native-restart-663.log`。再通过标准脚本恢复默认 `other` 工作区并实际点击输入框获得焦点，日志 `.cache/settings-page-default-run-663.log`。最终应用严格签名 exit 0，日志 `.cache/settings-page-final-signature-663.log`；最终 helper 与扩大回归使用的保存副本 CDHash 相同，见 `.cache/settings-page-default-code-equivalence-663.json`，重新签名的 CMS 元数据不作为代码相同的证明。

## 后续范围

完整范围仍为 21 个主页面／交互类别、26 个设置验收面及 29 项核心功能。详细剩余项见[完整矩阵](599-core-function-parity-matrix.md)。现有界面实现和关联测试不等于全状态、全交互的双端验收，完整配对继续为 **0/47**。

第 662 篇固定全量回归使用旧提交 `ecc2fe0`、独立 `native-ui-648` 产物、67 个源夹具、160 个包资源和保存的 helper。本阶段使用 `native-ui-654`，不重写被冻结的包、夹具及 helper；该全量结果不覆盖本阶段。

本阶段结束前再次确认第 662 篇回归句柄仍在运行，67 个源夹具、160 个包资源、测试执行文件与 helper 摘要均未变化；没有把等待中结果计为通过。
