# 颜色输入胶囊与强调色组合布局

日期：2026-10-08。接续第 672 篇，继续全部页面／交互及核心功能对齐；本阶段修正颜色输入框及强调色组合，不代表完整外观页完成。

## 公开参考

固定 Codex 26.930.51102 / build 13100，提取器 `script/extract_appearance_color_trigger.cjs` 校验四项资源 SHA，执行实际 `fa` 颜色输入、`Sa` 强调色组合、`wvs`／`dli` 按钮及 `HOi`／`qOi` 设置行。参考只展开关闭状态的 popover，账户／颜色／翻译使用受控测试值，回调未执行；不把账户夹具当真实账户或完整菜单验收。

完整 CSS 的颜色框宽 96、高 28、左右 padding 8、边框 1、圆形曲线胶囊、透明背景，字段使用主题文字颜色／12 点文字／tabular-nums；14 点色样位于 x=9、y=7，文本框位于 x=31、y=6、宽 56、高约 16。focus-within 的两点轮廓覆盖整个胶囊。自定义强调色组合为自然宽度按钮＋8 点间距＋96 点颜色框；非自定义按钮另有 12 点圆色点。

## 实现

原生 Field／Swatch、输入过滤、立即保存、输入法组合、失败回滚、同窗口选色和生命周期保持；透明绘制、边框与整框焦点通过不响应命中／Tab／辅助功能的装饰子视图实现。文字颜色来自当前主题 textForeground，所选颜色仅填色样，不再填整框或决定文字可读色。内部几何支持 RTL，正常字号文本框高 16，较大字体按实际原生行高避免裁切。

字体和强调色共用 `AppearanceControlsLayout`；强调色按钮按实际字体自然宽度测量，保留当前 12 点文字、色点及原生弹层行为。三个生产颜色入口改为 96 点。尺寸变化不替换原生文本字段，焦点与选区继续属于原控件。

## 验证记录

旧实现新增 5 项有 12 条失败，日志 `.cache/appearance-color-before-673.log`；其中 10 条来自尺寸／绘制／文字色／RTL／焦点差异，2 条来自 WebKit 焦点测试。首次改动编译失败为自定义属性名称与 NSView.appearance 冲突，改名 preferences，保留 `.cache/appearance-color-associated-673.log`。

随后 46 项关联剩 3 条失败：旧强调色固定 144 点预期，以及两条 WebKit ring 断言，日志 `.cache/appearance-color-associated-fixed-673.log`。独立实际 WebKit 诊断确认 input 已是 activeElement，但 unattached 文档 hasFocus=false、:focus-within=false、box-shadow=none；记录 `.cache/probe-appearance-color-focus-673.json`。现从实际完整 CSS 的两条条件规则读取原声明，显式投影到参考渲染分支验证，原生用例另以真实 NSWindow first responder 检验整框轮廓。此方式不冒充参考页面实际获得焦点。

更新旧尺寸断言及原测试颜色框夹具。模态遮罩回归改为捕获整个原生子树，包含文本、色样及新边框，避免对已透明的父 view.draw 做空绘制比较。

随后参考脚本报告 `InvalidTransition ... failed(deinit)`，单项复测仍失败（`.cache/appearance-color-associated-final-673.log`、`.cache/appearance-color-webkit-probe-673.log`）。实际 CSSOM 离线诊断确认，普通 CSSStyleRule 同样有空 cssRules 列表，原递归只保留叶子分支，丢弃了这些规则，焦点声明查找为空；修正为保留 style 声明并递归子规则，同时将测量包在显式返回的 IIFE 中。受限环境另无法启动 WebKit 渲染服务，独立探针记录权限错误和超时（`.cache/probe-color-cssom-673.log`）；本轮关联在该环境等待时，经进程采样后主动停止，exit 143（`.cache/appearance-color-associated-iife-673.log`），没有将其当通过或仅因观察期限重启。允许本地渲染服务后，最终 40 项关联、0 失败／跳过、21.625 秒通过（`.cache/appearance-color-associated-cssom-fixed-673.log`）。此前 46 项集合还含另一组行布局用例，当前 40 项不是同一集合，后续扩大回归统一覆盖。

四项资源校验和实际组件提取已重跑，结果与提交夹具逐字节一致（`.cache/appearance-color-trigger-reproduced-673.json`）。

最终扩大回归 **521 项、0 失败／跳过、165.734 秒**，覆盖设置、外观、命令、恢复、归档、快捷键、个性化、代码主题及 PR 评论菜单（`.cache/appearance-color-expanded-final-673.log`）。查看隐藏窗口整页快照 `.cache/appearance-color-final-673-snapshots/page-appearance.png`，颜色框已为透明胶囊、所选色只填色样、字体标题完整显示；夹具中部分菜单禁用，截图不是前台交互验收。

通过 `script/build_and_run.sh --app` 构建并执行最终默认应用的启动命令，exit 0（`.cache/appearance-color-final-default-run-673.log`）；Apple Development 严格签名通过（`.cache/appearance-color-final-signature-673.log`）。保存的第 670 篇 helper 与正式包 CDHash 相同（`.cache/appearance-color-code-equivalence-673.json`）；正式包 IPC 与 Core RPC 冒烟均 exit 0（`.cache/appearance-color-ipc-673.log`、`.cache/appearance-color-core-673.log`）。本阶段仅 Swift UI／测试改变，不将此前 Rust 回归计作新运行。

最终 CUA 再检查仍报告 Mac 锁屏，未操作新的系统授权或用户 API 配置。默认应用已由项目脚本恢复启动，但本轮工作区可交互、颜色输入／面板及重启前台验收仍待解锁，不用进程或启动命令成功替代。随后第 670 篇冻结全量原进程取得 exit 0：2,890 项、2 跳过、0 失败及 IPC 通过；已核对冻结资源未变，详见第 670 篇。这是旧提交结果，不覆盖本阶段。

## 冻结全量终态补充

2026-10-08 20:47:45，冻结提交 `bbee043bb8af011248d8d9e948f8fe9295f11a4b` 的原 handle 99495 取得 exit 0：**2,907 项 Swift、2 跳过、0 失败**，4,704.905 秒，随后 IPC exit 0。两项跳过是未配置 `SHIPIOS_VOICE_PREVIEW_FIXTURE_URL` 的本地语音预览／取消音频夹具，不能计为这些音频路径通过。本轮离线语法冷启动恢复计数为零。

终态核对 76 个捕获源夹具、169 个捆绑资源、测试执行文件、保存 helper 及完整参考 CSS 均未变化，记录 `.cache/full-alignment-regression-673-final-audit.json`；日志／manifest／status 同前缀。后续开发一直使用另一缓存，原进程没有因为观察期限而重启。此全量覆盖冻结的第 673 篇，不覆盖第 674—677 篇及以后的代码，也不代替锁屏期间缺少的前台验收。native-ui-654 在终态审计后方可复用。

## 仍待完成

全部窗口激活／失活及焦点来源、颜色面板精确材料／阴影／位置／动效、字体字重与响应式、真实账户主题服务和完整页面配对仍缺。CUA 前台验收此前受 Mac 锁屏阻挡，继续等待已发出的解锁请求。目标保持 21 个主页面／交互类别、26 个设置面及 29 项核心功能，完整双端配对仍 **0/47**，不按测试数量换算完成比例。
