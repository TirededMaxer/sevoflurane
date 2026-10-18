# TirededMaxer fork — 1.7.0-fork.5

保留上游署名和许可证，以及本机现有 CrossOver 引擎、Steam 容器、游戏、存档与运行时补丁。

## 当前实现

- Steam 页面沿用其原有 HTML、CSS、脚本、字体、布局、标题按钮和动画，由 WebKit/AppKit 承载桌面窗口。macOS 顶部只保留 Sevoflurane 应用菜单，隐藏的快捷键命令继续支持文本编辑。大屏幕模式读取 Steam 的 FullScreen 创建标记，不重写 Steam 的模式切换。
- 嵌入网页的 alert/confirm 通过原版 BrowserView 事件及回答接口交回 Steam 原有弹窗组件。
- 游戏叠加层保留 Steam 原始渲染、输入和生命周期；失败的截图/Metal 合成、输入转发和注入方案已从当前源码删除，可从 Git 历史追溯。
- 桌面通知使用 Steam 原有 notificationtoasts 网页与动画，由不抢焦点的窗口承载并显示在全屏游戏之上。macOS 通知中心模块已移除。
- 首次点击获取焦点；主窗口空白标题区支持拖动、双击缩放；登录与主窗口进入普通桌面空间；窗口首次居中，此后记住位置和大小。菜单保留原版悬浮规则并清除离开后的残留状态。
- 游戏名称下方复用原有状态行显示云存档上传中/失败；上传完成即恢复原状。只读取本地 cloud_log.txt，上传中阻止启动该游戏。
- 应用自动更新、统计、崩溃/游戏报告和其他数据上传模块已删除。保留只读兼容性与修复信息、手动引擎/渲染器/着色器下载，以及 Steam 自身更新、联网、云存档和 Discord 功能。
- 米哈游入口、管理实现、Sophon 依赖和专用启动辅助已删除。原作者主页菜单链接及底栏版本文字已移除；版本在“关于”中查看。
- [CrossOver 驱动补丁](Tools/crossover-ui/README.md) 限定 Steam 基础进程，并要求 SEVO_OWNER_PID 与 CX_HIDE_STEAM_DOCK=1。隐藏窗口、Dock 身份和托盘，不为隐藏图标强杀进程。游戏和安装程序窗口保留原有处理。

## 尚未完成的边界

旧式 Win32 非网页窗口仍缺少忠实呈现；被否定的 AppKit 控件重建原型及其 helper 已删除。后续实现由 Sevoflurane 承载、按屏幕原生分辨率绘制文字和原始布局，不直接放出 CrossOver/Wine 窗口，也不使用 macOS 标准弹窗样式。根页面底层 JavaScript 对话框的统一原版呈现、游戏内 WebKit 承载及完整真实组件验收尚未完成。不能宣称整个 Steam 生命周期已实现完全一致的视觉替换。

后续叠加层方向是验证游戏进程内的真实 WebKit 视图与同一游戏窗口共存，沿用原网页及 Steam 接口；跨进程承载、焦点和全屏尚待证明，不重新启用截图合成方案。

构建 34 的拖动、双击最大化/还原、最小化和中英文输入已由用户实测通过。大屏幕模式修复、当前警告、通知与叠加层的验收必须分别记录，不以夹具检查替代实机结果。

## 工作副本、构建与发布

唯一工作副本为 `/Users/mac/Desktop/Projects/Sevoflurane`。先在本地修改源码、审查，再同步 GitHub 的 main 与工作分支。所有编译、测试、签名和打包交给 `release.yml` 的全新 Apple Silicon runner，按 Package.resolved 下载依赖，不恢复构建缓存。

候选通过云构建后临时下载，核验 SHA-256、签名及版本，正常退出后替换本地应用；不替换容器和引擎。真实组件验收通过后，工作流创建草稿、核验远端资产及回下载哈希，再发布并删除旧 Release。仅保留一个最新 Release；保留 Git 标签和提交历史。临时包安装后删除。

正式包使用逐层 ad-hoc 签名及 hardened runtime，保留麦克风 capability，不含测试包和商业引擎。云端测试宿主仅为加载测试包而关闭 hardened runtime。此 fork 不修改 macOS TCC。

## 原版 painter 实验（构建 45）

`Tools/overlay-painter` 提供显式安装/恢复的 CEF 实验工具，默认不启用。固定本机 CEF 的 SHA、222 项导出及 API 哈希；透传定制十参数 CPU 绘制回调，保留滚动位置和页面缩放。可观测原 CPU/GPU 路径，显式请求时将一张 WebKit 测试卡交给原 CPU painter。原合成、快捷键、焦点和输入不重建。单帧 snapshot 只用于验证消费者边界，未实现持续 WebKit 输出、GPU 资源互操作或完整输入接入，不等于完整游戏内 WebKit 方案。此候选须实机验证，不发布正式 Release。
