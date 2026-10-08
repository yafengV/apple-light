# 调试构建使用稳定开发签名

日期：2026-10-07。用户反馈每次调试运行都要重新信任文件夹。

## 原因与改动

原构建脚本对主应用与 helper 均执行 `codesign --sign -`。实际检查主应用指定要求只包含本次 `cdhash`，TeamIdentifier 未设置；helper 标识还包含构建产生的 UUID。因此代码变化后无法依赖稳定签名身份沿用授权。这是已确认的签名缺陷，不能单独证明所有历史读取停滞都是它导致。

苹果 [TN3127](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements) 说明，相互兼容的 designated requirement 才能共享隐私资源授权，开发与分发签名的要求也可能不同。

- `script/build_and_run.sh` 自动选择本机有效 Apple Development 证书；`SHIPIOS_CODESIGN_IDENTITY` 可指定名称或指纹。显式选择失败会使构建失败，不悄悄回退。
- `script/macos_signing.sh` 先签 helper，固定标识 `dev.shipios.agent`，再签主应用 `dev.shipios.desktop`，最后执行严格深度校验。
- 本地调试关闭时间戳请求，保持原有调试运行方式。未新增沙箱或其他权限，不修改 TCC、钥匙串访问控制或系统授权记录。
- 没有可访问的开发证书时停止构建，避免受限环境把已有开发签名降级；显式 `SHIPIOS_CODESIGN_IDENTITY=-` 才允许 ad-hoc，并提示可能再次授权。多开发身份的机器建议在本地环境中固定选择。
- 证书、私钥、个人证书名称/指纹和本机配置不提交。

## 验证

本机现有开发证书签署正式应用与 helper 成功，证书链、TeamIdentifier 和两个固定标识已确认。通过项目脚本连续两次构建启动，主应用与 helper 的指定要求完全相同。两次均在原桌面项目恢复原任务与中文草稿；第二次实际打开 `Focus.txt`，内容可读取且编辑器获得焦点，未操作新的文件夹授权弹窗。

`bash script/smoke_macos_signing.sh` 使用真实开发证书和两版不同代码的 Mach-O 测试程序，确认主应用与 helper 的 CDHash 均变化、指定要求均不变，新版仍通过上一版要求的验证；无效的显式证书会失败。最终日志 `.cache/development-signing-smoke-verified-658.log`，exit 0。早期冒烟脚本分别因未请求足够详细的 CDHash 输出和遗漏内联要求的 `=` 前缀失败，已修正；这些失败不属于应用签名失败，日志保留。

正式构建日志 `.cache/development-signing-first-run-658.log`、`.cache/development-signing-second-run-658.log` 均 exit 0。两次签名要求保存在 `.cache/development-signing-{app,helper}-{first,second}-658.txt`，个人公开签名信息只保留在忽略目录。

2026-10-08 补充验证：受限执行环境实际返回 `0 valid identities found`，而相同机器在可访问钥匙串的环境中能够使用现有 Apple Development 证书。因此移除默认 ad-hoc 回退，缺少可访问身份时在停止旧应用或覆盖构建产物之前失败；临时签名必须显式选择。`smoke_macos_signing.sh` 新增无身份拒绝与显式临时签名选择检查，真实证书的两版代码身份稳定检查也通过（`.cache/development-signing-no-downgrade-smoke.log`，exit 0）。受限环境的失败路径通过（`.cache/development-signing-restricted-environment.log`）。通过 `script/build_and_run.sh --app` 完成当前代码构建与启动命令，exit 0，正式包与 helper 均通过严格签名校验；本轮 Mac 锁屏，未完成前台工作区交互验收，不将启动命令成功描述为页面验收通过。

## 边界

2026-10-08 当前请求复验：通过标准脚本重建并执行启动命令，主应用与 helper 均严格校验通过；真实证书的两版不同代码身份稳定测试再次通过（`.cache/development-signing-request-final-676.log`）。正式包 IPC／Core 冒烟通过。Mac 仍锁屏，本次重复授权弹窗的前台复验待解锁，不能仅凭签名测试宣称所有文件夹权限问题已解决。

从旧 ad-hoc 身份首次切换开发证书，或以后换开发团队/签名类型，macOS 仍可能要求一次授权。稳定签名不会绕过首次授权、已有拒绝或已撤销权限，也不代替发布签名/公证。现有测试证明签名要求在代码变化后稳定以及两次实际运行正常，不把它描述为所有 macOS 权限和全部 UI 对齐已经完成。

2026-10-08 用户再次反馈后复验：当前正式包已采用开发证书，无须另装证书或重置系统权限。真实证书的两版不同代码测试再次通过（`.cache/development-signing-current-request-678.log`）；使用独立 native-ui-654 缓存执行标准构建启动脚本，exit 0（`.cache/development-signing-run-678.log`），未触碰正在执行全量回归的 native-ui-648 缓存。重建后主应用及 helper 均使用 Apple Development，指定要求与重建前相同，并分别通过旧要求验证及严格深度校验。CUA 仍明确报告 Mac 锁屏，因此本次前台工作区和重复授权弹窗仍未验收；上述结果仅证明实际调试包与签名稳定性，不把启动成功等同于权限弹窗已消失。

## 解锁后的实际文件夹访问复验

2026-10-08，本次 Mac 已解锁。再次通过 `script/build_and_run.sh --app` 连续两次重建启动，均 exit 0，日志为 `.cache/development-signing-user-request-run.log` 和 `.cache/development-signing-user-request-second-run.log`。使用 native-ui-654 缓存，没有覆盖全量回归使用的 native-ui-648。

第一轮在原生界面打开命令菜单，再用项目文件夹选择器打开当前桌面仓库 `apple-light`；通过文件搜索实际打开 `AGENTS.md`，编辑器显示完整内容与“已保存”。第二轮重建启动后，初始的“正在恢复工作区…”状态随后结束，同一项目、文件标签和内容直接恢复；文件列表刷新、筛选和清空筛选均可操作。两轮观察过程中没有出现新的文件夹授权或信任弹窗，没有接受新系统权限、重置 TCC 或修改钥匙串访问控制。此结论限于本机当前仓库与这两次实际运行。

真实开发证书的两版不同代码冒烟再次通过（`.cache/development-signing-user-request-check.log`）：应用与 helper 的 CDHash 改变，指定要求保持不变，并通过旧要求验证；无身份与无效身份拒绝、显式临时签名选择检查也通过。正式包重建前后的指定要求一致，应用与 helper 均确认使用 Apple Development，并通过旧要求与严格深度校验（`.cache/development-signing-user-request-result.json`）。受限执行环境不能读取完整证书信任链，签名详情与校验使用可访问系统钥匙串的执行环境完成；没有因此降级签名。日志与本机公开证书详情仅留在忽略目录，未提交个人证书信息。本轮复验未修改签名实现，沿用上述已提交的稳定开发签名方案。

## 2026-10-09 当前调试入口复验

当前请求再次检查现有实现：真实开发证书的两版不同代码冒烟通过（`.cache/development-signing-request-recheck.log`）；通过标准 `script/build_and_run.sh --app` 重建并执行启动命令，exit 0（`.cache/development-signing-request-standard-run.log`）。主应用和 helper 均使用 Apple Development，指定要求仍与第 690 篇重建前一致，分别通过旧要求及严格深度校验（`.cache/development-signing-request-standard-signature-verified.log`）。首次调用校验脚本遗漏 `after` 参数而失败，日志保留；补齐参数后通过，这不是应用签名失败。

此次重新签名后的 helper 文件字节与第 691 篇保存的测试副本不同，但 CDHash 相同；签名封装字节一致与代码摘要／指定要求一致分别检查，不将它们混为一谈。本轮没有修改签名实现。CUA 当前返回 Mac 锁屏，故本轮无法复验工作区可交互或授权弹窗；上节解锁后的两次运行结果仅作为此前本机证据。

当前 `421ae19` 再次复验：`smoke_macos_signing.sh` 的两版不同代码、应用／helper 稳定要求、旧要求校验，以及无证书／无效证书拒绝检查均通过（`.cache/development-signing-latest-smoke.log`）。标准 `script/build_and_run.sh --app` 构建及启动命令 exit 0（`.cache/development-signing-latest-run.log`）；主应用与 helper 均使用 Apple Development，重建前后指定要求一致，分别通过旧要求验证和严格深度校验（`.cache/development-signing-latest-verification.log`）。当前代码没有变化，因此正式包代码摘要不变；代码变化后的稳定性由两版不同代码冒烟验证。再次检查前台时 Mac 仍锁屏，本轮不宣称工作区交互或弹窗已实际验收。签名实现无须重复修改；证书与验证产物继续只留在忽略目录。
