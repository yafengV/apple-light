# 项目协作约定

- 按用户要求，每个完成验证的独立开发阶段及时整理 commit 并 push 到当前分支的远端，不长期积压本地改动。
- 提交前检查变更范围和相关测试；构建产物、缓存、运行数据、凭证及个人配置不得进入提交。
- 原生 macOS 应用通过 `script/build_and_run.sh` 构建运行。启动验证需要确认工作区可交互，不能只检查进程是否存在。
- Codex UI 对齐尚未完成；区分代码实现、自动化测试和实际页面/交互验收，不把局部通过描述为完全对齐。
- 开发磁盘预算：`target/`、`.cache/` 和 `apps/macos/.build/` 合计不超过 64 GiB，所在磁盘至少保留 20 GiB 可用空间。标准构建／测试入口自动检查并在运行中监控；其他编译命令必须通过 `python3 script/dev_storage.py run -- <命令>` 执行，禁止绕开保护变量。
- 默认复用 `target/` 和 `.cache/macos-build`。必须隔离时只使用 `.cache/isolated/1` 或 `.cache/isolated/2` 固定槽位，并通过 `CARGO_TARGET_DIR`／`SHIPIOS_BUILD_CACHE_ROOT` 指向该槽位；禁止按日期、阶段编号或 agent 名无限新增编译缓存。隔离任务完成（包括失败／取消）后，在无构建运行时清理该槽位的编译产物。
- Rust 开发／测试默认关闭增量编译，使用有限调试信息；第三方依赖不生成调试信息。确需完整符号诊断时临时开启，完成后清理该批产物，不把调试配置提交为默认。
- 每个开发阶段结束检查 `python3 script/dev_storage.py check`。缓存超预算时先运行 `python3 script/dev_storage.py clean` 查看清单，再用 `clean --apply` 清理。清理必须保留源码、未提交改动、运行数据和验收日志／截图；不能整体删除 `.cache/`，也不能在构建／测试执行中删除其输入。前台测试的临时副本由宿主脚本自动回收，证据另存到指定输出目录。
