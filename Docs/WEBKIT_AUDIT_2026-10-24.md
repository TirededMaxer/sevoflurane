# WebKit 入口补查：构建 66

## 已定位并修改

- 原标题区拖动范围只按 CSS 类名猜测可点击元素，未覆盖聊天标签及标题的同级控件。现同时识别 HTML 交互语义、原 no-drag 标记和实际 React 点击/指针处理函数。
- 透明 AppKit 标题栏仍有原生命中区域。弹出窗口改为把原生标准按钮放入内容层，隐藏旧标题栏子树，使按钮之外的点击回到网页；桌面原工具栏与大屏幕模式不走此路径。
- 原 Windows 焦点高亮与原生窗框叠加。去掉重复 title-area-highlight/singleWindowFocusBar，并关闭原生标题栏分隔线。搜索标签保留原动画和状态，仅限制单行裁剪并在搜索状态隐藏。
- 桌面旧 CSS 使用全局 :has(TitleBar) 隐藏父节点，可能误伤同页模态窗口。现只标记桌面首个非模态标题行，不对所有后代标题的父节点执行隐藏。
- 两类 WKUIDelegate 都缺少 runOpenPanelWithParameters。Apple SDK 明确说明：macOS 未实现等同用户取消。新增公共文件选择器，供顶层窗口和嵌入 BrowserView 复用，支持多选、目录和取消。
- WebChat.OpenURLInClient 原样转发会导航到隐藏 CEF 根页面。桌面链接现调用可见页面的原 NavigateToSteamWeb；明确的外部链接交给默认浏览器，游戏 PID 目标继续转发 Windows。主窗口关闭后的链接先等待窗口重建及初始路由完成，防止目标被首页覆盖。
- Browser.Paste/StartDownload/SetPendingFilePath 曾发给隐藏页面。现交回调用窗口的 WebKit 与 AppKit；已有文件仍通过原 Steam 生成的特殊 input 获取，不复刻上传业务。
- BrowserView.Paste/FindInPage/StopFindInPage/SetSteamURLCallback 是空函数。现接入原生粘贴、WebKit 查找及原 Steam 回调。原页内查找栏沿用原组件，Cmd-F 通知其已有入口。显示计数取当前主文档的可见文本；跨源 iframe 的计数不在此 DOM 统计中。
- 嵌入网页的新标签和关闭请求原来直接跳到外部浏览器或无人接收。现发出原 new-tab / before-close 事件，由 Steam 原有处理函数决定窗口生命周期。
- 网页下载导航和不能直接显示的响应没有 WKDownload 接收方。新增共享下载委托，由 WebKit 处理 Cookie/传输，原生保存面板选择位置；显式保存截图使用相同入口。
- ClearAllBrowsingData 仅清原客户端数据，现同时清除 WebKit 数据。
- 更新后的 Steam 已移除部分游戏浏览器绑定，桌面脚本仍无条件调用并报错。仅对既定的四个游戏浏览器入口返回无浏览器/空订阅，不创建游戏 WebKit 窗口。保持其余 SteamClient 命名空间形态。
- 对早期脚本里的 g_PopupManager 裸引用改为 window.g_PopupManager，避免记录中出现的 ReferenceError。

## 保留与边界

Steam 的数据、好友、云同步、聊天、上传以及游戏业务继续使用原实现。Windows 游戏叠加层及旧式 Win32 桥不变；只处理本轮网页呈现和平台入口。BrowserView 的玻璃合成、VR 键盘和 Steam Input 等纯 CEF/平台入口继续不在 WebKit 承载；未声称全部 Steam API 都已移植。

本机在系统设置移除 SevofluraneDaemon 的旧输入监控条目，用户完成系统认证后确认列表中已消失。COEditor Wheel 及其他授权保留。未移除负责 Steam 启停的 helper，源码中没有新增输入监控请求。

## 验证

本机进行脚本/配置语法和差异检查，不运行本地编译和测试套件。GitHub 云端负责 Release 编译、签名、CLI/MCP 与 DMG 校验。真实好友聊天、文件选择、下载、商店和社区页面的用户验收需与构建结果区分；不发送真实消息、不购买、不自动启动 CS2。

## 构建 67 回归修正

构建 66 把系统拥有的标准按钮移入正文并隐藏标题栏父层，用户实测红绿灯消失。这项修改已替换为 AppKit 工厂创建的独立标准按钮，只隐藏原标题栏本身。嵌入标题栏窗口关闭 WebKit 自动原生标题栏 inset，取消正文顶部的第二层留白；尺寸 API 同步网页视口。好友头像预留完整的按钮高度，避免重新覆盖。桌面工具栏、大屏幕模式及无框菜单/通知不应用这项原生留白修改。

参考 WebKit 的 `_setAutomaticallyAdjustsContentInsets:`、`obscuredContentInsets` 和 Apple 的 `NSWindow.standardWindowButton(_:for:)`。定向检查覆盖原生按钮的可见性、命中与三个原生动作，窗口改变大小/外观后的按钮状态，以及网页顶边实际像素；不发送消息，不启动游戏。
