# 模型选择器的推理档位

2026-09-26。安装在本机的 Codex 客户端资源显示：模型选择弹层在具有多个可选档位时，可先显示简洁的推理滑杆，再进入完整模型列表。ShipiOS 现在仅在独立服务的 `/models` 结果明确声明当前模型支持的推理等级时显示离散滑杆。滑杆包含“服务默认”，按可见等级排序；进入完整列表后仍可搜索、键盘选择和手动输入模型 ID。已选等级被隐藏或与服务声明冲突时保持完整列表和明确提示，避免滑杆显示错误的当前值。

除了 `supported_reasoning_efforts` / `supportedReasoningEfforts`，也读取 Codex 模型元数据常见的 `supported_reasoning_levels` / `supportedReasoningLevels`，其中对象的 `effort` 字段作为档位。模型列表同时识别标准兼容 API 的 `data[].id` 与 Codex 模型目录的 `models[].slug`。服务未返回这些能力时，继续提供原有模型列表与下拉框，不推测其支持范围。

这仍未达到 Codex 当前模型弹层的完整配对：其预设可能同时切换模型版本与推理等级，而标准独立服务 `/models` 通常只返回模型 ID；当前实现的滑杆只改变同一模型的推理等级。Mac 锁屏期间无法完成两侧的外观、拖动、焦点和键盘验收。

模型选择相关 11 项测试、`script/build_and_run.sh --build-app` 和应用签名校验通过；这些验证不替代原生交互对照。
