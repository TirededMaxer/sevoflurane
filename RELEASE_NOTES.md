完全移除米哈游模块：设置和搜索入口、安装/更新/校验/修复、CLI/MCP 命令、Sophon 编解码依赖、原神帧率解锁及专用启动辅助。保留现有容器、游戏文件、存档和通用 Steam 功能。

源码在本地修改后同步 GitHub，全部测试、构建、签名与打包由 GitHub Actions 的全新 Apple Silicon runner 完成。不读取本机缓存，不打包商业 CrossOver 引擎。新版资产上传后回下载核对 SHA-256，发布成功后只保留最新 Release。

延续先前的窗口位置记忆、菜单悬浮高亮、Steam 原生好友提示、云存档上传状态及原版 UI 隐藏补丁。本包采用 ad-hoc 签名，保留 hardened runtime 和麦克风 capability。
