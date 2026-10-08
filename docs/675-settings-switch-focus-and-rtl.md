# 设置开关的焦点轮廓与 RTL 圆点

日期：2026-10-08。接续第 674 篇，继续核对共享设置控件；范围仍为全部页面、交互与核心功能。

## 参考与边界

固定 Codex 26.930.51102 / build 13100。`script/extract_settings_switch.cjs` 校验公开 shared JS 与完整 CSS 的 SHA-256，执行实际 `gyi`／`_yi`／`xyi` 函数。受控 React memo cache 与 JSX 返回真实组件树，涵盖 checked、disabled、default／sm、accent／neutral 的 16 种组合，并执行普通点击及调用方 preventDefault 回调。提取结果保存为 `settings_switch_reference_675.json`，没有执行 React 生命周期、浏览器默认键盘行为或真实 Codex 窗口。

WebKit 加载完整固定 CSS，对这些实际组件树在 LTR／RTL 下的 32 个结果测量尺寸、圆点位置、透明度与过渡时长。默认轨道 32×20、圆点 16×16；小号轨道 28×16、圆点 12×12；两者圆点起点均为 2／14，顶部 2；禁用透明度 0.6、过渡 0.15 秒。原生共享设置样式本轮继续采用默认尺寸，小号和中性变体是参考覆盖，不代表已在产品中增加全部变体。

参考焦点为 focus-visible、2 点 ring，颜色使用主题 borderFocus；圆点阴影为黑色约 8%、1 点竖向偏移、2 点模糊及 −1 点 spread。公开主题初始化会把强调色绑定到 chart-blue 的底层 token，因此自定义强调色轨道不是应当移除的差异。

## 问题与实现

旧原生样式将 RTL 的 offset 再乘 −1，但 SwiftUI 已镜像 leading 对齐与 offset，导致开启状态圆点移到轨道外。旧焦点轮廓外扩 3 点且留下 1 点间隙，深色模式仍使用原始强调色；点击还会直接展示键盘焦点样式。

提取无行为变化的 `SettingsSwitchSurface` 后保留旧实现作基线。初始 6 条失败中包含测试色彩空间重复转换：ImageRenderer 给出 sRGB 图像，而 NSBitmapImageRep.colorAt 将返回值标成 calibrated RGB，再转换会使原始纯红产生绿色分量。修正取样后，旧实现 **6 项、4 条断言失败、0.998 秒**（`.cache/settings-switch-baseline-corrected-675.log`），准确复现 RTL、焦点外边界／间隙和深色焦点色的问题；禁用透明度原本正确。

现在仅使用 SwiftUI 的一次方向镜像；轮廓外扩 2 点并紧贴轨道，改用解析后的 borderFocus。圆点的阴影透明度调整为 8%，使用缩小 2 点的投影形状表达负 spread。这个阴影实现是原生近似，尚无完整浏览器／原生逐像素阴影验收。

样式记录鼠标／键盘焦点来源：点击保留实际焦点但不画键盘轮廓，普通键盘输入恢复轮廓，失焦后重置来源；保留原有绑定、禁用保护、滚动显露、辅助功能表示及 Space／Return keyDown 切换。浏览器 button 的 Space 释放时序与全部 focus-visible 启发式尚未配对，本轮不宣称键盘行为完全相同。

## 验证

定向 **6 项、0 失败／跳过、0.274 秒**（`.cache/settings-switch-focused-675.log`），覆盖实际公开回调／完整 CSS、原生两种方向圆点、焦点轮廓、深色角色和禁用绘制。原生图像保存到忽略目录 `.cache/settings-switch-focused-675-snapshots`，取样前确认位图为 sRGB。

最终扩大回归 **534 项、0 失败／跳过、168.590 秒**（`.cache/settings-switch-expanded-final-675.log`），覆盖完整设置／外观／命令／恢复／归档／快捷键／个性化／代码主题／PR 评论菜单集合。提取器重新执行后与提交夹具逐字节一致（`.cache/settings-switch-reference-reproduced-675.json`）。

通过 `script/build_and_run.sh --app` 使用 native-ui-648 构建正式包并执行启动命令，exit 0（`.cache/settings-switch-final-default-run-675.log`）；Apple Development 严格深度校验通过（`.cache/settings-switch-final-signature-675.log`）。正式 helper 与保存的第 673 篇测试 helper CDHash 一致（`.cache/settings-switch-code-equivalence-675.json`）。正式包 IPC 和本地 Core RPC 冒烟均 exit 0（`.cache/settings-switch-ipc-675.log`、`.cache/settings-switch-core-675.log`），涵盖流式事件／重放／取消／重启与原生审批／提问／引导／写入／隔离／凭据清理；没有调用真实用户 API。本轮无 Rust 源码改动，不把历史 Rust 回归作为新运行。

本轮 CUA 再次报告 Mac 锁屏；前台工作区可交互、鼠标／键盘来源和重启验收仍待解锁。隐藏渲染测试不等于实际页面验收。第 673 篇全量仍使用冻结 native-ui-654 的原 handle 99495；本轮开发使用已释放的 native-ui-648，不改冻结执行文件、资源或已捕获夹具。

开发后的中途核对确认冻结的 76 个源夹具、169 个资源、测试执行文件、保存 helper 和 CSS 均未变化（`.cache/full-alignment-regression-673-stage675-audit.json`）；此核对不是全量终态，也不证明覆盖本轮变更。

## 剩余范围

全部激活／失活与焦点来源、浏览器键盘释放语义、阴影与动效逐像素、macOS 14 实机、真实用户 API 服务及全部页面双端交互仍需验证。完整范围保持 21 个主页面／交互类别、26 个设置面、29 项核心功能；完整配对 **0/47**，不把共享控件通过换算为整页完成率。
