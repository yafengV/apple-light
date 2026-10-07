# 文件搜索进度测试的启动就绪边界

日期：2026-10-07。接续[第 654 篇](654-workspace-search-source-focus.md)。本阶段只改测试准备，不改生产搜索会话、查询超时或 UI；完整双端配对保持 **0/47**。

## 证据与验证范围

第 654 篇正式 helper 扩大关联 243 项中，`testPartialResultsKeepAWorkingSearchAlive` 约 0.425 秒失败，没有收到响应，子夹具的 boot、query-read 和 emitted 标记全部缺失。原测试要验证五次间隔 150 毫秒的有效进度可以持续更新 400 毫秒查询期限，却在 `Process.run` 返回后立即提交查询，默认新 shell 已经开始执行。

新增 `testPartialResultsKeepAliveAfterSlowFixtureStartup`，让同一 shell 夹具在写 boot 前明确等待 600 毫秒。保持原生产代码和 400 毫秒期限、不等待就绪时，稳定出现 **1 项、1 条失败、0 unexpected，exit 1**，日志 `.cache/search-fixture-startup-repro-655.log`；查询约 0.407 秒超时，标记同样全部缺失。这证明该进度测试原先会把未就绪的夹具启动时间算入查询，而不能单独衡量进度续期。

这不证明生产会话超时逻辑错误，也没有定位之前 macOS 调度或文件系统启动延迟的底层来源。第 647/650/654 篇原全量和扩大集失败记录继续保留。

## 修正

两个进度用例现在共用同一验证函数，在提交查询前等待夹具 boot 标记；准备轮询最多 3 秒，未就绪明确失败。查询仍使用 **400 毫秒**期限，夹具仍每 150 毫秒发送五次 incomplete 和最终 complete，全部六次结果断言保留。失败诊断将先前的 launch 时长改名为 `launchAndReadiness`，查询耗时仍单独记录。

真正的无响应进程、无效协议和进程退出用例没有就绪等待或期限调整；默认生产会话 20 秒查询期限也未更改。新慢启动用例确保准备与查询的验证边界不会再次混在一起。

## 结果与剩余工作

使用正式包 helper 的 `WorkspaceFileSearchSessionTests` **14 项、0 失败/跳过，5.533 秒，exit 0**，日志 `.cache/search-fixture-startup-fixed-655.log`。包括原进度、新慢启动、真实 bundled helper 搜索、原始 100 毫秒停滞超时、错误/退出、旧期限与已读响应竞争、合并管道帧和替换查询隔离。

使用相同正式 helper 重跑第 654 篇的原扩大集合，并包含新慢启动用例，最终 **244 项、0 失败/跳过，60.931 秒，exit 0**，日志 `.cache/search-fixture-startup-formal-associated-655.log`。新增搜索焦点 9 项及原设置/独立窗口/终端/浏览器/文件/输入器等组均在集合内；这是关联集合结果，不是当前源码全量或前台验收。本阶段不新建模型请求、不修改运行数据或凭据。正式应用和 helper 沿用第 654 篇构建，helper SHA-256 `380bec2aac119df2c9755850f1aa6150dd14cb9403a2eb8d42eff39e7f54ae9b`；没有新的构建、前台或 IPC/Core 冒烟结论。

第 653 篇固定 `b4e81aa` 全量仍使用原二进制/资源和 handle `91319`，不覆盖第 654 篇产品修改或本阶段测试准备。原始扩大集失败不会因后续通过而被改写。第 654 篇前台搜索取消/结果导航验收因 Mac 锁定仍缺，其他 UI、核心功能与逐项双端配对继续未完成。
