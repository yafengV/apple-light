# 集成测试统一使用本次构建的 Agent

接续[子任务审批](618-native-subagent-approval-actions.md)。复核发现六项根会话测试以外，仍有大量旧测试直接拼接 `target/debug/shipios-agent`，以及 Git 生成夹具的静态路径。这会使独立缓存或正式包复测混用旧 Agent，不能据此证明当前 Core 功能完整。

## 修正范围

- 27 个测试源文件中的 88 处调用改用 `AgentTestExecutable.url()`：75 处直接 Agent 路径和 13 处 Git 生成共享路径；保留公共解析器唯一的默认仓库路径回退。
- 显式 `SHIPIOS_TEST_AGENT` 优先，路径不存在、目录或不可执行时原解析器直接失败；不改为静默回退或跳过。现有 IPC、模型请求、工作树、Git 生成和任务隔离断言保持。
- 清理编译器明确指出无用的旧仓库路径计算；夹具服务器文件、生产应用与 Rust/Core 源码不变。

## 验证及覆盖边界

初次统一入口后 38 项通过，0 失败/跳过，22.662 秒，`.cache/agent-source-unification-tests.log`。使用明确指定的第 618 篇 helper，包含实际 IPC、技能发现、Git Responses 生成、子任务审批和任务归档；筛选中的 `AgentTests` 同时命中 `TaskArchiveAgentTests`，数量按日志实际记录。

正式包 helper 的扩大回归 213 项通过，0 失败/跳过，515.581 秒，terminal exit 0，`.cache/agent-source-unification-final.log`。其中 ModelTransportTests 全组 86 项通过，涵盖实际 Core、命令/补丁、审批/提问、MCP、目标/计划、恢复/并行及取消；另外有 Git 生成、PR、项目切换和任务隔离。它在最后一批仅移除未使用路径计算前编译，最终清理后的重编译与复测另列。38 项与此集合重叠，不累加。

最后一批清理后重新编译全部测试源文件，38 项复测通过，0 失败/跳过，22.423 秒，terminal exit 0，`.cache/agent-source-unification-clean-final.log`，使用同一正式包 helper。没有遗留本次仓库变量的编译警告，`git diff --check` 通过。生产源码没有变化，因此不重复把第 618 篇构建启动当成新的前台验收。

隐藏布局测试与服务夹具不代替前台验收或真实用户服务。此阶段没有新增 UI，完整配对仍 0/47。

保留全量 session 47011 在 `f0439de` 编译结束后才修改上述测试源文件；不重启、不改其测试二进制或服务器夹具。它使用本阶段统一前的 Swift 二进制：支持公共解析器的测试使用当前指定 helper，尚未修正的旧测试仍固定使用默认目录旧 Agent。因此即使该全量最终通过，也不能称为所有集成用例均验证当前 Core。最终统一后需另行全量，不与仍在运行的同缓存测试竞争。

## 下一步行为核对

固定上游 Core 的 `tools/handlers/request_user_input.rs` 明确拒绝非根线程的结构化提问，返回 `request_user_input can only be used by the root thread`。子详情目前泛化的等待提示不能被当成实际支持证据，也不能通过去掉这一限制伪装成 Codex 对齐。接下来分别核对参考应用的子会话输入行为、MCP elicitation 和权限请求，按真实原生事件接入；根会话提问的既有支持与此边界区分。

其余完整要求保留在[核心及全部页面矩阵](599-core-function-parity-matrix.md)，不因本阶段测试修正缩小目标。
