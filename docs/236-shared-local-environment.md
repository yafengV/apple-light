# 项目共享本地环境文件

ShipiOS 的环境页现在读取并显式保存项目内的 `.codex/environments/environment.toml`。项目打开时，存在有效共享文件就以其中的名称、默认及分平台 setup/cleanup 和 Actions 覆盖 ShipiOS 的私有缓存；不存在时保留既有私有配置作为初始草稿。构建容器、Scheme 和构建配置仍只存放在 ShipiOS 私有工作区记录中。

保存前比较文件内容的 SHA-256 修订值。若 Codex 或其他编辑器在载入后修改了文件，ShipiOS 拒绝覆盖并提示重新载入。解析失败、未知字段、符号链接、超过 32 KiB 的文件同样不被覆盖。显式保存采用同目录临时文件和原子替换；项目切换时自动保存私有草稿，不写共享文件。已有工作树 setup/cleanup 和任务顶部 Actions 使用载入后的配置。

Rust 测试覆盖 Codex 格式读取、往返保存、版本冲突和符号链接拒绝；Swift 集成测试覆盖真实 Agent 下的项目打开、字段映射、保存与外部编辑冲突。此阶段只接入项目默认 `environment.toml`，未实现同目录多环境文件的选择、云环境或当前 Codex Mac 的页面视觉及原生交互配对。
