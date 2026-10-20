# TirededMaxer fork — 1.7.0-fork.9

保留上游署名和许可证，以及本机现有 CrossOver 引擎、Steam 容器、游戏、存档与运行时补丁。

## 当前实现

- Steam 页面沿用其原有 HTML、CSS、脚本、字体和内容布局，由 WebKit/AppKit 承载。带窗口控制的界面使用 AppKit 原生窗框与红黄绿按钮，网页重复按钮隐藏。Steam、View、Friends、Games、Help 五项菜单映射回 macOS 菜单栏，选择仍交给原网页命令，Edit 与 Window 提供系统快捷键。登录成功后停留后台，仅明确请求打开 Steam 才显示主界面。大屏幕模式读取 Steam 的 FullScreen 创建标记，不重写 Steam 的模式切换。
- 嵌入网页的 alert/confirm 通过原版 BrowserView 事件及回答接口交回 Steam 原有弹窗组件。
- 游戏叠加层的画面、子窗口、输入、Shift+Tab、焦点、光标、动画及位置全部由 Windows Steam 原版处理。桌面 WebKit 不创建游戏浏览器；此前的 WebKit 叠加层实验及其绘制、输入适配已移除。
- 桌面通知仍使用 Steam 原有 notificationtoasts 页面及 NotificationStore。构建 64 阻止 WebKit 重复提交好友通知；构建 65 在原始出队、队列更新入口旁同步已消费 ID，按来源、类型、通知 ID 和服务器项目 ID 精确移除另一端待显示副本，并通过原队列更新入口通知页面，不清空整条队列、不改未读或通知中心记录、不包装 PlayNotificationSound。原客户端页面生命周期内保留 ID 记录，页面重载时交接；Steam 新会话使用新的标识。游戏专属队列不参与同步，提示位置遵循 Steam 原设置。

网页主窗口、菜单、好友聊天、网页模态警告及通知均加载 Steam 自带文档；BrowserView 的 alert/confirm 经原事件及 DialogResponse 回答。平台适配负责窗口、输入、像素传递及 WebKit/CEF 的 API 差异。上游的可选兼容性标记、原生 macOS 游戏入口、用户 CSS 和隐私遮罩是独立附加功能，不能据此声称整个应用没有自定义界面。已停用的安装拦截及原生兼容性警告已删除。

构建 34 的拖动、双击最大化/还原、最小化和中英文输入，构建 30 的普通桌面空间，以及既有清晰叠加层和全屏游戏上方通知，已有用户实测。构建 47 的探针和无探针对照均出现隐形叠加层；恢复 CEF 原版浏览器回调后用户确认显示，并明确结束 WebKit 叠加层实验。构建 48 的自动浏览器所有权已由实际游戏和用户确认：原版叠加层可见，普通通知仅在右下角出现一次，没有左下角重放。用户随后发现全屏 CS2 提示仍错误预留 Dock 高度；构建 49 根据原版模块 25625/15148 修正游戏画布定位；完整 3024×1964 像素绑定、单次原队列消费及游戏内贴底位置均已实测，用户确认“可以了”。标准旧式 Steam 警告尚未触发真实窗口验收。

## 工作副本、构建与发布

唯一工作副本为 `/Users/mac/Desktop/Projects/Sevoflurane`。先在本地修改源码、审查，再同步 GitHub 的 main 与工作分支。所有编译、测试、签名和打包交给 `release.yml` 的全新 Apple Silicon runner，按 Package.resolved 下载依赖，不恢复构建缓存。

候选通过云构建后临时下载，核验 SHA-256、签名及版本，正常退出后替换本地应用；不替换容器和引擎。真实组件验收通过后，工作流创建草稿、核验远端资产及回下载哈希，再发布并删除旧 Release。仅保留一个最新 Release；保留 Git 标签和提交历史。临时包安装后删除。

正式包使用逐层 ad-hoc 签名及 hardened runtime，保留麦克风 capability，不含测试包和商业引擎。云端测试宿主仅为加载测试包而关闭 hardened runtime。此 fork 不修改 macOS TCC。
