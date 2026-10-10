# 确认弹层连续按键选择

日期：2026-10-10。开发基线：`2f6ea7d4`。范围：R8 共用确认弹层的快速导航／激活，以及相关取消、草稿和返回验收；全部 R1–R8 仍未完成。

## 问题和修复

第 742 篇记录的未保存确认快速 Tab→Enter 问题，在真实 AppKit 前台宿主中复现。把 Tab 与激活键连续放入原生事件队列、不给 SwiftUI 留渲染间隔，Tab→Enter、Shift-Tab→Enter、Tab→Space 都执行旧的取消选择；原有 5 项前台方法通过，新增方法产生 6 条失败断言。修复前冻结输入未变，记录保留。

确认弹层现在用每个实例独立的 `ModalButtonSelection` 同步保存当前选择，FocusState 负责实际控件焦点和焦点环。连续原生键盘事件读取最新选择，不读取上一次渲染的 FocusState 快照。原生初次捕获仍聚焦取消，实际焦点变化会同步选择；保留忙碌禁用、Esc／Cmd+W、修饰键及原有激活按键阶段。快照提示弹层使用相同修复。

移除了仅检查旧 `activationTarget` 辅助计算的三条断言，改由真实事件交付测试验证动作。新增前台方法通过两种实际 SwiftUI 弹层，验证一次／两次 Tab、反向 Tab、Enter／Space、Esc、Cmd+W、Cmd+Enter 不激活、忙碌时不执行以及重复挂载。快照测试的启用回调仅记录次数，不申请或授予任何系统权限。宿主现在执行 **6 项**，未放宽真实关键窗口或冻结输入条件。

## 验证

- 产品源码关联 **70 项、0 失败／跳过、16.162 秒**：归档确认、确认返回焦点、设置导航／返回、快照相关和开关键盘。前台方法明确从命令行排除，另跑独立宿主。
- 最终原生前台 **6 项、0 失败／异常／跳过、25.232 秒**，源码／测试／脚本／测试包／资源／helper 冻结输入未变。新增方法使用真实 NSApplication 事件队列与实际 key window，没有伪造焦点。
- 标准 `script/build_and_run.sh --app` 打包启动 exit 0，Swift 构建 18.17 秒；严格深层签名、第 713 篇应用／helper 旧身份要求、稳定 Apple Development 签名及最新打包 helper 的 IPC 冒烟通过。

本机日志：`.cache/confirmation-associated-743-fixed.log`、`.cache/confirmation-foreground-743-{before,fixed}/{test.log,result.json,manifest.json}`、`.cache/confirmation-product-launch-743-{before,fixed}.log`、`.cache/confirmation-signature-743.json`、`.cache/confirmation-ipc-743.log`。

## 实际正式应用

使用隔离数据 `.cache/settings-confirmation-visible-743/data`，不填写密钥、不调用真实 API：

- 个性化未保存草稿切换通用页，连续 Tab→Enter 正确丢弃并完成切换；重新打开后此前保存的指令未被覆盖。
- 未保存草稿返回确认中连续 Tab→Tab→Enter 正确取消，内容保留；连续 Shift-Tab→Space 正确丢弃并回到原聊天，输入框获焦点。
- 模型无效地址保存有明确校验错误。返回确认中的 Cmd+W 只取消弹层，设置主窗口、草稿和错误仍保留；再次连续 Tab→Enter 正确丢弃并回到原聊天输入框。
- 最后恢复默认数据实例，工作区可交互，同主窗口设置与 Esc 返回输入焦点复验。

取消后留在设置页的焦点续接仍未通过：实际 Cmd+W 取消后，Tab 没有可见焦点变化，未观察到焦点环或辅助功能焦点。该路径继续原生定位，不把内容保留记作焦点恢复通过。其他设置页面、窄窗口和浅深色验收及真实用户 API 开发闭环仍继续；本轮没有重跑最新全部广泛回归，不宣称完全对齐。
