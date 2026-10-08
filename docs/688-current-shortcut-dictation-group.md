# 新版通用快捷键页的听写分组与搜索

日期：2026-10-09。范围为 S13 通用快捷键页及 S02 的共享听写绑定；仍不代表完整设置页或全部 UI 已完成配对。

## 当前参考

通过安装包元数据定位公开分发资源，版本 26.930.51102／13100；只读取 `app.asar` 的静态公开代码，没有读取 Codex 窗口、原生桥接、账户、个人配置或历史。归档内 `app-initial-f9b16fbf8fc7.js` 与第 652 篇已核验摘要一致。

本轮取得当前 `keyboard-shortcuts-settings-ef4c455aeec6.js`，SHA-256 `f31de7f3b3c6b2449870be9f0fbc8259cd5f494d06105b619a26560976892328`，以及搜索组件 `keyboard-shortcuts-search-input-43f8d39542db.js`，SHA-256 `6c52630b9d12720d2c280ed4e522b81ecae7ec6e78c0924c118d8401db709baf`。前者的薄入口 `keyboard-shortcuts-settings-abba506cdbd4.js` 仅转出实际组件。

当前通用页将 `globalDictationHold`、`globalDictationSingleTap` 从普通命令卡片移出，`realtimeVoice` 仍在普通卡片。`Xt` 组件将单击听写默认折叠在单独的“高级”行下，并带有跨应用／Esc 说明。搜索仅命中单击听写，或非空按键搜索时，单击行直接显示而不显示高级按钮；普通文本搜索同时命中按住和单击时仍保持原折叠状态。数字快捷键偏好也参与文本过滤，按键搜索隐藏该偏好；外部浏览器链接偏好插入新建浏览器标签命令之后，若该命令未命中则放在普通卡片末尾。

`script/extract_shortcut_dictation_group.cjs` 固定当前设置资源及 primary 摘要，只隔离执行实际 `Xt`、纯过滤函数和分组／搜索表达式，保存三次折叠状态与七组搜索结果到新夹具 `shortcut_dictation_group_reference_688.json`。modifier 解码只执行实际排除分支，键名规范化使用身份桩；四种裸修饰键均返回空值。它证明当前按键搜索不会单独录入这些修饰键，不能由此推断完整键盘布局、Fn 或系统事件行为。第 686 篇将实际裸修饰键搜索列为待核验；本轮不再把它视为需要新增的功能。

当前通用页也确认使用 `set-codex-command-keybinding`／`reset-codex-command-keybindings` 及共享 keymap 失效，补足第 686 篇仅核验旧版通用页的来源限制；这仍不是新版整页或所有回调的验收。公开代码还显示序列绑定编辑、前缀冲突和序列按键搜索；本项目尚未完整支持这些能力，继续列入缺口。

## 改动

- 数字偏好、普通命令和听写采用分开的共享卡片，行使用现有参考的水平 16 点／垂直 12 点内边距，去掉末尾多余分隔线；外部浏览器偏好调整到对应命令后。保留单一滚动容器和吸顶搜索控件。
- 两种全局听写置于独立分组，单击行默认折叠，即使已经保存绑定也不默认展开；语音聊天保留普通命令位置。已有共享保存／注册事务沿用第 686／687 篇。
- 高级按钮支持原生 Space 松开、Return、标准及可访问性按压。折叠正在录制的单击行时，先恢复按钮焦点，再取消录制并释放捕获状态；保存值不变。折叠不取消仍可见的按住行。
- 搜索依照当前实际分组条件直接显示单击行，不改临时展开值；分组从搜索结果移除后重置展开状态。离开页面／设置也复位并结束旧录制。设置搜索定位单击命令时，在滚动前先展开目标。
- 数字偏好参与过滤；实际按键搜索继续忽略裸修饰键，不增加参考没有的捕获。每次页面渲染只计算一次普通行列表，避免逐行反复扫描全部命令。

## 验证记录

第一轮红测试宿主泛型声明错误，未进入页面（`.cache/shortcut-dictation-group-red-688.log`）。修正测试类型后，实际页面缺少高级按钮导致 **1 项、1 失败**（`.cache/shortcut-dictation-group-red-native-688.log`）。

首次接入后 **55 项中 1 失败**（`.cache/shortcut-dictation-group-focused-first-688.log`）：旧行编辑器测试要求窄窗口左边距为 20 点；实际卡片行已为 36 点。该断言改为读取独立公开页面夹具和既有卡片夹具的两级边距，不从生产常量生成期望、不放宽误差或跳过用例。新分组用例均通过。

修正布局断言后专项 **56 项、0 失败／跳过，6.363 秒**（`.cache/shortcut-dictation-group-focused-final-688.log`），扩大 **705 项、0 失败／跳过，225.437 秒**（`.cache/shortcut-dictation-group-expanded-688.log`）。随后补充绑定变化导致分组从按键搜索结果移除的边界，红测试 **1 项、2 个失败断言**（`.cache/shortcut-dictation-group-unmount-red-688.log`）：高级展开值没有随组件移除复位，恢复绑定后仍展开。现补齐对分组实际出现／移除的观察，取消其旧录制并复位展开；需以之后复测证明最终源码，不能沿用前述 705 项宣称已覆盖修复。

最终源码专项 **57 项、0 失败／跳过，7.365 秒**（`.cache/shortcut-dictation-group-focused-unmount-final-688.log`），其中本阶段新增 10 项测试。隐藏原生页面涵盖默认折叠／保存值保持、搜索直接显示／恢复、实际设置搜索定位、Space 松开／失活、折叠录制的焦点／捕获计数及绑定变化移除分组。状态测试将七组实际参考结果与生产分组模型逐项比较；真实按键搜索原生控件也确认忽略裸修饰键。

真实隐藏页面渲染 `/tmp/shipios-shortcut-group-688.png` 已查看，可见普通命令卡片、独立听写卡片、展开后的单击行和底部高级按钮；这不是前台或双端视觉验收。参考重复提取逐字节一致，改变输入资源会在求值前被摘要校验拒绝（`.cache/shortcut-dictation-group-reference-guard-688.log`）。

最终 `script/build_and_run.sh --app` 构建及启动命令 exit 0（`.cache/shortcut-dictation-group-build-run-final-688.log`）。主应用代码改变，App／helper 均使用 Apple Development，指定要求与重建前相同，并通过旧要求和严格深度校验；helper CDHash 与冻结第 685 篇受测代码相同（`.cache/shortcut-dictation-group-code-equivalence-final-688.json`）。最终正式包 IPC／本地 Core RPC 冒烟均 exit 0（`.cache/shortcut-dictation-group-ipc-final-688.log`、`.cache/shortcut-dictation-group-core-final-688.log`）。没有 Rust 源码改动，不重复称已重跑 Rust 全套。

最终源码扩大关联回归 **706 项、0 失败／跳过，227.475 秒**，terminal exit 0（`.cache/shortcut-dictation-group-expanded-unmount-final-688.log`）。包含绑定变化移除修复，区别于修复前的 705 项；与专项重叠，不累加，也不替代最新源码全量或前台验收。

## 保留缺口

本轮分组是明确的页面布局／交互修正，不是所有通用页回调或命令的完整实现。序列绑定模型、录制／冲突／执行／搜索，完整命令映射与排序／描述、精确行控件和视觉仍缺。裸修饰键监听权限／保存事务及语音链路继续待开发验证。当前跨应用 Esc 取消全局录音路径尚未取得实现／实测证据，新增说明只与参考文案一致，不能据此宣称取消功能已完整。

最终正式构建后 CUA 再次返回 Mac 锁屏，无法确认工作区可交互；启动命令成功不作为前台验收。Mac 前台与全部双端逐页、逐状态、逐交互配对继续待验；完整配对仍 **0/47**，不是实现比例。隐藏窗口和直接原生控件输入不能代替真实系统键盘或前台验收。没有调用真实服务、麦克风或新增系统权限。

第 685 篇冻结全量使用 native-ui-648；本轮使用 native-ui-654，新增夹具没有替换其原 85 个源夹具或 178 个编译资源。本轮运行中核对原 85 个夹具、178 个编译资源、测试执行文件／helper／参考 CSS 均未改变（`.cache/shortcut-dictation-group-frozen-integrity-688.json`）。随后原句柄 terminal exit 0，已独立完成终态审计并补充第 685 篇：3,020 项、2 跳过、0 失败及 IPC 通过；原工件终态仍一致，20 个原来源路径已由后续工作修改，不能称全源码未变或以旧冻结结果覆盖本阶段。
