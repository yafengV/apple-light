# 站点工具菜单层级与来源活动

依据 [OpenAI Site tools 文档](https://learn.chatgpt.com/docs/webmcp)和[桌面使用说明](https://help.openai.com/en/articles/20001423-using-site-tools-in-the-chatgpt-desktop-app)，地址栏菜单首层改为“可用站点工具（数量）”和有成功调用时出现的“最近使用”。前者展开当前页面工具清单，再点具体工具查看详情；后者打开所属任务的 Sources。菜单显示网站声明的读取/写入数量，并说明工具仅属于当前网页。

Sources 现在从持久化的成功浏览器调用中列出站点工具活动，按网站分组。每条记录可查看工具名、原始网页、页面标题和调用结果，也可打开网页。拒绝、取消和失败的调用不进入来源。调用发生后即使工具改变当前页，记录也保留**调用前**的页面 URL 与标题；请求参数没有被加入来源条目。

验证：`BrowserTests` 68 项、`BrowserPanelLifecycleTests` 2 项、`CodexBrowserTimelineTests` 4 项及 `TaskSummarySourceTests` 2 项通过；`script/build_and_run.sh --build-app` 和严格深度签名通过。当前桌面控制接口不能完成新构建的可交互窗口与 Codex 参考端配对，因此弹层点击、键盘/焦点、视觉及完整 45 项逐页逐交互验收仍待完成。
