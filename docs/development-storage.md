# 开发与测试磁盘预算

开发使用固定的 Rust `target/` 和 Swift `.cache/macos-build`；不为每个阶段复制编译树。默认关闭 Rust 增量编译，工作区保留有限调试信息，第三方依赖不生成调试信息。这会增加部分重新编译时间，并减少调试器中的类型／变量信息；断言、溢出检查和测试执行语义不变。配置含义见 [Cargo profiles](https://doc.rust-lang.org/cargo/reference/profiles.html)。

macOS 配置向 rustc 显式传入 `-C strip=none`，避免无调试信息的宏库触发 macOS 27 的 LINKEDIT 对齐错误。Cargo 对 `debug=0` 的依赖仍会传入 `strip=debuginfo`，仅设置 profile 的 `strip="none"` 不够，最终编译器参数必须覆盖它。问题见 [rust-lang/rust#157750](https://github.com/rust-lang/rust/issues/157750)；保留符号不会恢复全量依赖调试信息。

标准入口 `script/build_and_run.sh`、`script/test.sh`、`script/check_codex_core_embed.sh` 和前台测试宿主自动使用存储保护。其他编译、定向测试通过同一入口执行：

```sh
python3 script/dev_storage.py run -- cargo test --locked -p shipios-core
python3 script/dev_storage.py run -- xcrun swift test --build-system native --package-path apps/macos --scratch-path .cache/macos-build --cache-path .cache/swiftpm-cache --disable-sandbox --filter SomeTests
python3 script/dev_storage.py check
```

`target/`、`.cache/` 和 `apps/macos/.build/` 的目录统计合计上限为 **64 GiB**，磁盘最少保留 **20 GiB**。运行前后检查两个阈值，运行中每 5 秒检查可用空间、每 60 秒检查缓存体积；越界终止该次命令及进程组，并给出清理指引。上限是采样保护，长时间扫描或一次写入可能暂时越界，不是文件系统硬配额。`.cache` 中保留的日志和截图也计入预算；APFS 共享块会让目录统计高于独占空间，因此此预算有意按目录统计执行。

需要隔离时只有两个可复用槽位，环境变量必须指向这些固定路径：

```sh
CARGO_TARGET_DIR="$PWD/.cache/isolated/1/target" \
SHIPIOS_BUILD_CACHE_ROOT="$PWD/.cache/isolated/1" \
  script/build_and_run.sh --build-app
```

第二个槽位为 `.cache/isolated/2`。独立上游嵌入实验默认也复用 `target/`，若需隔离，显式选择上述固定槽位；守卫拒绝旧 `.cache/codex-upstream-target` 环境或命令参数，历史证据保留。不得创建 `native-ui-阶段`、`isolated-full-阶段` 等新的编译目录，也不得关闭 `SHIPIOS_STORAGE_GUARDED` 的保护来绕开预算。定向 Swift 命令仍需显式复用同一 scratch/cache 路径。

阶段结束或达到预算后清理：

```sh
python3 script/dev_storage.py clean          # 只列出可重建产物
python3 script/dev_storage.py clean --apply  # 无构建／测试运行时执行
```

清理器仅删除已知编译缓存和旧 Agent 可执行副本；保留临时仓库、运行数据、证据、日志和截图。嵌套 Git 检出存在修改、Git 检查失败或路径通过软链接指向其他位置时保留。保护入口与清理器使用共享／排他锁，防止清理与受保护构建并发。

前台测试用 `TemporaryDirectory` 保存复制的 XCTest、资源和 Agent。结果、日志及输入摘要写入指定输出目录后自动回收；编译失败、超时、异常和正常的 INT／TERM 取消也执行清理并终止匹配该临时路径的宿主。强制 KILL 或断电不能保证 Python 清理逻辑执行，遗留目录应在确认宿主已退出后人工清理。

## 本阶段验证

2026-10-10：13 项存储保护回归通过，覆盖运行前拒绝、运行中超预算停止进程组、结束后检查、固定缓存路径、清理锁、修改过的检出及软链接保留、临时目录回收、TERM 取消和部分证据保留。真实宿主进程清理测试确认其他进程不受影响；Shell／Python 语法检查通过。

应用通过 `script/build_and_run.sh` 完成 Rust／Swift 冷构建、打包和启动，签名、Agent IPC 和捆绑 Codex RPC 冒烟通过。实际前台验证设置快捷键、返回工作区和任务输入焦点。未执行 Swift 全量回归，也不表示 Codex UI 已完全对齐。验证日志保存在忽略目录 `.cache/storage-*.log`；首次冷构建的 LINKEDIT 失败和最终成功日志分别保留，通信检查在打包结束后顺序复验。
