# 模型配置读取的恢复期限与重试

日期：2026-10-07 开始，2026-10-08 收尾。接续[第 656 篇](656-model-power-stops-and-focus.md)。处理 C12 的模型配置恢复缺口，未改变全部页面、全部交互和核心功能范围，不把本阶段计为整类完成。

## 已确认的问题

第 656 篇原生采样记录 `WorkspaceStore.loadModelConfiguration → Data(contentsOf:) → __open` 停滞。模型配置原先使用不可取消的同步读取等待，没有期限；读取失败只设置普通错误，随后继续打开工作区并写入历史。

新增损坏 model.json 用例在旧实现取得 **1 项、4 条失败断言、0 unexpected，exit 1**，日志 `.cache/model-restoration-repro-657.log`：工作区仍开放、发送未阻止、历史字节发生变化。修复后必须保留原文件与有效历史，失败停在主窗口恢复界面，修复配置后显式重试。

## 实现

- 抽出 `BoundedFileReader`，工作区记录和模型配置共用等待期限、单次 I/O 复用和独立等待者取消；默认 15 秒，不堆积仍被系统阻塞的读取线程。
- `ModelConfigurationReader` 只有不存在的文件返回空配置；损坏、目录和其他读取失败不会被当成新用户空状态。
- 模型读取失败停止恢复；主窗口既有错误/重试入口、任务窗口与分离内容窗口保持对应失败状态，不能误认为有效历史损坏或关闭有效任务窗口。
- 恢复期间或失败后阻止命令、发送、归档操作及任务记录写入；临时侧聊和待删除工作树清理延后到模型读取成功。
- 取消、超时和应用关闭后的结果不再更新配置；显式保存成功使旧读取失效，保存失败保持原读取权威。未完成读取时关闭应用也不改写任务记录。

## 自动化与前台验证

首批恢复、窗口和模型关联 **42 项通过**，日志 `.cache/model-restoration-fixed-657.log`；扩大 **99 项、0 失败/跳过**，34.373 秒，exit 0，日志 `.cache/model-restoration-associated-657.log`。第 658 篇开发签名改变了正式 helper 的签名字节，后续用该正式 helper 再扩大回归及 IPC/Core 冒烟，具体终态见下文，旧哈希不用于声称新签名已验收。

开发签名中间扩大 **288 项、0 失败/跳过**，140.309 秒，exit 0，日志 `.cache/model-restoration-formal-final-associated-657.log`。审查随后发现“显式保存后立即再次读取”的新等待者仍可能复用失效 I/O 的旧快照；新增用例 **1 项、2 条失败断言、0 unexpected，exit 1**，日志 `.cache/model-restoration-superseded-repro-657.log`，所以中间 288 项不作为最终通过结论。

`cancelPending()` 现同时标记在途结果失效；旧 I/O 返回后不再投递给后来等待者，仍有等待者才开始新的读取。这样保存后重读得到当前文件，也不会增加同时阻塞的线程。修复后 **43 项、0 失败/跳过**，exit 0，日志 `.cache/model-restoration-superseded-fixed-657.log`；最终正式 helper 扩大 **289 项、0 失败/跳过、0 unexpected**，141.289 秒，exit 0，日志 `.cache/model-restoration-verified-final-associated-657.log`。

第 658 篇签名前后，原桌面夹具均恢复为可交互，草稿保持；此前采样的系统 open 停滞本轮未再次出现。因此既不能把恢复正常单独归因于本阶段，也不能继续声称该夹具现在仍卡住；签名因素与等待期限是分别处理的边界。

通过 `script/build_and_run.sh --app --data-root /tmp/shipios-model-restoration-657/Data` 启动正式包，日志 `.cache/model-restoration-fifo-run-657.log`，exit 0。FIFO 模型文件被 Foundation 立即以权限错误拒绝，前台显示“无法恢复工作区”和“重试恢复”，输入/导航/工具栏禁用，⌘K 不打开后台命令菜单；原历史哈希保持。该夹具没有进入阻塞读取，不能用它声称前台等待了 15 秒；超时、单 I/O 复用、取消和迟到结果隔离由可控阻塞测试验证。

随后只用原子替换将自有 FIFO 改为损坏 JSON，Return 重试实际重新读取并把错误改为格式错误，历史字节仍保持；再只修复模型文件为本机占位服务和 `restored-657`，点击重试恢复同一工作区，显示新模型和原中文草稿。没有发送模型请求或改动真实用户服务。点击原输入后 ⌘, 在同一 `ID: main` 打开设置，Esc 返回原草稿并恢复输入焦点。

最终修复正式构建 exit 0，Swift 2.94 秒，日志 `.cache/model-restoration-final-run-657.log`；再次用损坏 JSON 验证禁用界面和历史字节保持，只修复模型文件后按 Return 恢复 `restored-final-657` 与原中文草稿。严格深度签名、相同 helper 的 IPC/Core 冒烟 exit 0，日志 `.cache/model-restoration-verified-{signature,ipc,core}-657.log`。独立保留的已验证 helper SHA-256 为 `1759b556737f9952012d5d927664e044149e8bbe14fb874109aa5ef6092e81f5`；正常系统信任环境下签名校验通过，默认工具沙箱不能访问信任服务时的 CSSMERR_TP_NOT_TRUSTED 不能当作证书无效。

最后通过 `script/build_and_run.sh --app` 恢复默认 `other` 工作区，exit 0，Swift 3.11 秒，日志 `.cache/model-restoration-verified-default-run-657.log`。实际点击空输入、⌘, 在同一 `ID: main` 打开设置、Esc 返回原空输入焦点，无持续 loading；真实用户服务配置未改动。

## 固定全量结果与剩余边界

第 653 篇固定提交 `b4e81aa51a1b0eb27018797c43df66d580dbb92d` 已取得终态 **exit 0**：2,822 项 Swift、2 跳过、0 失败，4,603.518 秒，以及 IPC 冒烟通过。原 handle `91319` 确认 exit 0；终态文件 `.cache/full-alignment-regression-653-status.json`，日志 `.cache/full-alignment-regression-653.log`。终态后核验 58 个夹具、153 个资源、测试二进制和独立 helper 哈希均保持。该固定结果不覆盖第 654—658 篇，当前阶段提交后会启动新的固定全量，未取得终态前不计通过。

本阶段只限制模型配置等待，不强行终止内核中的同步 open。其他恢复步骤、底层桌面读取停滞根因、全部故障组合、真实用户 API、完整页面/交互双端配对仍须继续。完整配对保持 **0/47**。
