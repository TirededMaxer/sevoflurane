# TirededMaxer fork — 1.7.0-fork.3

基于上游 Sevoflurane v1.6.0，保留原作者署名、许可证及本机现有 CrossOver 引擎、Steam 容器和输入/画面补丁。

## 本版范围

- 完全移除米哈游模块：设置和搜索入口、安装/更新/校验/修复、CLI/MCP 工具、Sophon 编解码依赖、原神帧率解锁及专用伴随环境启动辅助。保留用户已有游戏文件、容器和通用日志/错误检测。
- 单一 Git 工作副本迁至桌面 Projects/Sevoflurane，先在本地修改源码，再同步 GitHub；全部测试和构建由 GitHub 云端完成，本地只保留源码及相关文档。Release 只保留核验后的最新构建。

- 删除应用自动更新模块与 Digoxin、TiptoeGitHub/AppUpdater 依赖，不再检查、下载或替换 Sevoflurane 自身；也不在启动时自动升级内置引擎。
- 删除使用统计、运行统计、游戏报告、崩溃报告上传、共享数据身份和对应设置、引导、CLI 入口。诊断 ZIP 仅在本地保存；GitHub 问题链接不携带诊断查询参数。
- 按用户确认的范围，保留只读兼容性数据库、在线修复列表、手动引擎/渲染器/着色器下载，以及 Steam 自身更新、联网、云存档和 Discord 功能。
- 完全删除 macOS 通知中心模块、权限请求、通知代理和通知操作。Steam 使用自己绘制的右下角提示页面及动画，在不抢键盘焦点的 AppKit panel 中显示。好友上线、玩游戏及聊天提示遵守 Steam 原有开关和声音设置。
- 桌面标题条空白处通过 AppKit 显式拖动、双击缩放；工具栏抢先命中时由同一窗口的本地事件路由接管。原生交通灯、账户和其他标题条按钮保留交互。
- 云存档上传中和失败显示在顶部菜单对应游戏的名称下方，复用已有状态行；上传中禁用该游戏条目和“使用其他渲染器运行”的启动路径。上传完成后立即恢复原有状态行或留空，不常驻显示“已上传”。数据只读取 Steam 本地 cloud_log.txt；单个文件上传成功不会被当成整个同步完成。
- 独立 Steam 窗口和游戏叠加层子窗口首次打开时居中；之后记住大小和位置，关闭重开、重启应用后恢复，桌面与叠加层分别保存。Steam 初始化的坐标与尺寸请求不会覆盖保存的窗口。Sevoflurane 自身设置等窗口使用 AppKit 位置记忆。根覆盖层对齐游戏画面，附属菜单和右下角提示保持各自锚点。
- 修复 ID 等非焦点下拉菜单缺少悬浮高亮的问题：将光标路径映射到 Steam 原有的 `:hover` 样式，包含禁用态及嵌套媒体规则；菜单保持不抢焦点，离开、隐藏或取得键盘焦点时清除接管的视觉状态。原因与 [WebKit 非 key 窗口冻结 hover 的行为](https://github.com/WebKit/WebKit/blob/main/Source/WebCore/page/EventHandler.cpp)一致。
- 底栏不显示版本号，避免挤压渲染器名称；版本可在“关于”和“更多操作”中查看。
- 移除为隐藏 Dock 图标而重启 Steam、为隐藏托盘而终止 explorer 的路径。运行时驱动负责隐藏身份、窗口和状态栏图标。真正崩溃恢复、用户要求的重启和退出仍保留正常生命周期管理。

## 原版 UI 的覆盖边界

现有匹配 CrossOver 26.3 的 [驱动补丁](Tools/crossover-ui/README.md) 在显示入口拦截 Steam 基础进程窗口、托盘和抢焦点请求；需要 SEVO_OWNER_PID 和 CX_HIDE_STEAM_DOCK=1。CEF 的登录、桌面、聊天、菜单和提示由 WebKit 桥接接管。补丁公开源码，不分发商业运行时。

本版加入 [原生错误转接 helper](Tools/steam-ui/README.md)，在同一容器内读取 Steam/Steam error-reporter 的标准 Win32 对话框文字、按钮，再由 Sevoflurane 的 NSAlert 显示并将选择传回原始窗口。扫描与回答只经过后台 helper 的认证接口，不另起容器所有者、不终止 Steam。

标准 #32770 对话框，以及暴露子控件文本的 VGUI/SDL 对话框可以转接。没有可读子控件的自绘窗口不能保证完整重建；驱动仍会抑制其原版显示并留下本地日志。游戏自身和安装程序窗口保留交互。因此不能把当前实现描述为任意 Windows 界面和任意异常的 100% 原生替换。之前偶发乱码错误背后的网络或启动失败原因仍未复现确认。

## 构建与签名

通过 GitHub Actions 的 `Cloud build and release` 手动工作流构建：

```sh
git push origin HEAD:main
gh workflow run release.yml --repo TirededMaxer/sevoflurane --ref main -f publish=true
```

工作流使用全新 `xcode-27` Apple Silicon runner（工程格式为 Xcode 27，最低运行系统仍是 macOS 26），按 Package.resolved 获取依赖；不恢复编译缓存、不读取本机文件。源码内 Tools/ci 保存测试、构建、打包和发布脚本，共享 scheme 显式包含完整测试目标。测试宿主关闭 hardened runtime 以加载 ad-hoc 测试包，正式构建保持开启。云端保存日志、测试摘要及构建资产 7 天；Release DMG 和 SHA256SUMS.txt 回下载校验后发布，再删除旧 Release。本地仅临时下载已核验的云端安装包，安装后清理。

原生对话框 helper 的源码、导入定义及构建方法见 Tools/steam-ui。

发行包在云端逐层 ad-hoc 签名，保留 hardened runtime 和既有麦克风 capability，无测试包、无内嵌商业引擎。这不是 Developer ID 公证版本。现有容器和运行时不随应用替换。输入监控等系统授权仍由 macOS 管理；若更换 helper 签名导致旧授权失效，需在系统设置重新授权。本 fork 不修改 TCC。

## 验证

- 完整 Debug 测试和正式 Release 构建由云端工作流执行，结果见 Release 中链接的 Actions 记录；测试宿主临时关闭 hardened runtime 仅用于加载 ad-hoc 测试包。正式 Release 保持 hardened runtime、关闭测试插桩。覆盖首次居中、尺寸和位置持久化、跨实例恢复、真实 WebKit 菜单高亮与离开清理，以及云状态观察订阅；底栏布局通过正式构建检查。
- 云日志测试覆盖最终确认、单文件成功、并行游戏、失败重试、分段读取及日志轮换；窗口测试覆盖原生拖动、双击、工具栏事件范围、提示位置和非激活行为。
- 实际登录达到 healthy；Steam 自带好友游戏/上线测试创建原版 notificationtoasts 页面，窗口位于屏幕右下方。上线提示测试仅临时覆盖测试目标的显示条件，不持久修改 Steam 设置。
- 本地中文 Win32 错误测试由 NSAlert 显示完整文字和“确定/取消”；点击确定后原窗口收到 response:1 并正常退出，Steam 保持 healthy。
- 本机先前驱动范围检查和 31 项 AppKit 窗口/托盘断言通过。当前沿用同一驱动，不覆盖其输入、显示或其他 ABI 组件。
