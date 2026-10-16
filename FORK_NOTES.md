# 本地修复分支

基于官方 `v1.6.0`（`bddae888ec297db7b9870f6f6152e4d58454bbf4`），用于保留现有 CrossOver 引擎和 Steam 容器。

## 修改

- 在应用 Info.plist 中添加麦克风用途说明，为应用与负责启动 Wine 的后台 helper 添加 `com.apple.security.device.audio-input`。保留 hardened runtime；仍由 macOS 弹窗征求用户授权。
- 覆盖层内好友、聊天、浏览器等使用 popup chrome 的窗口保留 `.nonactivatingPanel`，同时恢复原生标题栏、关闭按钮和调整大小能力。Steam 页面的按钮按原设计隐藏，由原生控件接管。
- 页面报告的拖动区域通过 `performDrag(with:)` 显式进入 AppKit 拖动；正文点击及覆盖整个游戏的根覆盖层不触发窗口拖动。
- 覆盖层打开聊天时，Steam 可能同时创建桌面与游戏内两份窗口；此时只显示游戏内实例，退出覆盖层时仍随窗口组清理桌面副本。桌面模式下的聊天显示不变。
- 添加 AppKit 回归用例，覆盖关闭按钮、非激活行为、拖动区域与根覆盖层保护。

## 构建

遵循上游 CONTRIBUTING.md。使用 Xcode 26+、macOS 26+ 和 Apple Silicon。

```sh
SEVO_EMBED_ENGINE=0 xcodebuild -project Sevoflurane.xcodeproj \
  -scheme Sevoflurane -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= \
  ENABLE_CODE_COVERAGE=NO CLANG_COVERAGE_MAPPING=NO build
```

这是本地签名构建，不是上游的 Developer ID / 公证发行版。安装时需先退出游戏及客户端，再替换应用并重建 helper 注册。系统可能要求重新确认后台运行、输入监控或通知权限；本分支不会写入 TCC 数据库或代替用户授权。上游基于开发者签名的可选统计认证不适用于本地签名版本。

从上游签名版本切换到本地签名版本后，输入监控列表可能显示已开启，但系统仍保存旧签名要求。本次遇到 `Failed to match existing code requirement`，仅关闭再开启开关未能更新记录。通过系统设置移除旧的 `SevofluraneDaemon` 条目，再添加当前应用内 `Contents/Library/LaunchAgents/SevofluraneDaemon` 并授权，重启客户端后，Wine 日志确认 `physical wheel reader opened (nonexclusive)`。该操作需用户确认系统输入监控权限。

输入、画面补丁仍由原有自定义运行时提供，本分支不修改 Wine、Mos 或游戏文件。

## 验证记录

本地构建通过，覆盖层相关 Swift Testing 共 12 项通过，包括原生关闭按钮、非激活面板、标题条显式拖动、覆盖层焦点范围，以及聊天双实例的显示和重排序。上游 Release 测试目标中的其他文件依赖 DEBUG 专用类型，本次仅编译 `OverlayPopupChromeTests.swift` 与 `SteamOverlayTests.swift` 中选定的三组用例。

在没有开发者签名证书的机器上，本地 XCTest 宿主临时使用 `ENABLE_HARDENED_RUNTIME=NO` 以加载 ad-hoc 测试包；这仅用于测试。安装版本重新以无测试插桩的 Release 构建，并保留 hardened runtime，只增加麦克风录音 capability。游戏内体验已确认麦克风授权弹窗、标题栏拖动和关闭按钮正常；聊天双窗口修复也已确认只显示一个窗口。
