# PR 评论中的 GitHub 媒体

Codex Mac 的 PR 评论会把 GitHub 附件图片和视频直接放在评论正文中，并在加载失败时提供原地址。ShipiOS 此前把 Markdown 图片一律渲染为链接文字。本阶段在 Activity 与 Code 共用的评论正文中加入媒体片段：支持 GitHub 附件、公开和私有 GitHub 用户图片域名下的 Markdown 图片、单独的视频 URL，以及独立的 HTML `img`/`video` 标签。其余 Markdown、代码块和非允许来源保持原有渲染。

此阶段的媒体下载只接受 HTTPS 的 GitHub 媒体来源，重定向仅能留在 GitHub/GitHubusercontent 域名，禁用 cookie 与缓存；根据响应类型区分图片和视频，流式限制图片 24 MiB、视频 64 MiB。视频写入私有临时目录供系统播放器读取，视图消失时停止播放并删除。此阶段尚未接入私有仓库媒体认证；后续第 556 篇已接入 GitHub CLI 令牌、将大小限制统一改为 10 MiB，并调整成功/失败展示。

5 项媒体解析/来源/类型测试及 21 项评论折叠和 Markdown 回归通过。`script/build_and_run.sh --build-app` 与严格签名检查通过。Mac 当前锁屏，尚未完成图片、视频、焦点、三行折叠和 Codex 双端前台配对；完整验收仍为 **0/47**（主工作区 21 项、设置 26 项），表示待验收面数量，不是已确认缺陷数量。
