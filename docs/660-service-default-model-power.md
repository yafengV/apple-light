# 服务默认模型与默认档位恢复

日期：2026-10-08。

## 参考与差异

固定公开 Codex Mac `26.930.51102`、build `13100` 的资源 SHA-256 `22f3ea455585cfc0508e3d3627eac161c80c849c0aace3d76d09fdebaa0aeca3`，在隔离 VM 中执行公开纯函数 `H9r/U9r`。新增 `script/extract_model_power_defaults.cjs` 与新夹具 `model_power_default_reference_660.json`，15 组结果覆盖精确默认、同强度 Sol、缺省/不可用默认、Sol 名称边界与大小写、多冒号模型 ID、空列表等。脚本重跑与夹具逐字节一致，旧全量捕获的夹具未修改。

旧代码总是优先选择 Sol Medium，忽略服务指定的默认模型。回归基线使用服务默认 Terra Low，实际返回 Sol Medium，1 项 / 1 条断言失败，日志 `.cache/model-default-repro-660.log`，exit 1。

## 实现

- 模型能力解码接受 `is_default` / `isDefault` 的真实布尔值；不把数字、字符串或 null 误当默认标记。重复模型缺省保留既有标记，显式 false 可覆盖 true。
- 默认恢复先匹配可见服务默认模型及其默认强度；不可用时依次匹配同强度 Sol、Sol Medium、首个 Sol、任意 Medium、首个有效默认档位。沿用实际服务能力和高级档位过滤，没有虚构服务未声明的能力。
- 紧凑档位菜单增加恢复默认按钮，与完整列表已有动作共用 `selectDefaultPower`。不存在可用默认时先报错，不改选择。任务作用域保持任务模型与全局 API 配置隔离。
- 模式和模型配置保存仍是独立操作，各自错误返回界面；不宣称跨文件原子事务。请求协议及身份隔离未改变。

## 验证

修复后关联 **31 项、0 失败/跳过**、6.010 秒、exit 0，日志 `.cache/model-default-fixed-660.log`。新增 5 项包含公开参考的 15 组结果、元数据类型和重复合并、不可用/隐藏默认及失败清理；真实本机 HTTP 服务确认默认选择、任务/全局隔离、协议保持、持久模式、写盘失败和空能力错误。

正式包通过 `script/build_and_run.sh` 在独立 `.cache/model-default-native-660/Data` 和本机能力服务运行。实际鼠标从明确 Sol High 的紧凑菜单恢复为服务指定 Terra Low，按钮隐藏、滑杆保持实际焦点；右键切到 Sol Low。完整列表选择明确 Sol 后恢复原中文草稿焦点，再从完整列表恢复 Terra Low，回到滑杆焦点；Return 关闭、⌘, 进入同一 ID: main 设置、Esc 返回原草稿焦点均通过。

正式包重启后任务 Terra Low、default 模式及原中文草稿保持；重新打开仍显示跨模型档位，Return 返回输入焦点。落盘证据 `.cache/model-default-native-evidence-660.json`：全局仍为 global-660/high，任务为 Terra Low，草稿保持，本机服务只有 5 次 GET、没有模型 POST。构建日志 `.cache/model-default-native-run-660.log`、`.cache/model-default-native-restart-660.log` 均 exit 0。随后通过标准脚本恢复默认 other 工作区，实际点击输入、同窗口设置往返和返回输入焦点通过，日志 `.cache/model-default-default-run-660.log`；本机验收服务已停止。

最终正式 helper SHA-256 `5d109a3502afba5fda545fc5d174b544efeff01e92e208965e1176bc5f8e094e`，严格签名、相同 helper IPC/Core 均通过、exit 0，日志 `.cache/model-default-final-{signature,ipc,core}-660.log`。相同 helper 的最终扩大回归 **363 项、0 失败/跳过、0 unexpected**、286.335 秒、exit 0，日志 `.cache/model-default-final-expanded-660.log`；筛选覆盖模型/推理、两种实际协议请求、任务/子会话隔离、持久恢复、设置返回焦点、任务窗口及标签。

本轮另重新核验开发签名：真实证书两版不同代码保持指定要求一致、主应用/helper 严格校验通过，日志 `.cache/development-signing-recheck-660.log`。未修改证书、隐私数据库或用户 API 配置。

固定第 657 篇全量仍在独立冻结缓存运行，不覆盖第 659—660 篇。本轮核验其 63 个捕获夹具、155 个 bundle 资源、测试程序及保存 helper 的散列均保持不变；未因观察等待而重启全量。没有 Rust 源码改动，未声称重新运行既有 195 项 Rust 测试。

## 后续缺口

公开 primary 资源 SHA-256 `234429db84d9319850ff0766a4a5052a9e898bfa0611883633f80018080dd6c0` 的 `X0e` 显示完整菜单初始焦点优先已选 `menuitemradio`，再选择首个可交互项；Tab / Shift-Tab / 上下键循环遍历可见菜单项并排除滑杆。当前高级列表仍先聚焦搜索框，其方向键只改变高亮，尚未实现相同菜单焦点循环。第 659 篇搜索聚焦通过只证明当时的实现行为，不能算这项参考行为已对齐。

动态服务预设、精确视觉/拖动/动效、完整菜单焦点与全部键盘路径、真实用户服务和整页双端验收继续缺失。现有能力与有限原生验证不等于完整页面对齐；47 类页面/交互完整配对计数保持 0/47，29 项核心要求继续按总矩阵逐项验收。
