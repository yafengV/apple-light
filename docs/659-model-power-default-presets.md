# 默认 Power 档位跨模型选择

日期：2026-10-08。

## 参考与范围

固定公开 Codex Mac 版本 `26.930.51102`、build `13100` 的资源 SHA-256 `22f3ea455585cfc0508e3d3627eac161c80c849c0aace3d76d09fdebaa0aeca3`。新脚本 `script/extract_model_power_presets.cjs` 只在隔离 VM 中运行公开纯函数 `R9r/G9r/I9r` 及其默认常量，不读取账户、私有会话或应用运行状态。提取 10 组实际参考结果到新夹具 `model_power_presets_reference_659.json`，未改动运行中全量回归捕获的旧夹具。

参考默认主档位从 Terra Low 到 Sol Low/Medium/High/XHigh/Ultra；按实际能力过滤后至少三档才使用。主档位不足时尝试 Terra 的 Low/Medium/High/XHigh，仍不足则不提供默认预设。过滤不会重排预设，参考中的原始 `powerSettingIndex` 也保留。默认参考已选档位匹配时可跨模型；明确指定模型时保留该模型自己的实际能力顺序。

## 实现

- `ModelPowerSelection` 用模型 ID 与推理强度共同标识每个档位，过滤隐藏模型、缺失能力和未开启的高级强度。代码中的参考模型名称不代表当前服务可用。
- 默认档位中的滑杆移动同时保存模型与推理强度；任务弹层仍只更改该任务的模型选择，不改全局 API 配置。选中档位未变化时保留省略推理参数的服务默认语义。
- 完整模型列表选择后保存指定模型模式；“使用默认档位”恢复参考 fallback 档位及默认模式。模式独立保存在工作区，旧数据缺省为自动推断。模式保存与模型请求配置保存属于独立动作，分别报错；不宣称跨文件事务。
- 键盘左右键、边界、Return 和可访问性增减沿用实际原生滑杆。默认档位标签包含模型与强度，明确模型模式显示该模型的推理强度。

## 验证

第一轮关联 **26 项通过**，日志 `.cache/model-presets-associated-659.log`；扩大 **358 项、0 失败/跳过**、284.704 秒、exit 0，日志 `.cache/model-presets-expanded-659.log`。这两次均在后续高级列表修复前完成，不能用它们证明该修复。

正式窗口发现原高级列表在弹层中压缩到零高度，条件挂载搜索框也未获得焦点。现为列表提供有界高度，在文本框挂载后重新请求焦点，并给实际模型行提供明确可访问标签。新增测试最初尝试读取隐藏 SwiftUI 虚拟按钮，但只有 AXGroup 可读，两个定位尝试分别失败；日志 `.cache/model-presets-layout-focus-659.log`、`.cache/model-presets-layout-focus-diagnostic-659.log` 保留。测试改为进入相同高级内容后检查实际 NSTextField 的 firstResponder 与 NSScrollView 高度，不假称隐藏按钮已验收。修复后 **26 项、0 失败/跳过**、4.475 秒、exit 0，日志 `.cache/model-presets-layout-focus-final-659.log`。

正式包已在独立 `.cache/model-presets-native-659/Data` 与本机能力服务中验证 Sol → Terra → Sol 的方向键跨模型选择、最低边界、搜索框自动聚焦、两条可见模型行、输入 terra 后 Return 选择及返回中文草稿输入焦点；明确模型模式实际显示该模型自己的档位。全局模型仍为 global-659/high，任务保存独立。原生夹具首次项目路径替换错误已修正后重启，未归为产品问题。正式包重启后 Terra Low 仍保持明确模型模式及原草稿，随后实际默认按钮恢复 Sol Medium，再按两次左键切到 Terra Low；返回设置/退出均为同一个 ID: main 窗口并恢复原输入焦点。最终模式落盘为 default，原全局配置与中文草稿保持，本机夹具只有 GET、没有模型 POST，证据 `.cache/model-presets-native-evidence-659.json`。

最终构建 `.cache/model-presets-final-native-run-659.log`、严格深度签名 `.cache/model-presets-signature-659.log` 通过；IPC/Core 日志 `.cache/model-presets-ipc-659.log`、`.cache/model-presets-core-659.log` 均 PASS、exit 0。已通过项目脚本恢复默认 other 工作区，原生点击输入、⌘, 同窗口设置、Esc 返回空输入焦点通过，日志 `.cache/model-presets-default-run-659.log`；本机验收服务已停止。最终正式 helper 快照 SHA-256 `ff98c94558ef811d37eeb0170b07ad67b9f94dbd914a14e8dc019cd03a610942`，严格签名与相同 helper 的 IPC/Core 均通过，日志 `.cache/model-presets-verified-{signature,ipc,core}-659.log`。最终相同 helper 的扩大回归 **358 项、0 失败/跳过、0 unexpected**、283.744 秒、exit 0，日志 `.cache/model-presets-verified-final-expanded-659.log`。覆盖模型/推理、实际两种协议请求、任务/子会话模型隔离、持久恢复、工作区标签及设置焦点。参考脚本重跑与新夹具逐字节一致，新本机服务 Python 语法检查和 `git diff --check` 通过；没有 Rust 源码改动。

固定第 657 篇全量回归在提交 `1cf6f0b917324c12549c4404189fdeda0d4d6417` 启动，捕获 63 个夹具、155 个 bundle 资源及实际二进制散列，独立使用冻结的 `native-ui-654` 缓存；不覆盖本阶段改动。本阶段使用已结束旧回归的 `native-ui-648` 缓存。

## 尚未完成

服务端动态预设、服务明确默认模型的优先 fallback、档位精确视觉与拖动/动效、完整高级列表的全部键盘和焦点路径，以及真实用户服务与整页双端验收仍需完成。公开纯函数及有限原生验证不等于完整页面验收，全部 47 类页面/交互配对计数保持未完成。
