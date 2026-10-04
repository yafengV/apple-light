# 归档流式验证的启动与输出等待

接续[核心矩阵](599-core-function-parity-matrix.md) C04/C06/C12。全量 `script/test.sh` 在 `ActivityArchiveTransportTests.testCoreArchiveCommandStopsActualStream` 中遇到一次等待失败：任务仍为 running、回复为空，夹具没有模型请求记录。随后原编译产物中的同一用例单独运行通过（0.500 秒）。当前证据指向启动/请求准备等待不足，但没有证明原失败的确切耗时来源，也不能据此宣称全量回归通过。

## 本轮修正与验证

- 归档测试按实际夹具 POST 记录区分启动/请求准备与模型输出：前者上限 15 秒，后者仍为 5 秒。任一阶段失败都会报告实际任务状态和请求记录。
- 收到部分回复后，额外断言任务仍处于 running，防止已经完成的回复被当成停止流式任务的证明。
- 新增真实 Agent 前的 6 秒启动包装脚本；仍需实际 Core 请求和未完成的部分流式输出，随后走命令归档、并行任务隔离、队列/草稿保留和磁盘归档记录检查。包装脚本仅位于私有临时测试目录。
- 使用独立 Swift 构建目录，保留正在运行的全量测试产物及 Python 夹具不变。11 项归档测试通过（`.cache/archive-delayed-startup-regression.log`，16.655 秒），其中延迟用例 13.283 秒；覆盖 Chat Completions/Core Responses 两种协议以及 Activity 批量、单行、侧栏、命令和独立任务窗口五种归档入口。

## 未完成项

延迟用例等待另一个启动中的任务取消时仍会等待其启动结束；需要另外验证并修复启动期间的及时取消，不能把本轮拆分等待预算当作该产品行为的修复。全量测试针对上一提交 `f96b997`，运行时已确认一项失败且其余用例继续执行；专项通过没有覆盖全部 macOS 测试，也未覆盖真实外部 API、前台鼠标/键盘或完整 Codex 配对。Mac 当前锁定，本轮没有新前台证据，完整配对仍为 **0/47**。

## 复现

```sh
CLANG_MODULE_CACHE_PATH="$PWD/.cache/archive-regression-clang" swift test \
  --package-path apps/macos --scratch-path "$PWD/.cache/archive-regression-build" \
  --cache-path "$PWD/.cache/archive-regression-swiftpm" --disable-sandbox \
  --filter ActivityArchiveTransportTests
```

当前 `target/debug/shipios-agent` 必须已构建；使用本机临时 HTTP 服务，不需要外部密钥。源码变化仅为测试，没有把已有正式应用构建算作本轮新的页面验收。
