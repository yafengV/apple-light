# HelloShipiOS 固定计数器验收

这是 ShipiOS 所开发的 iOS 演示工程，不是 macOS 客户端的模拟器替代。仓库中的 App 故意保持原始欢迎页；模型必须在隔离副本的 `HelloShipiOSApp.swift` 实现计数器。

固定的 `HelloShipiOSUITests` target 使用真实 XCTest UI 操作，要求：

- `counter.value` 静态文本初始为 `0`。
- `counter.increment` 按钮可点击，第一次点击为 `1`，第二次为 `2`。
- `counter.reset` 按钮可点击，点击后回到 `0`。

测试代码、Xcode project 和共享 scheme 是验收输入，模型不得修改；验证入口会检查它们与仓库一致。失败时截图保留在 `.xcresult`，不能仅用构建成功或截图代替断言。

先复用或创建名为 `ShipiOS-v0.1-Counter` 的专用 iOS Simulator 并启动，再将本目录复制到忽略的工作目录。真实模型改码结束后，从仓库根运行：

```sh
python3 script/verify_ios_counter.py \
  --project /absolute/path/to/isolated/HelloShipiOS \
  --simulator DEDICATED_DEVICE_UUID \
  --output /absolute/path/to/new/evidence-directory
```

入口先 build-for-testing，成功后才 test-without-building，默认每步上限 300 秒；编译失败不执行 UI 测试。编译经过仓库磁盘守卫，复用 `.cache/xcode-derived-data`。证据目录必须是新的、在工程之外；旧结果不会被覆盖。报告记录源码指纹、设备、命令退出码、实际用例和未运行／失败／通过状态，运行中输入变化不能通过。入口只验证、不修复、不提交代码，也不声明模型来源。

`script/smoke_ios_counter.py` 提供 `correct`、`bad-increment`、`compile-error` 三个受控场景：回环 Responses 服务发出补丁，实际 bundled Core 修改隔离 App，随后运行相同 UI 验收。后两个场景只有准确检测错误才算烟测通过，产品 UI 验证状态仍是失败或未运行。

```sh
python3 script/smoke_ios_counter.py --scenario correct \
  --simulator DEDICATED_DEVICE_UUID --output /absolute/path/to/new/smoke-evidence
```

这些场景证明工具链和失败检测，不能记作真实 API 的 A03 通过。T03 仍须用户配置服务的模型改码、工具报告、失败后的有界修复与接管、实际 macOS 窗口检查。
