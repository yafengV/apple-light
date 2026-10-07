# 调试构建使用稳定开发签名

日期：2026-10-07。用户反馈每次调试运行都要重新信任文件夹。

## 原因与改动

原构建脚本对主应用与 helper 均执行 `codesign --sign -`。实际检查主应用指定要求只包含本次 `cdhash`，TeamIdentifier 未设置；helper 标识还包含构建产生的 UUID。因此代码变化后无法依赖稳定签名身份沿用授权。这是已确认的签名缺陷，不能单独证明所有历史读取停滞都是它导致。

苹果 [TN3127](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements) 说明，相互兼容的 designated requirement 才能共享隐私资源授权，开发与分发签名的要求也可能不同。

- `script/build_and_run.sh` 自动选择本机有效 Apple Development 证书；`SHIPIOS_CODESIGN_IDENTITY` 可指定名称或指纹。显式选择失败会使构建失败，不悄悄回退。
- `script/macos_signing.sh` 先签 helper，固定标识 `dev.shipios.agent`，再签主应用 `dev.shipios.desktop`，最后执行严格深度校验。
- 本地调试关闭时间戳请求，保持原有调试运行方式。未新增沙箱或其他权限，不修改 TCC、钥匙串访问控制或系统授权记录。
- 没有开发证书时保持原可构建能力，但明确提示 ad-hoc 签名可能导致再次授权；显式 `SHIPIOS_CODESIGN_IDENTITY=-` 也会提示。多开发身份的机器建议在本地环境中固定选择。
- 证书、私钥、个人证书名称/指纹和本机配置不提交。

## 验证

本机现有开发证书签署正式应用与 helper 成功，证书链、TeamIdentifier 和两个固定标识已确认。通过项目脚本连续两次构建启动，主应用与 helper 的指定要求完全相同。两次均在原桌面项目恢复原任务与中文草稿；第二次实际打开 `Focus.txt`，内容可读取且编辑器获得焦点，未操作新的文件夹授权弹窗。

`bash script/smoke_macos_signing.sh` 使用真实开发证书和两版不同代码的 Mach-O 测试程序，确认主应用与 helper 的 CDHash 均变化、指定要求均不变，新版仍通过上一版要求的验证；无效的显式证书会失败。最终日志 `.cache/development-signing-smoke-verified-658.log`，exit 0。早期冒烟脚本分别因未请求足够详细的 CDHash 输出和遗漏内联要求的 `=` 前缀失败，已修正；这些失败不属于应用签名失败，日志保留。

正式构建日志 `.cache/development-signing-first-run-658.log`、`.cache/development-signing-second-run-658.log` 均 exit 0。两次签名要求保存在 `.cache/development-signing-{app,helper}-{first,second}-658.txt`，个人公开签名信息只保留在忽略目录。

## 边界

从旧 ad-hoc 身份首次切换开发证书，或以后换开发团队/签名类型，macOS 仍可能要求一次授权。稳定签名不会绕过首次授权、已有拒绝或已撤销权限，也不代替发布签名/公证。现有测试证明签名要求在代码变化后稳定以及两次实际运行正常，不把它描述为所有 macOS 权限和全部 UI 对齐已经完成。
