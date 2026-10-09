# 固定侧栏浏览器来源菜单与真实页面操作

日期：2026-10-09。接续[固定项重命名来源](721-pinned-browser-rename-dialog.md)及[紧凑改名弹层](723-compact-rename-dialog-presentation.md)。固定侧栏新增来源页重新加载、复制标签页、复制 URL、外部浏览器打开和关闭，继续提供取消固定及同窗口重命名。

## 固定参考与范围

参考仍是 Codex 26.930.51102／build 13100，初始 JS SHA-256 `22f3ea455585cfc0508e3d3627eac161c80c849c0aace3d76d09fdebaa0aeca3`，共享 JS SHA-256 `eb2500c5398279d4fbf5c71d7ce982d54631660907761740199f6c22591d71ab`。`script/extract_pinned_browser_menu.cjs` 检查两份摘要，执行实际 `ewa`、`eYr`、`tYr`、`ZJr`、`nwa`、`rwa`、`twa` 和 `XJ`，保存 9 组完整菜单条件、复制 fallback 的插入位置／opener／默认 revealAndFocus、导航消息以及来源失效后的零动作。scope、closeability、browser snapshot、分叉能力、音频菜单 provider、国际化／图标／JSX、page 初始化、ZJ.open controller 和 host effects 明确替换，不作为原生菜单、完整历史 clone、静音、分叉或焦点验收。

完整参考保留 no-snapshot、无效相对地址、空白、普通 Web、默认浏览器、suspended、muted、媒体及可分叉来源差异。Swift 比较其中已实现动作的次序与条件，保留音频／分叉条目存在的断言，不删除夹具中的缺失能力来声称全菜单通过。中文菜单及成功提示按已固定的中文资源核对。

| 项目 | 本阶段行为 | 验证边界 |
| --- | --- | --- |
| 菜单次序 | 取消固定；重新加载、复制标签页、条件 URL／外部打开；重命名；关闭 | 不提供仅属于标签栏的在右侧新建／关闭其他／关闭右侧项；静音和分叉仍缺 |
| 复制 URL | 仅 Web、有效已提交 URL 且非 about:blank 前缀；执行时再读取最新 URL | 不复制地址栏未提交草稿；特殊媒体 runtime 尚未接入 |
| 默认浏览器 | 系统默认处理应用为 dev.shipios.desktop 时隐藏外部打开 | 条件比较由注入值验证；真实改变系统默认浏览器未验收 |
| 成功提示 | 剪贴板写入成功才显示“URL 已复制到剪贴板” | 任务窗口来源在其 notices 上显示，不向主窗口投放同一条提示；前台提示样式未配对 |
| 复制标签页 | 使用原 session 的 owner-aware child route，紧邻来源、相同 pane／opener，以已提交 URL 重新加载；空白 URL 用原生 WebKit 加载 | 采用实际无 browserHost clone 时的 URL fallback；完整历史／host clone 状态尚未实现 |
| 隐藏来源 | 后台原 owner 的布局保存新页为选中／focused；当前聊天、草稿、当前布局不切换 | 主／任务窗口来源均测试，全部特殊 primary／phase 仍待核对 |
| 关闭 | 先保存最新 URL、标题／customTitle，再调用来源容器关闭 | 固定项保留，可显式恢复；不因查询菜单恢复冷来源 |
| 失效 | 比较 pin 完整值、unpin generation、project、pane、session 和 page 身份，并复用 owner／window／kind／placement／drag 检查 | 旧菜单不能操作同 ID 替代页面或取消固定后重新加入的引用 |
| 背景隔离 | 主模态、其他弹层、项目准备、恢复限制、关闭应用期间不运行来源动作 | 实际菜单关闭后键盘焦点仍待前台验收 |

任务窗口来源解析另外补齐 tab.kind == browser 条件，避免页面 UUID 仍存在时把类型变化当作浏览器来源。

## 测试与修复记录

首轮测试因夹具调用了不存在的 `updateAddressDraft` 而编译失败，没有执行方法；改用现有 `setAddressDraft`。第二轮 23 项有 1 条媒体条件断言失败：参考媒体不提供复制 URL，补齐 isWeb 条件后保留完整断言；当前原生 browser context 仍是 WebKit 网页，纯条件比较不证明特殊媒体已实现。另外按实际 `XJ` 的默认 revealAndFocus 补齐隐藏来源布局中的新页选中状态，并新增 about:blank 真实 WebKit 复制验证。

最终专项 **24 项、0 失败／跳过，3.360 秒**，含新增 6 方法及既有浏览器子窗口／固定改名回归。本机 HTTP 服务实际加载 One／Two 网页，验证原页重新加载、地址草稿不进入剪贴板或复制页、注入外部打开收到准确已提交 URL、真实复制页加载、关闭后磁盘固定项保留最新 URL／自定义标题；about:blank 不复制且复制页无地址验证错误。外部回调替代真实浏览器启动，没有访问模型／用户服务。18 组来源改变分别检查旧动作不执行，cold／modal 入口不恢复或切换当前页面。没有将注入回调称为外部浏览器前台验收。

最终扩大 **406 项、0 失败／跳过，42.225 秒**，包含第 723 篇范围、全部 BrowserTests 和新增动作测试。沿用第 723 篇窗口排除，尤其保留真实关键窗口焦点方法的未通过状态；不是全部 Swift 方法通过。源码、测试、执行文件及编译资源摘要前后未变化。专项与扩大重叠，数量不累加。最终日志／清单为 `.cache/pinned-browser-actions-focused-url-final-724.log`、`.cache/pinned-browser-actions-focused-url-final-provenance-724.json`、`.cache/pinned-browser-actions-expanded-url-final-724.log`、`.cache/pinned-browser-actions-expanded-url-final-provenance-724.json`。

参考重新提取第一次调用多传一个参数，把 JSON 写到了忽略目录的主 JS 副本。已从另一份原先保存且 SHA-256 完全一致的本地 JS 副本恢复，重新提取夹具逐字节一致，没有重建或替换参考版本，也未改变产品源码／测试夹具。提取脚本新增严格参数数目与输出不能覆盖输入的校验；三组错误调用均拒绝且输入摘要不变。扩大首轮 406 项通过后，对参数防护脚本再次取得 406 项通过；随后复核相对 URL 在 Swift／JS 的解析差异，补齐绝对地址及真实外部前缀条件，新增第九组实际参考并取得上述最终 24／406 项终态。此前日志保留。恢复记录为 `.cache/pinned-browser-reference-input-restored-724.json`。

## 打包与剩余验收

标准 `script/build_and_run.sh --build-app` exit 0，Swift 3.74 秒；正式应用与 helper 均为 Apple Development，指定要求保持第 713 篇基线，旧要求验证及严格深度校验通过，正式包 helper IPC exit 0。打包前后 1,639 项源码、测试、执行文件和编译资源摘要未变。日志与清单为 `.cache/pinned-browser-actions-{build-run-url-final,signature-url-final,package-url-final-provenance,ipc-url-final}-724.*`。Mac 最近明确锁屏，本阶段不把包生成、WebKit 本地夹具或无关键窗口的挂载当作实际菜单／工作区可交互验收。固定第 721 篇独立广泛回归的监督 PID 97076 与 Swift PID 1838 经 `ps` 确认仍活跃，构建／预检已通过、当前继续执行 GitPullRequestWorkflow 等组，仍待终态，不含本篇改动。

仍未实现完整静音／取消静音 backend、浏览器来源分叉到本地／同工作树／新工作树、host clone 完整历史及状态、特殊媒体／iframe/CDP/WebMCP 菜单；还需前台菜单外观／图标／焦点、关闭菜单后的 fixed row fallback、真实系统默认浏览器及外部打开、冷／primary／phase／全部跨窗口路由、固定行图标／状态／缩略图／布局配对。原范围保持 **47 页面、29 核心项，完整双端配对 0/47**，不把支持的六项来源动作当作整个浏览器或全部 UI 完成。
