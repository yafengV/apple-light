# 已登记全局快捷键的录制路由

日期：2026-10-08，接续第 683 篇。范围保持 47 类页面／交互与 29 类核心功能，完整双端配对尚未完成。

## 复现与实现

仅依赖 NSEvent 的录制框收不到已被自有 Carbon 全局注册截获的按键。实际语音页面的旧路径分别在隐藏普通窗口及受控 key-window 条件下得到 **1 项、2 失败**（`.cache/registered-shortcut-capture-before-684.log`、`.cache/registered-shortcut-capture-before-key-684.log`）：送入本测试进程应用事件目标的已登记 Carbon 事件后，页面仍在等待录制，计数仍为 1。

AppGlobalHotKey 在主线程事件回调中判断当前录制框，将其已登记组合交给该框的绑定入口，按焦点代次与注册代次拒绝迟到输入。已由录制接收的按下、重复和对应松开不再触发原全局动作；普通全局按下与松开保持原行为。活动录制要求 key window、第一响应器及没有 sheet／应用模态窗口，不保存全局视图引用。窗口或应用失活结束录制并清理监视器。

语音、通用快捷键、按键搜索和弹出窗口录制均接入绑定入口，沿用原验证和保存逻辑。搜索与弹出窗口增加录制会话身份，防止旧事件修改下一次录制。页面接线与原生 Carbon 路由验证不等于真实系统键盘投递或全部跨模块冲突已验收。

## 回归定位

首轮 **87 项、4 失败（1 unexpected）**（`.cache/registered-shortcut-capture-focused1-684.log`）。取消测试的三条旧断言仍期待应用失活后继续录制，现改为检查失活取消、原值保留、旧指针松开无法取消下一轮、下一轮可正常取消。

其余异常单测独立通过，顺序组合稳定失败。LLDB 的 Swift throw 栈显示后一测试的 Carbon 注册冲突，同时失败清理中系统 Gestures／NSPanGestureRecognizer／HostingScrollView 析构产生 `InvalidTransition`（`.cache/registered-shortcut-capture-swift-throw-stack-684.log`）；没有证据把整个问题归为 SwiftUI 本身。新测试 action 强持有 store，store 连接控制器再持有 action，形成循环使上个注册未释放。改为弱引用后，**89 项、0 失败／跳过、36.637 秒**（`.cache/registered-shortcut-capture-focused-final-684.log`）。单独卸载隐藏窗口并未修复该问题，最终没有保留该试探。

测试使用真实 Carbon 注册／处理器和 `SendEventToEventTarget`，窗口保持隐藏，仅对 key-window 谓词提供受控值；既不是真实 OS 键盘注入，也不证明前台按键、指针路由或 VoiceOver。第 681 篇全量继续冻结在 native-ui-654；本阶段使用 native-ui-648，不覆盖其执行文件、资源和原源夹具。

在 89 项通过后补查注册变化时的配对释放，新用例旧代码 **1 项、2 失败、1.032 秒**（`.cache/registered-shortcut-capture-registration-release-before-684.log`）。提交新注册时不再重置已归属录制的按键状态，对应松开仍被消耗；旧注册排队输入继续按注册代次丢弃。最终专项 **90 项、0 失败／跳过、37.032 秒**（`.cache/registered-shortcut-capture-focused-verified-684.log`），与中间 89 项重叠，不累加。

2026-10-09 最终扩大回归 **642 项、0 失败／跳过、217.642 秒**（`.cache/registered-shortcut-capture-expanded-684.log`），与专项重叠，不累加。覆盖设置、外观、快捷键、恢复、语音记录等关联范围，不是全部核心功能的全量测试。

标准 `script/build_and_run.sh --app` 构建与启动命令 exit 0（`.cache/registered-shortcut-capture-build-run-684.log`）。正式 App／helper 均为 Apple Development，主应用代码哈希变化、指定要求稳定，均通过上一版要求与严格深度校验；helper CDHash 与验证版本相同（`.cache/registered-shortcut-capture-code-equivalence-684.json`）。本地 IPC／Core RPC 冒烟均 exit 0。最终 CUA 仍返回 Mac 锁屏，不能完成本阶段工作区可交互或新快捷键前台验收；启动命令成功不代替这些验收。

## 待验收

真实 OS 键盘→Carbon→AppKit、全局触发、全部布局／Fn／模态来源、整窗重开仍缺。通用快捷键对语音组合的反向冲突、宠物／弹出窗口保存与注册完整事务、裸修饰键权限／监视器事务、语音提示音／双击免提及完整实录／转写／播放／跨应用写入继续待完成。没有调用用户真实 API 或新增系统权限，完整双端配对仍为 **0/47**。
