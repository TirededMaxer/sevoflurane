# 桌面与游戏聊天同步：构建 68

## 证据与原因

原版 Steam 多个窗口共用其聊天模型；Sevoflurane 的 WebKit 根页面另建一份模型。只转发 SteamClient 调用及各自连接的回调，没有转发某一根页面在发送确认后产生的本地状态更新。只读运行检查确认两个页面已登录、各自持有不同 SharedConnection 句柄及不同的已载入聊天集合；检查没有输出消息正文，没有发送消息。

核对当前 Steam `sp.js` 的模块 47467（聊天历史/合并）、76296（私聊）、`library.js` 模块 91470（SharedConnection 传输）。REA 整包 sp.js 分析因堆内存限制未完成；随后仅提取这三个模块并记录原文件 SHA-256 和字节区间，静态分析三文件成功，不能据此声称真实消息行为已验收。证据 parent：ev_20779b970348acc54d405f41ecee5b0cf29e9fee0a1eb79d03d9fd0106ec97ab。

## 实现

两端共享同一适配工厂，观察原 ServiceTransport 成功返回和原聊天通知分发。转发内容只有账号、会话标识和受影响时间戳。发送失败、异常和正在输入通知不触发同步，返回值/原 Promise 保持不变。

接收端调用原 `LoadFriendMessageSessions`、`InternalLoadChatLogs(true)`、`GetMessagesFromTimeRange`/`MergeChatHistoryChunk`、`UpdateLastAckTimeFromServer`。表情或删除更新读取相应时间段，避免只刷新新消息尾部而漏掉旧行。自己的最新消息使用原本的本地回声更新辅助方法刷新预览；其他发送者的历史不再进入通知路径。群聊数据仍由 Steam 按原规则恢复。

同步事件按账号隔离，自己的事件不回灌。突发事件合并保留历史尾部及旧消息时间段；断线恢复重新读取当前会话数据；只为已载入的聊天读取历史，新聊天依然由 Steam 打开时加载。适配重复安装不堆叠方法包装，清理时恢复原方法。

## 检查边界

纯数据定向检查覆盖成功/失败发送、私聊/群聊、已读、表情/删除时间段、突发合并、断线补齐、未打开会话、账号切换和清理。GitHub 云端负责执行检查及编译、签名、打包；真实 Steam 服务器和游戏内外消息发送验收需另行确认。不自动启动 CS2，不发送真实聊天消息。

## 原版模块来源

```json
[
  {
    "file": "sp.js",
    "module": "47467",
    "source_sha256": "692083495994d2b2cf686effd89c11fa987aefa45787cbfa212627c37eda9c7a",
    "start_byte": 679210,
    "end_byte": 695813,
    "extracted": "sp-47467.js"
  },
  {
    "file": "sp.js",
    "module": "76296",
    "source_sha256": "692083495994d2b2cf686effd89c11fa987aefa45787cbfa212627c37eda9c7a",
    "start_byte": 917565,
    "end_byte": 937437,
    "extracted": "sp-76296.js"
  },
  {
    "file": "library.js",
    "module": "91470",
    "source_sha256": "ef4d81fa36acadf052cca6e2645db838c7c3ffd445f056fa9aee8b98c1d31309",
    "start_byte": 396647,
    "end_byte": 420800,
    "extracted": "library-91470.js"
  }
]
```

本机仅做可清理的接口诊断：在现有 SharedJSContext 安装同一工厂、读取原历史并等待空闲，得到 installed=true、emitted=0、reconciled=1、failed=0；随后恢复原方法、移除诊断属性。没有发送真实聊天消息，没有启动游戏。这确认原接口可接入，不等于发送场景验收。

补查群聊未读元数据属于 `GetMyChatRoomGroups`，不在私聊会话响应中。群聊事件及已有群聊的断线补齐同步调用原 `LoadMyChatRooms`，避免只补历史而遗漏群聊未读/成员状态；对应新增定向检查。
