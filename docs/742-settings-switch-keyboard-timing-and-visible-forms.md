# 设置开关连续按键与表单实际验收

日期：2026-10-10。开发基线：`b6476dc2`。范围：R8 的共用开关、设置搜索、个性化保存和模型配置返回；不是整组 R8 或全部核心对齐完成。

## 修复

实际窗口中，纯文本开关获得焦点后连续按 Tab、Space，下一开关第一次没有变化；分开操作则生效。原生前台 XCTest 复现：AppKit 的 first responder 已改变，SwiftUI FocusState 尚未更新，开关的额外 focused 判断拦截了已经由原生焦点路由到它的事件。

开关现在按原生键盘路由处理 Space／Enter，保留禁用与修饰键检查。Space 仍在松开时提交、Enter 仍在按下时提交。Tab／反向 Tab 在焦点移动前同步取消待提交的 Space，避免 SwiftUI 把松开事件送回旧开关时误触发；失焦、窗口失活、禁用和移除仍取消待提交操作。

新增真实前台方法验证：Tab 后立即 Space、Shift-Tab 后立即 Enter、按住 Space 后真实移走 first responder 再松开。反向 Tab 使用 AppKit 的 back-tab 字符。隐藏窗口的旧方法改为明确调用原生 key-view 导航，仍验证实际 responder 离开／返回及取消；实际 Tab 事件由前台方法覆盖。验收宿主扩为 **5 项**，仍保留真实关键窗口要求，不伪造焦点或将排除记为通过。

## 实际产品窗口

通过 `script/build_and_run.sh --app --data-root …` 启动隔离目录 `.cache/settings-visible-742/data`，测试未填写密钥、未调用用户 API：

- Cmd+, 在 `main` 内打开设置，搜索有初次焦点；无结果查询显示提示，Esc 清空查询，中文关键词可定位通用页并滚动到目标。搜索定位保留搜索框焦点。
- 开关点击、Space、Enter 可操作。修复后的正式包连续 Tab→Space 改变下一开关，Shift-Tab→Enter 改变前一开关；下拉触发器可由反向 Tab、Space 打开，Esc 关闭菜单后焦点留在触发器且值不变。
- 个性化测试草稿切换分类触发丢弃确认；Esc／继续编辑保留内容，分别 Tab 和 Enter 丢弃后分类切换完成、编辑器还原。Cmd+S 保存显示成功，重启后测试文本仍在且保存按钮禁用。
- 模型表单无效地址保存显示具体校验错误，返回触发未保存确认；取消保留草稿和错误，分别 Tab 和 Enter 丢弃后回到原任务并聚焦输入。重启后地址／模型仍为空，无效草稿未写入配置。
- 通用开关值在重启后恢复。最终恢复默认数据实例，主工作区、同窗口设置入口和 Esc 返回输入焦点可操作，没有持续恢复 loading。

另观察到未保存确认中将 Tab、Enter 连续发出时选择未按预期执行；分开操作通过。该快速确认路径尚未完成原生定位／修复，不能将确认弹层全部键盘状态记为通过。其他常用设置页面、窄窗口及浅深色完整验收仍继续；真实 API 开发闭环仍待用户保存服务配置。

## 验证与原始记录

- 最终关联 **25 项、0 失败／跳过、10.723 秒**，包含开关键盘／呈现、焦点揭示、确认返回等匹配方法。真正的前台方法在命令行明确排除，另由宿主执行。
- 最终前台宿主 **5 项、0 失败／异常／跳过**，源码／测试／脚本／测试包／资源／helper 的冻结输入未变；包含新增方法及原有聊天返回、改名和准备页验收。详见 `.cache/settings-switch-foreground-742-complete/{test.log,result.json,manifest.json}`。
- 参考样式采用已冻结的 `app-shared-6fb15e58cd7f.css`，SHA-256 `4ea4b25e3f4f3225a3bf212fa767afe7655b16bbd5919ebf4fb12c656f974720`。没有重试此前受限的实时 Codex 页面读取。
- 标准产品打包／启动 exit 0，Swift 构建 17.89 秒；严格深层签名、应用／helper 第 713 篇旧身份要求及稳定 Apple Development 签名通过。最新打包 helper 的 IPC 冒烟通过。

失败／中间记录均保留：隐藏窗口旧 Tab 分发与最初新增方法失败、宿主未能激活、修复前实际 Space 被拦截、第一次扩大时关键窗口失焦及反向 Tab 字符不正确、待提交 Space 未及时取消。首轮呈现测试跳过及误指定 initial CSS 导致的 hash／几何失败另保留；最终 shared CSS 与完整断言通过，没有削弱样式断言。

本机日志：`.cache/settings-switch-{fast-742-before,associated-742-*,product-742-final,default-launch-742,ipc-742}.log`、`.cache/settings-switch-signature-742.json`、`.cache/settings-switch-foreground-742-*/`。缓存、测试配置和构建产物不提交。最新全部广泛回归没有重跑，R1–R8 继续验收。
