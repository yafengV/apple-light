# 子目录项目的完整仓库审查

## 实际差异与对照

当前[官方审查文档](https://developers.openai.com/codex/app/review)说明，项目只需位于 Git 仓库内即可审查，审查页反映仓库的实际变更，包含用户与 Agent 产生的变更。ShipiOS 原有 Git 发现上限使仓库子目录显示为没有仓库，提交、分支与审查操作也要求重新打开根目录。

真实临时仓库的复现测试失败：子目录项目没有 Git 状态、无法提交、仓库内外的变更均未显示，见 `.cache/nested-git-review-before.log`。第 366 篇的创建入口不会创建嵌套仓库，但这一已有仓库的正常审查入口仍缺。

## 实现与范围

任务目录与审查仓库独立保存。识别最近的 `.git` 目录或工作树/子模块 Git 文件，经 Git 确认所属根目录；不因当前子目录没有 `.git` 就初始化仓库。损坏的最近元数据、已删除的项目目录不会退回其他祖先仓库。

审查的差异、分级暂存/取消暂存、撤销、提交选择与统计、说明生成、分支、推送及 PR 上下文共用完整仓库范围。子目录项目显示仓库路径，让用户知道审查文件的相对基准。执行目录、项目、任务草稿及文件预览保持原归属。

文件树仍限于选定项目：从仓库查询该目录的文件，再转换为项目内相对路径，保留已跟踪的隐藏文件与忽略规则；显式打开的整个被忽略项目仍保留原来的文件枚举回退。普通文件读取不会因此允许 `../` 越界。

审查文件打开使用卡片绑定的仓库，旧卡片请求不能改用新仓库。评论继续绑定原任务和项目，额外记录仓库作为文件相对路径基准；发送前检查所属仓库变化，旧评论格式仍可读取。模型审查快照保存仓库根目录，并在独立 API 及 Core 的只读差异上下文中用 JSON 说明路径基准；任务与模型工具工作目录保持不变。PR 请求在仓库执行，结果仍记录到原项目任务。

写入前检查项目代次、仓库和只读设置；创建新的嵌套仓库后，旧审查授权与批量快照不可继续使用。已经启动的 Git 操作可能完成，不能承诺回滚既有写入。

## 后台索引锁

较宽回归曾出现真实 `index.lock` 冲突。独立临时仓库确认普通 `git status` 会更新索引缓存，而 `--no-optional-locks` 阻止这一可选写入，见 `.cache/git-optional-index-reproduction.log`。[Git 文档](https://git-scm.com/docs/git#Documentation/git.txt-GIT_OPTIONAL_LOCKS)也明确说明这一后台读取用途。

新增索引字节校验继续发现，在本机 Git 中，普通 `git diff` 即使使用该选项仍更新索引；另行禁用 `diff.autoRefreshIndex` 后不再更新，见 `.cache/git-diff-index-reproduction.log`及[Git 配置文档](https://git-scm.com/docs/git-config#Documentation/git-config.txt-diffautoRefreshIndex)。两项仅作为命令参数，不修改用户或仓库配置。实际暂存、提交和分支写入仍遵守必要锁；遇到已有索引锁不会自行删除，锁释放后可重试。

## 验证记录

- `.cache/nested-git-review-first.log` 是新增测试误用异步 XCTest 自动闭包导致的编译失败；调整后 `.cache/nested-git-review-fixed.log` 执行 9 项，模型提示的 JSON 路径转义断言未通过，其余通过。路径显示改为不转义斜线。
- 首轮较宽集合 `.cache/nested-git-review-related.log` 执行 142 项，141 项通过，1 项分离审查夹具遭遇索引锁冲突，不能称整组通过。
- `.cache/nested-git-review-lock-fixed.log` 包含新测试的 Swift 参数名编译错误；修正后 `.cache/nested-git-review-lock-final.log` 执行 76 项，1 项跳过、3 项失败：被忽略项目列表回退、索引自动刷新，以及已有 400 毫秒文件搜索夹具的一次超时。
- 修复前两项后，`.cache/nested-git-review-lock-rechecked.log` 的 76 项集合零失败，其中 1 项真实 Agent 搜索因未提供环境变量跳过。文件搜索夹具复核通过，未修改其期限或产品搜索运行时；超时原因尚未确定。
- 最终全部相关集合以 `SHIPIOS_TEST_AGENT` 指定本地实际 Agent 执行，190 项全部通过，无跳过，日志 `.cache/nested-git-review-final.log`。覆盖新增 15 项及分支、提交、推送、PR、只读、差异块、评论、独立窗口和文件搜索回归；这次未复现搜索超时，不据此认定此前超时原因已修复。
- `script/build_and_run.sh --build-app` 构建与签名通过，日志 `.cache/nested-git-review-app-build.log`；`codesign --verify --deep --strict --verbose=2 dist/ShipiOS.app` 与 `git diff --check` 通过。本轮没有启动新构建进行原生交互验收。

原生可见布局、鼠标、焦点、跨窗口点击及当前 Codex 双端配对仍未验收。完整配对保持 0/45，多仓库选择、Last turn 比较和 PR 联合创建等仍待继续。
