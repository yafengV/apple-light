# 原生前台验收宿主与工作树准备页辅助功能

日期：2026-10-10。开发基线 `54e1391`。交付范围仍为第 726 篇的 R1–R8；本篇补 R4／R7 的部分前台证据，不表示两组或全部核心交互已完成。

## 产品修复

工作树准备页原先直接给外层 VStack 设置 `worktree-fork-preparation`。实际挂载后，该标识传播到 SwiftUI 子节点，覆盖取消／继续等按钮的标识。现在外层声明 `.accessibilityElement(children: .contain)`，保留页面容器和可分别操作的子控件。取消、重试、返回逻辑不变。

## 可复用前台验收

新增 `script/test_macos_foreground.py` 和 `script/macos_foreground_test_host.swift`。运行器加载已经编译的原 XCTest 方法，在正常 AppKit 应用中显示“开始验收”。实际点击后，先确认应用活跃且启动窗口成为关键窗口，再由 AppKit 回调运行测试；保留异步 MainActor 所需事件循环。

复制测试包、SwiftPM 资源和指定 helper 到本机临时目录，不读取个人 Codex 配置。记录测试次数、断言失败、异常、跳过、终态和输入哈希；缺少测试、未结束、超时、输入变化或异常都返回失败。`open` 成功本身不等于测试通过。

工作树夹具现在通过节点实际实现的 Objective-C 辅助功能方法遍历／按下按钮。SwiftUI `AccessibilityNode` 不声明 `NSAccessibilityProtocol`，原来的协议转换会漏掉实际可操作的节点。

两项原生方法保留关键窗口、编辑器焦点、文本选择、同窗口呈现、实际取消／继续按钮、来源草稿和工作树归属断言。普通命令行测试未显式启用前台时，这两项按前台需求跳过，必须另跑上述宿主，不能将跳过记为验收成功。

在实际观察期间，macOS 会往 `NSApp.windows` 加入 `NSLocalWindowSharingWindow`。最终窗口数量比较只排除此已确认的系统共享覆盖层，其他 NSWindow／NSPanel 均保留；没有重写 `isKeyWindow` 或忽略应用新增弹窗。

复现示例（需先编译测试，Mac 保持解锁、可交互）：

```sh
xcrun swift build --build-system native --package-path apps/macos \
  --scratch-path .cache/native-ui-654/macos-build \
  --cache-path .cache/native-ui-654/swiftpm-cache --disable-sandbox --build-tests
python3 script/test_macos_foreground.py --interactive \
  --build-path .cache/native-ui-654/macos-build/arm64-apple-macosx/debug \
  --agent target/debug/shipios-agent --output .cache/foreground-local-run
```

点击验收宿主的“开始验收”，运行期间避免操作其他窗口。输出目录必须是新的目录；需要现成 helper，必要时先 `cargo build --locked -p shipios-agent`。该宿主不代替通过 `script/build_and_run.sh` 启动产品。

## 构建工具链

`script/build_and_run.sh` 和 `script/test.sh` 现在使用所选 Xcode 的 `xcrun swift`，避免用户安装的旧独立 Swift 干扰。默认指定原先 SwiftPM 的 native 构建器，保持当前 SwiftTerm 资源处理；可用 `SHIPIOS_SWIFTPM_BUILD_SYSTEM` 显式切换构建器。本机 Xcode 的新默认构建器此前在 Metal 编译阶段失败，记录保留。native 构建器有上游弃用提示，未来更换需验证资源及打包结果。

## 本轮证据和范围

- 关联命令行回归：`PinnedBrowserRenameTests` 11 项和 `TaskMenuNativeForkTests` 30 项，合计 **41 项、0 失败／跳过、186.454 秒**；两项前台方法明确从这轮排除。其他指定名称没有匹配测试，不记为已覆盖。这轮在最终系统覆盖层过滤收尾前执行，执行方法本身未因该收尾改变。
- 最终原生宿主：两项完整原方法 **2 项、0 失败／异常／跳过、17.791 秒**，所有冻结输入未变。覆盖行内改名失焦保存、固定标签同窗口改名及全选、工作树准备页实际取消／继续、来源草稿、同一检出及子任务打开。数据和 Core 响应使用受控夹具，不能替代真实模型开发闭环。
- 标准独立打包 exit 0，随后通过 `script/build_and_run.sh --app` 启动最新版。实际主窗口可操作，无持续恢复 loading；Cmd+, 在 `main` 内打开设置并聚焦搜索，Esc 返回并聚焦输入框。本轮未观察到新的文件夹信任提示。
- 稳定 Apple Development 签名、严格深层验证及第 713 篇旧 designated requirements 均通过。IPC 冒烟通过：doctor、流事件、重放、报告、日志、立即重跑、构建取消、重启持久化和帧大小限制。
- 重建前的第 735 篇包另做外观页实际验收：浅色点击、方向键切深色、恢复系统模式、Esc 返回输入框；与最新包入口验收分开记录。

本机未提交证据：`.cache/foreground-associated-736.log`、`.cache/foreground-native-overlay-fixed-736/{test.log,result.json,manifest.json}`、`.cache/foreground-package-736.log`、`.cache/foreground-product-launch-736.log`、`.cache/foreground-ipc-736.log`、`.cache/foreground-stage-evidence-736.json`。

失败和中间诊断保留：第 735 篇前台失败、本轮命令行宿主失焦、原生宿主初始化／事件循环试验、辅助功能遍历失败和系统共享窗口数量失败，均不改写为通过。最终适配前最近一次冻结复验仍失败 1 条窗口数量断言，见 `.cache/foreground-native-current-736/`；最终适配后的独立运行见 `overlay-fixed` 目录。

真实 API 仍待用户在应用设置保存服务。R1／R2／R6 的真实开发闭环，以及 R3／R4／R5／R7／R8 的其他页面、冷恢复、焦点和状态验收继续进行；没有重跑最新全部广泛回归，没有宣称完整对齐。
