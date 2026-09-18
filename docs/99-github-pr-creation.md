# GitHub PR 创建与草稿设置

2026-09-18。在现有审查页中加入创建 PR 弹层与 Git 设置的默认草稿选项。设置仍在主窗口内。

## 对照与协议

本机 Codex 的 `create-pull-request-modal-content-e1563a1fb9c7.js` 包含创建 PR 标题/描述、源分支到目标分支、草稿/普通 PR 操作及已有 PR 的浏览器入口。`git-settings-be89d122415f.js` 提供 Create draft pull requests；Git 操作状态包含 CLI 未安装、未认证、未推送和已有 PR 等原因。

实现依据 [GitHub CLI 创建 PR 文档](https://cli.github.com/manual/gh_pr_create)：显式指定 `--head` 跳过 CLI 自动推送或 fork；使用 `--repo`、`--base`、`--title`、`--body-file` 和可选 `--draft`。已有 PR 的结构化读取依据 [PR 列表文档](https://cli.github.com/manual/gh_pr_list)，默认分支读取依据 [仓库查看文档](https://cli.github.com/manual/gh_repo_view)。认证只检查 [github.com 当前活跃账户](https://cli.github.com/manual/gh_auth_status)，不读取 Codex 登录状态或输出令牌。

## 当前实现

- 主窗口和独立任务窗口的审查页共用创建 PR 弹层，读取仓库、默认目标分支、远端发布提交及已有 PR。
- 支持 github.com 的 HTTPS / SSH 远端。按 Git 推送偏好解析仓库与源分支，创建前复核本地 HEAD、分支、远端 URL 和服务器上的源分支提交。
- 标题、描述与目标分支可编辑；支持草稿/普通 PR。主窗口 Git 设置保存默认草稿偏好，并可从设置搜索定位。
- 默认分支、不存在的发布记录、未推送提交或远端不一致时给出原因。存在同仓库源分支的 PR 时展示并打开已有链接，不重复创建。
- 多行描述通过权限 0600 的临时文件传递，目录权限 0700，结束后清理。命令使用参数数组，不调用 shell，不请求 CLI 打开编辑器或交互提示。
- 读状态失败可重新检查；普通表单校验失败可编辑后重试。已发起创建但结果不确定时保留输入，要求先查询状态；重新查询发现已有 PR 后恢复链接。
- 输入按所属工作区保留，切换项目使用新的 PR 状态；只读审查不能创建 PR。关闭弹层后不应用过期的状态读取结果。
- CLI 在执行时重新发现，安装后可点击“重新检查”，无需依赖应用启动时的缺失状态。

## 测试与运行限制

本机未安装 `gh`，且桌面仍锁屏。测试使用真实临时 Git 仓库及本地可执行 CLI 夹具；夹具只读写测试目录，不连接网络、不读取真实 GitHub 凭据，也没有在当前项目创建远端 PR。这些测试不代表真实 GitHub 发布已经验收。

初次 6 项 PR 专项测试全部通过，日志 `.cache/github-pr-tests.log`。覆盖仓库/链接校验、显式分支与描述文件、草稿、重复创建保护、HEAD 变化、未推送提交、认证/CLI 缺失、远端不一致、结果不确定后的恢复以及只读审查/设置保存。

随后增加可编辑表单校验失败的测试，并修正活跃账户检查与 CLI 重新发现。完整回归 525 项通过，日志 `.cache/github-pr-full-tests.log`；最终 PR 专项 7 项通过，日志 `.cache/github-pr-final-tests.log`。本轮改动与后续设置交互修复一同打包，构建日志 `.cache/settings-interaction-build.log`。

## 仍未对齐

本篇记录最初的手动创建流程；描述留空自动生成与 PR 指令随后在 [第 101 篇](101-pr-generation-and-instructions.md) 接入。创建时一并提交/推送本地变更、浏览器预填创建、跨 fork/GitHub Enterprise/GitLab、合并与自动监控尚未补齐。原生布局、焦点和键盘行为仍待解锁后逐项配对；不能以本轮创建流程代表全部 PR 或全产品交互已对齐。
