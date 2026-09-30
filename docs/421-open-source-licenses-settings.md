# 通用设置中的开源许可子页

当前 Codex 桌面分发的通用设置有“Open source licenses”行，说明为“Third-party notices for bundled dependencies”；“View”会导航至 `/settings/open-source-licenses`，并带回通用设置的返回路径。依据为本地分发的 `general-settings-ed7ca2006cd3.js`（SHA-256 `3a2ff568faaa71fa98cde8ca59a04d525baf13ce81a470ea8ae72c5283800753`）及主路由模块 `app-initial-b21bd554b363.js`（SHA-256 `01c04b2e5a96e5dd4c97e02ffa183f571a55bef7a221abd99404246c430f2212`）。

ShipiOS 此前已在正式包中包含第三方许可文件，但通用设置没有查看入口。现在“开源许可”行打开主窗口内的子页，按文件名列出当前 ShipiOS 包内实际附带的声明，并显示可选择复制的完整正文。侧栏返回与 Escape 先回到通用设置，之后才返回应用；切到其他设置页或再次打开通用设置会退出子页。设置搜索可定位入口。缺文件、不可读文件和无效 UTF-8 有明确错误或空状态，重试会重新读取包内文件。

文件读取、顺序、错误、设置返回和搜索路由测试通过；264 项相关回归通过，耗时 74.066 秒，日志 `.cache/open-source-licenses-regression.log`。最后新增的键盘返回断言再次通过三项定向测试，日志 `.cache/open-source-licenses-final-targeted.log`。`script/build_and_run.sh --build-app` 成功，日志 `.cache/open-source-licenses-build.log`；严格深度签名通过，正式包的七份许可文件和 29 个语法资源与源文件逐字节一致。

这些许可是 ShipiOS 自身捆绑依赖的声明，不应冒充 Codex 产品的完整许可目录。本轮没有可见双端逐页、真实点击或辅助功能验收，完整配对仍为 **0/45**。
