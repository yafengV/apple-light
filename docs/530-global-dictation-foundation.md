# 全局听写的热键与文本目标基础

Codex 的语音页包含“按住听写”和“切换听写”两种全局快捷键，它们把文字送到桌面当前光标所在的应用。ShipiOS 的原有听写只写入自己的任务草稿，现有 Carbon 全局热键也只处理按下事件，因此直接复用会把文字送错地方，且无法在松开时结束按住听写。

本阶段让 `AppGlobalHotKey` 可选地接收同一快捷键的释放事件；现有只需按下的宠物和弹出窗口热键行为保持不变。新增 `GlobalDictationTextTarget`，在开始前读取系统当前聚焦的可编辑文本控件、原文及选区。写入时重新核对原文和光标，任何变化都拒绝覆盖；优先使用辅助功能的“选中文字”替换，必要时才用完整文本值和更新后的光标。位置计算按 UTF‑16 单元，拒绝越界及落在代理对中间的选区。

合成 Carbon 按下／释放事件与 emoji 选区测试通过，正式应用构建及严格签名通过。**全局热键设置、按键与录音控制、授权提示、跨应用文字写入和可见状态尚未接入**，因此当前不能把全局听写描述为已可用，完整 Codex 双端验收保持 **0/47**。

接口依据：[Apple 的系统级聚焦元素](https://developer.apple.com/documentation/applicationservices/1462095-axuielementcreatesystemwide)、[辅助功能属性写入](https://developer.apple.com/documentation/applicationservices/1460434-axuielementsetattributevalue)、[选中文字属性](https://developer.apple.com/documentation/applicationservices/kaxselectedtextattribute)。
