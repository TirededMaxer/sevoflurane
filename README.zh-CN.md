# Sevoflurane — TirededMaxer fork

基于 [kageroumado/sevoflurane](https://github.com/kageroumado/sevoflurane)，保留原作者署名。本 fork 修复顶部拖拽与双击最大化，恢复 Steam 右下角提示，转接标准 Win32 错误对话框，并在顶部菜单显示云存档上传状态。详见[修改范围、构建和验证](FORK_NOTES.md)。

Sevoflurane 为 Mac 带来类似 Proton 的体验，在同一个 Steam 界面中运行 Windows 和 macOS 游戏。原生 WebKit 窗口替代通过 Wine 渲染的 Chromium 界面，Steam 在后台运行，通知使用 Steam 原有的右下角提示。老游戏也能调整窗口大小，并开启画面放大与超分。

<a href="https://github.com/TirededMaxer/sevoflurane/releases/latest"><img src=".github/download.zh-CN.svg" alt="下载 Mac 版 Sevoflurane" width="360" height="80"></a>

![Steam 游戏库](.github/sevoflurane-library.png)

## 特色

- 在同一游戏库中运行 Windows 和 Mac 原生游戏，并为每款游戏选择版本。
- 用 WebKit 窗口操作 Steam；Windows 客户端在后台运行，右下角显示 Steam 原有提示。
- 调整老游戏的窗口大小，并使用 Lanczos、MetalFX、Anime4K 或 CuNNy 放大画面。
- 每款游戏都有独立的程序坞图标和图形设置。

<details>
<summary>完整功能</summary>

- **安装：** Steam 设置向导、新建或接入容器、Dormison/CrossOver/CrossOver Preview、字体及旧版运行库、Rosetta 和游戏移植工具包；支持后台安装和 `sevo setup`。
- **Steam：** 游戏库、商店、好友、聊天、Big Picture、键盘和手柄配置使用 Mac 窗口；原生菜单、剪贴板、启动选项提示、`steam://` 链接和 Steam 右下角提示。
- **个性化：** 实时重载 CSS 样式、直播模式，以及低电量模式和减少动态效果联动。
- **兼容性：** Sevoflurane、AppleGamingWiki 和 ProtonDB 的分版本评分、反作弊信息、游戏库奖牌、Mac 原生版标记和本机可玩筛选。Linux 评分单独显示，不决定 Mac 筛选结果。
- **启动：** 菜单栏和程序坞中的最近及已安装游戏、单次或永久渲染器选择，以及外部程序快速启动。
- **游戏窗口（Dormison）：** 独立程序坞图标、游戏模式、可调整大小的固定分辨率窗口、Lanczos/MetalFX/Anime4K/CuNNy 放大、实时滤镜、帧率限制及 CPU/GPU/帧时间显示。
- **输入与视频：** 支持震动的 Xbox/PlayStation 手柄，D3DMetal 上通过 MetalFX 实现 DLSS。Dormison 另支持原始鼠标、光标限制、原生 Win32 菜单、CPU 核心数限制及 H.264/HEVC 硬件解码。
- **原生游戏：** 支持的引擎可安装 macOS 游戏并按游戏切换版本，也可转交 Steam for Mac；原生 NW.js 游戏保留 Steam 游戏时长和成就。
- **游戏会话：** 保持显示器唤醒、终止卡住的游戏、清理进程、Steam 重连及 Discord 活动；Dormison 还可转发游戏自己的 Discord 状态。
- **外部游戏：** Finder 启动 `.exe`、缩略图、安装程序跟踪、快速启动、非 Steam 游戏库条目、Steam Input、覆盖层及运行报告；提示内核驱动依赖。
- **配置：** 可搜索的引擎和单游戏图形、输入、性能、DLL 及环境变量设置；可撤销的已知修复、依赖修复和 Proton 风格启动选项导入。
- **存储：** 游戏及分类大小、缓存和引擎清理、外部游戏库，以及跨容器共享安装文件并保留独立存档。
- **恢复：** 客户端看护、崩溃循环检测、丢失唤醒修复、孤立进程清理、辅助程序和容器修复、缓存重置及故障指南。Sevoflurane 崩溃后游戏继续运行，重开可重新连接。
- **本 fork 的隐私设置：** 移除应用自动更新、统计与使用数据上传、崩溃及游戏报告上传、macOS 通知模块；保留兼容性数据库和手动引擎、渲染器下载。
- **诊断：** 运行记录、帧时间、日志、崩溃报告、单游戏记录等级、本地诊断 ZIP 导出、进程监视器、CPU 限制建议及 `sevo perf compare`。
- **自动化：** CLI/MCP、手动引擎切换；Steam 自身更新和云存档同步正常保留。顶部菜单从本地日志显示云存档上传状态。
- [详细参考](REFERENCE.zh-CN.md)。标有 Dormison 的功能需要该引擎。

</details>

## 其他信息

- Apple 芯片 · macOS 26+ · Rosetta。设置向导提供 Dormison 或 CrossOver；DirectX 12 需要 D3DMetal。
- [游戏兼容性](https://kagerou.glass/sevoflurane/games/?lang=zh-CN) · [渲染器、限制及命令行参考](REFERENCE.zh-CN.md)。
- **设置 → 关于 → 保存诊断…**收集报告。[贡献指南](CONTRIBUTING.md)。
- [English](README.md) · [简体中文](README.zh-CN.md)。
