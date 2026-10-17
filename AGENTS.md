# Sevoflurane 工作规则

- 本机唯一项目 Git 工作副本位于 `/Users/mac/Desktop/Projects/Sevoflurane`；直接在此修改，保留完整提交历史，不另建项目克隆或工作树。
- 源码先在本地修改、审查，再提交和推送到 `TirededMaxer/sevoflurane`。
- 所有编译、测试、签名及打包交给 GitHub Actions 的 `Cloud build and release` 工作流（`release.yml`）。使用全新 GitHub 托管 Apple Silicon runner，按已提交的 Package.resolved 下载依赖，不恢复本地或远程编译缓存。不得在本机运行 Xcode 构建或保存 DerivedData、SwiftPM 缓存和发行包。
- 本机只保留源码、Git 历史和项目相关文档；本地可做差异审查及脚本/配置语法检查。需要运行验证或重装时，从成功的云端 Release 下载到临时目录，核对 SHA-256 后安装并清理临时文件。
- 版本号同步更新所有目标的 MARKETING_VERSION/CURRENT_PROJECT_VERSION 和 RELEASE_NOTES.md 后，推送源码，在 main 上手动启动工作流。工作流先完整测试、构建、签名验证与 CLI/MCP 检查，再上传草稿；回下载核对上传状态、大小和 SHA-256 后发布。确认新版可下载后删除旧 Release，仅保留一个最新构建；保留 Git 标签和提交历史。
- 更新本地 `/Applications/Sevoflurane.app` 时正常退出应用，并保留已有 CrossOver 引擎、Steam 容器、游戏和存档。运行时安装不是编译缓存，不得作为清理目标。
