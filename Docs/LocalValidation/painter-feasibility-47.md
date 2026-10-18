# 原版 Steam painter 实施与验证（构建 47）

代码版本：`c56e5e482f7135c0705746f5d9f9b545c2b6ee28`。候选版本：1.7.0-fork.5，构建 47。原生 Steam 网页、合成消费者及输入路径继续保留；不是完成的 WebKit 叠加层。

- 构建 46 的磁盘代理被 Steam 启动流程恢复，未接到回调；已经删除该路线及其安装/导出代码。
- 构建 47 采用正常启动后接入，只作用于完整路径匹配的 x64 steamwebhelper。两次正常启动各有四个 helper 成功加载探针并各接上一个实际存在的浏览器创建 IAT 导入；CEF API/结构检查未拒绝。
- 两次观察中的新建浏览器及绘制回调计数均为零。第二次调用原好友窗口流程时，当前 SharedJSContext 返回 `friends unavailable`，没有生成好友窗口，不能作为回调成功证据。没有调用其他未知界面接口。
- 原生 WebKit 测试卡及 BGRA 格式只在云端夹具验证通过，尚未交给实际 Steam 叠加层消费者。未启动 CS2、未请求替换帧。
- Steam 已正常停止，临时探针文件已移除；原 libcef.dll、winemac.so 前后 SHA 一致。候选默认不启用探针，临时 DMG 下载已清理。
- 云端 1199 项应用测试、6 项会话测试、原生 WebKit 帧校验及签名通过。该候选未发布正式 Release。

因此，当前已证实的是进程接入和实际导入位置可用，尚未证实完整画面替换可行。下次游戏测试应在创建游戏叠加层之前接入，先记录新建浏览器和实际 CPU/GPU 路径。只有真实 CPU overlay 回调出现，才允许单帧试验；GPU-only 结果需另外研究资源握手，不能强制改为 CPU。随后再验证原消费者交付、完整输入、生命周期和持续性能。

精简证据：`painter-cloud-47.json`、`painter-install-47.json`、`painter-runtime-47.json`。启动失败路线见 `painter-startup-46.json`。
