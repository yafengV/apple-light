# 语音快捷键值、编辑、清除与取消

日期：2026-10-08。接续第 680 篇，保持全部 47 类页面／交互及 29 类核心功能的目标；本篇不代表整页、真实语音链路或全部对齐已经完成。

## 参考与实现

继续固定公开 Codex 26.930.51102／build 13100。`app-primary-c0280d43ce72.js` SHA-256 为 `234429db84d9319850ff0766a4a5052a9e898bfa0611883633f80018080dd6c0`；其导入 `app-shared-9d148924be0b.js` SHA-256 为 `eb2500c5398279d4fbf5c71d7ce982d54631660907761740199f6c22591d71ab`。核对真实 `lBe`／`uBe` 与共享 export `SE` 对应的 `Oli`，没有把同名本地变量当作组件。

新增 `script/extract_voice_shortcut_controls.cjs` 执行这些实际函数，提取未绑定、已绑定、禁用与录制四种分支，输出源夹具并逐字节复现。非录制分支为非按钮的快捷键值、独立编辑 ghost 工具按钮，以及已有绑定时的清除按钮；录制分支仅输入框与取消按钮。取消 mouseDown 调用 preventDefault，避免提前 blur；输入框本身会捕获 Tab，不虚构 Tab 离开录制器的参考行为。声明类给出默认行至少 32、内部间距 4、清除前间距 8，以及 144 最大宽度的录制区。该夹具只执行本地 hooks／JSX 与回调，未执行 DOM 焦点、CSS 级联、禁用按钮的浏览器事件阻止或真实注册／持久化。

实际语音页按这一结构替换旧绑定按钮和 plain xmark：未绑定显示“关闭”，已绑定显示快捷键标签；编辑和清除各自具有模式明确的辅助功能名称与标识；录制时隐藏编辑／清除，显示独立“取消”。新增原生 `VoiceShortcutActionButton` 保留 Tab、Space 松开、Return／数字键盘 Enter、标准 press 和 AX 激活，失焦／失活／禁用／卸载清理待处理动作。取消按钮 pointer-down 保持录制器焦点，pointer-up 在按钮内才取消；旧取消回调核对录制身份，不影响新录制。

按钮使用共享主题文字、透明 hover、28 点工具尺寸及焦点轮廓；快捷键值按参考声明使用紧凑背景／内边距和被动标签。当前编辑／清除图标使用 SF Symbols，尚未证明与参考 SVG 像素相同；完整 CSS、精确视觉与动效继续待配对。真实异步注册失败回滚／pending 仍属于后续工作，不能用本地禁用或保存测试代替。

## 验证

首轮专项 39 项、2 条失败（`.cache/voice-shortcut-controls-focused1-681.log`）：命中测试误把父视图自身坐标传给父视图 hitTest，短视口孤立页面未提供实际设置容器的 ScrollViewReader reveal 回调。修正为自有按钮的父坐标命中，并在夹具中提供与 RuntimeSettingsView 相同的实际滚动回调；未改生产控件来迁就夹具。

修色前专项 **40 项、0 失败／跳过、31.774 秒**（`.cache/voice-shortcut-controls-focused2-681.log`）。最初八项新验证覆盖真实页面的条件控件／独立命名、Tab 到清除、Space 松开只清所属绑定并持久化、取消 pointer-down 保持录制焦点／up 取消且不注册、外部释放／应用失活取消等待、过期取消回调隔离、失焦和 repeat Space 不清除、数字键盘 Enter、400×400 RTL 的控件顺序／焦点滚动／取消尺寸，以及实际公开组件 trace。隐藏窗口指针测试先核对真实 hitTest，然后把事件送到命中的自有原生控件，不声称覆盖系统窗口分发。

修色前扩大回归 **613 项、0 失败／跳过、216.424 秒**（`.cache/voice-shortcut-controls-expanded-681.log`），与专项重叠，不累加；正式构建／签名／IPC／Core 及前台验收正在进行，终态另补。

## 剩余范围

真实注册失败回滚／pending、全部热键解码与系统来源、提示音／双击免提、动态设备／语音能力、共用麦克风、屏幕引导、词典完整前台编辑／IME、录音菜单／恢复、实录／转写／播放／跨应用写入、真实服务及 macOS 14 实机仍缺。完整逐页双端配对仍为 **0/47**；第 677 篇 2,938 项全量仅覆盖其冻结构建，不覆盖本篇。

## 绘制复验补充

离屏整页检查 `.cache/voice-shortcut-controls-expanded-681-snapshots/page-voice.png` 发现新编辑图标为纯白。原绘制调用 `AppearanceRGBA.opacity(1)` 覆盖了共享 tertiary 角色原有 alpha，并非乘上启用／禁用比例。新增实际原生绘制回归检查编辑、清除和取消在黑底的主题 alpha 与禁用透明度。最初彩色夹具对 `colorAt` 的 calibrated-RGB 标签再次转换，混入不成立的绿色断言（`.cache/voice-shortcut-controls-alpha-before-681.log`）；改为中性色编码通道读取后，旧绘制 **1 项、4 条失败、0.753 秒**（`.cache/voice-shortcut-controls-alpha-before2-681.log`），确认真实透明度缺陷。第一步保留 alpha 后，SF Symbol 调色板使图标透明度重复应用：41 项专项出现 4 条下限失败（`.cache/voice-shortcut-controls-focused3-681.log`）。改为使用不透明符号调色板，并在合成时仅应用一次主题 alpha；最终专项 **41 项、0 失败／跳过、31.568 秒**（`.cache/voice-shortcut-controls-focused-final-681.log`）。上述 40／613 项不覆盖此后的绘制修改，最终扩大回归另行完成。

正式包首轮构建／开发签名、IPC／Core 均通过，但进入前台验收时 Mac 再次锁屏，CUA 明确无法自动解锁。准备的独立测试目录没有复制用户配置或 API 凭据；新控件的实际前台点击／重启保存尚未验收，不沿用第 680 篇旧控件的前台结果。

## 最终验证

最终扩大回归 **614 项、0 失败／跳过、216.233 秒**（`.cache/voice-shortcut-controls-expanded-final-681.log`），覆盖最终绘制修改，与 41 项专项重叠，不累加。重新检查原生离屏整页，编辑图标已保留 tertiary 透明度；这不是 Codex 前台像素配对。

通过 `script/build_and_run.sh --app` 重新构建并恢复默认工作区目录（`.cache/voice-shortcut-controls-final-default-run-681.log`）。最终 App 与 helper 均为 Apple Development，旧 designated requirement 验证通过、身份保持不变，App 代码哈希更新，helper 与测试版本相同，整个包严格递归验签通过（`.cache/voice-shortcut-controls-code-equivalence-final-681.json`）。此前第 658 篇补充的两次正常重建／文件读取交互未再出现重复授权提示；本次再次尝试前台时 Mac 仍锁屏，启动命令成功不能替代新增控件或工作区实际交互验收。

最终正式包 IPC 和 Core RPC 本地冒烟均 exit 0（`.cache/voice-shortcut-controls-ipc-final-681.log`、`.cache/voice-shortcut-controls-core-final-681.log`），使用本地夹具，未调用用户真实 API 或录音。

## 冻结全量终态（2026-10-09）

提交 `9e919e2e8fb507303b6447ee036761408ab53973` 的固定全量已终态 exit 0：**2,976 项 Swift、2 跳过、0 失败、4,745.688 秒**，IPC 也 exit 0（`.cache/full-alignment-regression-681.log`、`-status.json`）。两项跳过为未配置的本地语音音频夹具；离线语法冷启动恢复为 0。

终态核对 **83 个原源夹具、176 个编译资源、测试执行文件、保存的 helper 与参考 CSS** 全部符合冻结哈希（`.cache/full-alignment-regression-681-final-audit.json`）。期间后续开发已改动部分原源码，因此不宣称当前整个源码仍等于冻结提交；测试实际使用冻结的 native-ui-654 可执行文件／资源与未变源夹具。本结果不覆盖第 682 篇以后改动，也不替代真实前台或完整双端配对，仍为 **0/47**。
