# 外观字体自然宽度与设置行控件保留区

日期：2026-10-08。继续全部 UI、交互及核心功能对齐；接续第 671 篇发现的完整父容器宽度差异。

## 公开依据与旧实现

固定公开参考仍为 Codex 26.930.51102 / build 13100。提取器校验初始 JS、共享 JS、完整 CSS 和 general-settings 四项 SHA，执行实际 `ja` 字体组合、`wvs`／`dli` 按钮和 `HOi`／`qOi` 设置行。字体数据和翻译提供受控测试值，菜单 portal 只取触发按钮；没有执行用户账户或服务。五种组合包含单字体、单样式、双菜单、继承字体及长标题。

完整 CSS 在 850 点桌面 viewport、628／328／168 点行宽下确认：行左右 padding 16、控件间距 16，右侧区域最小宽度 `min(160, 行内容宽度×40%)`；字体组合内部间距 8。字体按钮的自然宽度是文本＋左右 padding／边框／箭头和间距，类名 `max-w-36` 不能覆盖完整 CSS 更后面的 `max-w-full`。Menlo 与 Regular 的测试按钮各约 70.69／79.41 点；长测试名称可超过 144。极窄行允许组合压至行宽，但按钮各自受父容器最大宽度限制，组合仍可能超出其布局盒；不为方便而人为改成两个等宽按钮。

旧新测试基线 3 项、13 条断言失败，日志 `.cache/appearance-row-baseline-672.log`；真实 CSS 用例通过，原生固定 144 点和未保留控件区域失败。首次测试编译另因引用其他文件的 private 委托失败，已给本文件独立委托，保留 `.cache/appearance-row-before-672.log`。

## 实现与验证

`SettingsLabeledRow` 显式接收行间距，原有默认 24 点不变；外观行使用紧凑 16 点或普通 24 点，并复用已验证的最小控件区域布局。字体组合由同步 Layout 测量现有子视图的自然宽度，再按父容器最大宽度摆放，不更换原生按钮或通过异步 state 修正位置。字体按钮 opt-in 按当前原生字体测量标题和真实按钮 chrome，代码主题／其他菜单默认路径不变。

首次关联 18 项仅剩旧测试要求 144 点的一条失败，保留 `.cache/appearance-row-associated-672.log`；按实际公开 CSS 更新该旧断言，不删除菜单／焦点／保存检查。最终专项 **19 项、0 失败／跳过，10.827 秒**，覆盖三个行宽、左右方向、真实字体按钮身份与 first responder 在 resize 中保持、完整 CSS 的 15 个行实例和字体菜单原闭环。日志 `.cache/appearance-row-associated-final-672.log`。

初次扩大 **514 项、0 失败／跳过，158.332 秒**，日志 `.cache/appearance-row-expanded-final-672.log`。检查实际快照发现默认中文标题仍有省略号，追加真实 SwiftUI 文字宽度用例后复现 2 条失败：NSString 测量 47.5／83.5 点，而 SwiftUI 文字需要 48／84 点，日志 `.cache/appearance-row-title-probe-672.log`。生产自然标题宽度改为向外取整；修正后 20 项专项通过，日志 `.cache/appearance-row-title-final-672.log`。另增加长标题和三种字体／三种字号的中文真实 Text 测量，新增测试首次因 Int→Double 与辅助功能 Any? 类型编译失败，保留 `.cache/appearance-row-all-variants-672.log`；修正测试类型后 6 项、0 失败／跳过、9.473 秒通过，日志 `.cache/appearance-row-all-variants-final-672.log`。最终扩大 **516 项、0 失败／跳过，164.185 秒**，18:58:20.883 终态，日志 `.cache/appearance-row-expanded-final2-672.log`；包括修正后的 6 项布局与既有设置／外观／恢复／归档／快捷键／共享菜单。再次查看实际隐藏窗口页面快照，默认字体标题已完整显示；该快照夹具的控件禁用，不当作前台交互验收。

取整修正前的正式构建、helper IPC／Core 与严格签名已通过（日志 `.cache/appearance-row-{native-run,ipc,core,signature}-672.log`）。最终源码再次通过 `script/build_and_run.sh --app` 构建签名并恢复默认数据目录，日志 `.cache/appearance-row-final-default-run-672.log`；严格签名及 helper 代码身份另记录在 `.cache/appearance-row-final-signature-672.log` 和 `.cache/appearance-row-code-equivalence-672.json`。helper 与已执行 IPC／Core 的版本相同，测试没有使用用户实际服务。

原生页面访问时 CUA 两次报告 Mac 已锁屏；已请求解锁，未把启动进程当作可交互证明。本阶段字体选择／重启／同窗口返回的新增前台验收仍待解锁，第 671 篇原生通过结果保留其原范围，不代替本阶段。

## 仍待完成

强调色与颜色输入组合的宽度／表面、完整窄窗口和响应式规则、所有控件字重／精确像素／动效、全部菜单焦点来源与 macOS 14 实机仍缺。固定第 670 篇全量是此前冻结提交的测试，不覆盖本阶段。完整范围仍为 21 个主页面／交互类别、26 个设置面及 29 项核心功能；完整双端配对继续 **0/47**，不把局部实现或测试数量换算为完成比例。
