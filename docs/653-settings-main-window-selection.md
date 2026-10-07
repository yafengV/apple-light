# 设置入口的主窗口选择

本阶段修正设置入口按窗口数组第一项捕获来源的缺陷。存在较早的非活动 `main` 候选时，设置现优先选活动主窗口，再选可见主窗口，保留原先隐藏场景和无主场景时的回退。没有更改设置在主窗口内呈现的设计。

## 原全量的终态

固定 `fa27fc9` 全量的原 handle `76513` 已返回 exit 1，状态文件记录结束于 `2026-10-07T11:29:46.765661Z`。Swift 结果为 **2,793 项、2 跳过、16 条失败断言、0 unexpected，4,531.578 秒**。日志 `.cache/full-alignment-regression-647.log`、状态 `.cache/full-alignment-regression-647-status.json`。6 个失败用例为：

- 旧主题搜索断言一项，已在第 649 篇按当前参考语义修正，但不覆盖原全量结果。
- `testChildComposerReturnWaitsForRetainedEditorToBecomeEnabled`。
- `testReenteredSettingsInvalidateThePreviousQueuedFieldRestoration`。
- `testSettingsReturnRestoresContentAndInspectorFileEditors`，涉及左/右/检查器来源。
- `testSettingsReturnRestoresOriginalStandalonePageField`，涉及项目/插件/技能/自动化来源。
- `testUnsavedConfirmationRetainsSourceUntilExitActuallyCompletes`。

本轮原全量中的文件搜索组通过，不能据此宣称此前的 400 毫秒间歇失败根因已修复。Swift 失败后 runner 没有执行后续 IPC。旧 55 个夹具、150 个资源、测试可执行文件和独立 helper 在终态后核验仍未改变。

## 缩小复现与修复

在当前源码上先运行浏览器站点工具确认用例，再运行设置返回组，11 项中出现子输入恢复的 3 条失败，日志 `.cache/settings-window-order-repro-653.log`。新增捕获窗口身份断言后，同组合另一次 11 项通过，日志 `.cache/settings-window-capture-diagnostic-653.log`；因此不能把这个组合描述为每次必现，也不能仅凭其先后顺序确认所有原全量失败的根因。

随后新增两个实际 AppKit 主窗口候选的确定性回归：将窗口数组中较早候选设为非活动，另一候选设为活动并持有子输入器。旧代码的来源窗口、返回焦点、保持原输入请求三条断言均失败，日志 `.cache/settings-window-active-repro-653.log`。这明确证明按数组首项捕获来源存在缺陷。

`PageNavigation.openSettings` 现按活动、可见、其余主窗口候选顺序选择来源，无主窗口时才使用当前 key window。原有 task/root/revision、弹层、未保存确认、子编辑器重新启用等待，以及非活动窗口不得抢回焦点的保护保持。新增可见但非活动窗口回归，既确认来源选择，也确认关闭设置后仍不会绕过非活动保护。

首个子输入用例另加入捕获窗口身份断言，失败时仅输出窗口类、可见/活动状态及预期/实际身份布尔值，不输出聊天、文件、查询、凭据或用户配置。原有最终焦点、选区、草稿和命令归属断言及等待时间均保留。

## 验证与边界

修复后的浏览器单项与设置返回组合 **13 项、0 失败/跳过，9.821 秒**，日志 `.cache/settings-window-selection-fixed-653.log`。正式包 helper 下扩大关联 **144 项、0 失败/跳过，46.413 秒**，日志 `.cache/settings-window-formal-associated-653.log`；范围包含浏览器全部、文件搜索返回、设置导航/返回、输入器、设置编辑器、命令/搜索弹层及相关外观交互。集合有重叠，不累加。

正式应用通过 `script/build_and_run.sh --app` 构建运行，日志 `.cache/settings-window-formal-run-653.log`；严格深度签名通过，日志 `.cache/settings-window-signature-653.log`。本阶段没有 Rust 或通信实现变化；正式 helper SHA-256 仍为 `380bec2aac119df2c9755850f1aa6150dd14cb9403a2eb8d42eff39e7f54ae9b`，第 652 篇对相同 helper 的 IPC/Core 冒烟证据保持，不能描述为本阶段重新执行了这些冒烟。

前台确认默认 `other` 工作区可交互，无持续 loading。由任务输入按 ⌘, 打开 `ID: main` 设置，Esc 回到原空输入焦点；技能页搜索框进入设置后，Esc 回到技能页并恢复原搜索焦点；最终返回 `other` 空输入。没有发送模型消息、修改真实服务或新建用户项目。

多个主窗口候选的排序在独立测试进程内验证，没有将该测试称为参考应用与 ShipiOS 全窗口的前台配对。原全量五个焦点失败是否全部因本次修复消失，仍须由最新源码的新固定全量确认。字体平滑的 SwiftUI/其余文字覆盖、文件搜索间歇根因及矩阵其余功能/页面缺口保持；完整双端配对仍 **0/47**。
