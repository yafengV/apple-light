# 紧凑模型菜单的原生焦点循环与输入框隔离

日期：2026-10-08。

## 公开参考

继续固定 Codex Mac `26.930.51102`、build `13100`：primary SHA-256 `234429db84d9319850ff0766a4a5052a9e898bfa0611883633f80018080dd6c0`，initial SHA-256 `22f3ea455585cfc0508e3d3627eac161c80c849c0aace3d76d09fdebaa0aeca3`。只读取公开发布资源中的局部函数，不操作 Codex 的个人会话或设置。

`U0e` 的模型切换和恢复默认均为可交互菜单项；`w0e` 的键盘档位控件也是菜单项，内部另有真实 slider。`X0e` 普通 Tab / Shift-Tab / 上下键循环经过菜单项，实际 slider 子目标不参与该捕获。`w0e` 普通左右键调整一档并提交，边界不重复选择；Enter 完成。只有特殊 `ComposerNavigation` 事件才让上下键改档。

新增 `script/extract_model_power_keyboard.cjs` 在隔离 VM 执行 `w0e` 的键盘闭包及 initial 的纯函数 `B9r`，提取 14 组结果。自动化原生菜单只比较其中普通、未锁定的事件；特殊 ComposerNavigation 和锁定 Enter 的参考结果保留，不声称已实现这些产品能力。

继续复核 `X0e` 的焦点 effect：键盘激活后的视图切换优先选中有效单选行，再找当前视图首个交互项。因此从完整列表通过 Enter/空格返回紧凑视图，应该聚焦模型按钮；键盘恢复默认使原按钮移除后也应回到首个交互项。指针来源和已有焦点走另一分支。新增 `extract_model_menu_focus.cjs` 独立执行该 effect 的 11 组输入，记录这些边界，完整来源语义仍未全部实现/配对。

## 实现

- `ModelPickerMenuFocus` 扩展为持有本选择器的弱 NSView 引用，供完整列表、紧凑模型按钮、恢复默认和键盘档位共用。同窗口、可见、启用、实际可接受焦点的控件才能进入循环；没有全局键盘监控。
- 紧凑两个动作改为原生 menu item；完整列表保留单选角色。图标和文字沿用主题颜色，响应器与选中数据仍由 SwiftUI 管理。
- `ModelPowerSlider.KeyboardControl` 承接菜单键盘路径；内部 NSSlider 保留鼠标和辅助访问的实际档位操作。普通上下键只移动菜单焦点，左右键改档，Return 完成。关闭或拆卸使键盘及保留的旧 pointer slider 均失效。
- 紧凑/完整视图变化重新配置有效焦点；记录原生 Enter/空格激活来源，键盘选择模型返回紧凑视图或恢复默认移除原动作后聚焦模型按钮，保存失败保持原动作并允许重试。指针/辅助访问来源暂保留现有档位焦点，不把它宣称为全部参考来源语义已对齐。模式和模型配置仍分别保存，不宣称跨文件事务。
- 主窗口打开模型菜单时清除输入框的期望焦点；主窗口和独立任务窗口向 ComposerTextEditor 传递明确的 focusAllowed。旧的排队焦点请求和设置返回请求在菜单占用时不能抢回输入，菜单关闭后才恢复。
- 初始原生焦点只在应用已激活、目标窗口可见且可成为 key 时请求该窗口成为 key。隐藏测试窗口不被激活。信息日志仅记录菜单窗口焦点布尔状态，不记录模型、草稿、文件或凭证。

## 失败与修正记录

最初在默认工具沙箱运行基线时，本机能力服务无法正常启动，产生服务端口及模型动作两条失败，不能作为有效产品基线。随后在正常测试权限下重跑：**1 项、1 条失败**，紧凑模型动作不存在原生响应器，日志 `.cache/model-compact-verified-repro-662.log`。

第一轮关联 **23 项、1 条失败**：能力/模式变化直接从紧凑退回完整列表时，焦点没有重新落到默认行。现按视图类型切换使旧焦点代次失效，日志 `.cache/model-compact-associated-662.log`。新增参考夹具曾放错 SwiftPM 资源目录，两轮各 **28 项、1 条失败**均在 URL 解包处，非按键结果失败；已移到 ShipiOSTests/Fixtures。修正后 **28 项、0 失败/跳过**、11.370 秒，关闭保留 slider 的保护加入后再次 **28 项、0 失败/跳过**、11.571 秒。

原生验收又复现菜单首个 Tab/上键关闭，按键落入自有测试草稿。输入框焦点保护单独加入后，关联 **34 项、0 失败/跳过**、12.868 秒，但实际 Tab 仍曾失败，故未计为完整修复。窗口诊断记录原生菜单 `isKeyWindow=true` 但与 `NSApp.keyWindow` 不同；随后补充可见窗口 key 请求，最终快捷键入口、按钮入口及重启路径连续通过。该记录不能单独证明所有历史意外关闭只有一个原因；失焦、重新激活及所有来源组合仍待继续。

测试夹具复制时旧项目路径没有递归替换，已在自有 JSON 中修正并重启。一次界面工具在标准脚本完成前重新启动默认实例，已改为等待构建终态后单实例重启。失败验收插入的 Tab/换行仅发生在自有草稿，已通过应用恢复原文；未发送请求。

## 原生验收与最终验证

独立 `.cache/model-compact-native-662/Data` 使用自有 loopback 能力服务。最终正式包实际走通 Tab / Shift-Tab / 上下循环、左右改档、空格恢复服务默认 Terra Low、键盘进入完整列表、选择 Sol 和继续改档、Return 返回原中文草稿；模型设置入口与 ⌘, 仍使用同一 `ID: main`，Escape 返回输入。最终重启恢复明确模式、Sol Medium 和原草稿；默认 other 工作区随后通过标准脚本恢复，实际输入与同窗口设置返回可交互。

原生证据 `.cache/model-compact-native-evidence-662.json`：明确模式、任务 Sol Medium，全局仍 global-662/high，草稿为原 `跨模型原生验收草稿662`，17 次 GET、无 POST。自有能力服务已停止。鼠标滑杆的普通上下排除通过隐藏原生窗口测试；本轮 AX click 未把实际焦点移到内部 slider，因此不把该前台步骤记为指针路径验收通过。主窗口截图未包含弹层像素，也不当作弹层精确视觉验收。

键盘切换焦点修正前的扩大回归 **381 项、0 失败/跳过**、294.669 秒、exit 0，日志 `.cache/model-compact-final-expanded-662.log`。随后严格按公开 effect 修正键盘返回首项；最终关联 **34 项、0 失败/跳过**、12.519 秒，日志 `.cache/model-compact-transition-final-associated-662.log`。最终正式包实际确认恢复默认后焦点落模型按钮、列表 Return 选择后也落模型按钮，再上键到档位继续改档；重启、原草稿和同窗口设置返回再次通过。最终原生证据 `.cache/model-compact-transition-native-evidence-662.json` 为 **4 GET、无 POST**，任务 Sol Medium / 明确模式，全局及原草稿保持，自有服务已停止。

最终相同 helper 的扩大回归 **381 项、0 失败/跳过、0 unexpected**、304.986 秒、exit 0，日志 `.cache/model-compact-transition-final-expanded-662.log`。保存 helper 与正式包 helper SHA-256 均为 `e52641406fa97c2705b42fc6018e49423f6979b666b29b297f0b9417099f43ba`。相同 helper 的 IPC/Core 冒烟与正式包严格深度签名均 exit 0，日志 `.cache/model-compact-transition-final-{ipc,core,signature}-662.log`。两个公开提取脚本重跑均与提交夹具逐字节一致。没有 Rust 源码改动，未重跑或重新声称既有 195 项 Rust 测试。

最终默认工作区通过标准脚本恢复并实际确认输入焦点，日志 `.cache/model-compact-transition-default-run-662.log`。本阶段提交后启动新的固定提交全量；运行期间冻结 native-ui-648、保存 helper 和捕获的夹具/资源，下一阶段使用 native-ui-654。未取得终态前不计全量通过。

第 657 篇固定提交 `1cf6f0b917324c12549c4404189fdeda0d4d6417` 全量已取得终态：**2,846 项 Swift、2 跳过、0 失败、0 unexpected**，4,573.777 秒，及 IPC exit 0。两项跳过均为未配置本机实时语音预览 WebSocket 夹具。原 handle 28406 已确认 exit 0，状态 `.cache/full-alignment-regression-657-status.json`；捕获的 63 个夹具、155 个资源、测试可执行程序及 helper 哈希复核未变。该固定结果不覆盖第 659—662 篇。

## 尚未完成

动态服务预设、锁定/解锁、速度层级和 ComposerNavigation 产品路由；所有指针/键盘激活来源及重新激活、失焦、意外关闭组合；精确尺寸、材料、拖动、过渡及辅助访问播报；NSHosting AttributeGraph 警告来源；真实用户服务及完整页面双端配对仍缺。全目标继续保留 47 类页面/交互与 29 项核心要求，完整双端配对仍 **0/47**，不是代码实现比例。
