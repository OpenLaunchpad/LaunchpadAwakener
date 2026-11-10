# Draft - 文本输入通道改用系统的 Swift XPC 接口

- **状态**: In Progress
- **创建日期**: 2026-11-10
- **最后更新**: 2026-11-10
- **实现分支**: `feature/text-input-swift-xpc`

## 摘要

payload 与文本输入辅助进程之间的通道（[0001](0001-input-method-helper.md) 引入）是项目里唯一手写 libxpc 的地方：`xpc_dictionary_set_*` 拼字典，键名是字符串常量，两边各自解析，类型对不上只能在运行时发现。这次把它换成系统 XPC 框架的 Swift 接口——客户端用 `XPCSession`，服务端用 `XPCListener`，消息是两边共用的 `Codable` 类型——删掉 `TextInputService.swift` 与 `TextInputHelperClient.swift` 里全部 `xpc_*` 调用。

起初打算用依赖图里已有的 SwiftyXPC，但它与手写 libxpc 有两处语义不同（见「备选：SwiftyXPC」），系统接口没有这两个问题，也不需要新增依赖。

## 方案

### 为什么系统接口够用

逐条对照这条通道依赖的行为（依据 macOS 27.2 SDK 的 `XPC.swiftinterface` 与 `xpc/session.h`、`xpc/listener.h`）：

| 需要的行为 | 系统接口 |
|---|---|
| 按到达顺序处理 | 消息按 FIFO 投递（`session.h`），处理者是同步闭包，在 session 的目标队列上逐条调用。目标队列设成主队列，与现在一样 |
| 单向消息 | `send(_:)` 不要回复，对方处理者返回 `nil` 即可，没有多余的消息 |
| 带回复的消息 | `send(_:replyHandler:)`，回复在目标队列上交回，与之后到达的消息保持先后顺序 |
| 消息类型 | `send<Message: Encodable>`；收到的消息用 `XPCReceivedMessage.decode(as:)` 解码 |
| 只认 Apple 签的 Dock | `XPCSession.setPeerRequirement(_:)`（macOS 26）：对方不满足要求时 session 被取消，取消回调里拿到原因，所以能照旧记下拒绝日志 |

### 消息类型

放在 `LaunchpadAwakenerShared`，替换 `TextInputServiceIdentity` 里的 `MessageKey` 与 `Request` 两组字符串常量。它们只是 `Codable` 结构，模块仍然不依赖任何东西。

- payload → 辅助进程：一个 `Codable` 枚举，四种情况 `begin`、`setString`、`setFocus`、`end`，各带原来那些字段。辅助进程只有一个处理者，按情况分派。
- 回复：`begin` 回上下文编号、进程号、窗口编号；`end` 回最终文字（可为空）。
- 辅助进程 → payload：`changed`，带文字、是否在组字、编辑是否结束。

### 两端

- **辅助进程**：连接管理放在不碰 AppKit 的 `TextInputPeerListener`，`TextInputService` 只管托管的文本框。它用 `XPCListener(service:targetQueue: .main, incomingSessionHandler:)` 监听原来的 Mach 服务名，每个接进来的 session 在激活前设好签名要求与主队列，交给一个 `XPCPeerHandler`。测试里用同一个类型匿名监听、不设签名要求（`PeerPolicy.anyPeer`）。「先发来一条合法消息才接替旧连接」不变：处理者收到的消息来自另一个 session 时，取消旧的、换成新的。当前 Dock 的 session 取消时结束托管；不是当前 Dock 的 session 因签名不符被取消时记一条拒绝日志。
- **payload**：`XPCSession(machService:targetQueue: .main, incomingMessageHandler:cancellationHandler:)`；测试里改连匿名监听的 endpoint（`TextInputHelperClient.Destination`）。回调在主队列上直接进主 actor，万一不在主线程就改为跳一次，绝不在 Dock 里断言崩溃。session 不像连接那样能在对方退出后继续用：辅助进程一退出 session 就失效（`session.h`：「system will make no attempt to reestablish the connection」），所以取消回调里丢掉它、通知界面辅助进程走了，下一次 `begin` 建新 session，launchd 照旧按需拉起辅助进程。`TextInputHelperClient` 对界面层的接口（`begin(…completion:)`、`setString`、`setFocus`、`end(completion:)`、`post`）不变，`SpringboardRemoteTextField` 不用改。

### 没有询问就采用的假设

- **签名要求换个写法。** 原来是代码签名要求字符串 `identifier "com.apple.dock" and anchor apple`。Swift 接口不收这种字符串，改用 `.isPlatformCode(andMatchesSigningIdentifier: "com.apple.dock")`，即「系统自带的二进制，且签名标识是 Dock」。Dock 两条都满足。注入过的 Dock 能不能通过，要在两台测试机上确认。
- **只在 session 上设签名要求，监听器上不设。** 监听器上的要求不满足时，请求直接丢掉、不留痕迹（`listener.h`），也不会传给 session（「Peer sessions created from the listener do not inherit the requirement」）。只设在 session 上，不满足的 session 收到第一条消息就被取消，安全性一样，还能留日志。
- **删掉按进程路径认 Dock 的检查。** session 拿不到对方的进程号；签名要求本来就逐条把关，路径检查原本只是「先看一眼」。日志里也不再有 Dock 的进程号。
- **签名要求要 macOS 26**（`XPCPeerRequirement` 与 `setPeerRequirement` 从 26 开始才有），包的最低系统是 macOS 15。只在设要求的那一处判断系统版本：低于 26 时监听器拒绝所有连接。payload 与辅助进程本来就只在 26 与 27 上运行。其余接口（`XPCSession`、`XPCListener`、匿名监听的 endpoint）macOS 15 就有。
- **部署后要手动换掉旧辅助进程。** 还在运行的旧辅助进程不认新格式，收不到能让它自行退出的 `begin`。这次部署后，每台测试机上要 `pkill -f LaunchpadAwakenerTextInput` 一次；项目还没对外发布，没有用户受影响。以后再改消息格式就不需要了：辅助进程解码失败时，先检查自己的可执行文件有没有被换掉，换了就退出。
- 不改 daemon，`daemonVersion` 不递增。payload 改了，部署后要重启 Dock。

### 测试与验证

- 新增 `LaunchpadAwakenerTextInputCoreTests`，在测试进程里用匿名监听（`XPCListener(targetQueue:incomingSessionHandler:)` 加 `XPCSession(endpoint:)`）跑真实的 XPC。两个测试 target 共用的 XPC 测试辅助放进 `TestingSupport`。
  - 每种请求和回复经 XPC 往返后不变。
  - 连发几百条消息，到达顺序与发送顺序一致。
  - 测试进程不是 Dock，所以用辅助进程那份签名要求的 session 会被取消；取消时能拿到原因。
  - 换 Dock 的规则：新 session 发来合法消息后接替旧的，当前 session 取消时托管结束。
- `LaunchpadAwakenerPayloadCoreTests` 里用一个替身辅助进程测 `TextInputHelperClient`：`begin` 送出的配置与拿回的托管、托管不了与拒绝 Dock 时退回本地编辑、之后的请求按顺序到达、`end` 拿回最终文字、回报按顺序到达、辅助进程退出后只报一次并在下一次 `begin` 重新连上。
- 开发机上用 `RunScript.sh` 构建，跑全部单元测试。
- 部署到测试 MacBook（27.2）和 macOS 26 的虚拟机，看日志确认 Dock 通过了签名要求、连上辅助进程、`begin` 拿到托管。用输入法实际打字属于交互验证，用户提出才做。

### 落地步骤

1. ✅ **消息类型**：在 `LaunchpadAwakenerShared` 加 `Codable` 消息与回复类型，新建 `LaunchpadAwakenerTextInputCoreTests`，用匿名监听测往返与顺序。旧的字符串常量暂时保留，两端照旧能编。
2. ✅ **辅助进程**：`TextInputService` 改用 `XPCListener` 与每个 session 上的签名要求，接替 Dock 的规则抽成能单测的类型并补测试；签名要求拒绝测试进程的测试也在这一步。
3. ✅ **payload**：`TextInputHelperClient` 改用 `XPCSession`，删掉 `MessageKey` 与 `Request` 常量。
4. ⬜ **文档与验证**：更新 `CLAUDE.md` 与实现说明，跑全部单元测试与 `RunScript.sh` 构建；部署到测试机看日志。文档、单元测试与构建已完成，部署到测试机还没做。

### 文档

同一批次更新：项目 `CLAUDE.md`（结构表里 `LaunchpadAwakenerShared` 与辅助进程那两行，以及「改文本输入辅助进程」一条里的部署说明），[Launchpad 复刻的实现说明](../Internal/LaunchpadReplica.md) 里讲辅助进程连接与签名的段落，[已裁决清单](../Internal/ReviewAdjudications.md) 里提到 `XPCObjectBox` 与「测试进程里没有 seam」的两条。0001 是当时的决策快照，不改。不新增使用指南：这次只换了通道，用户看到的行为不变。

## 备选：SwiftyXPC

SwiftyXPC 已经在依赖图里，App 与 daemon、App 与 payload 两条通道经 swift-helper-service 用它。没选它，是因为有两处语义不同，要额外写代码补：

- **收到的消息不保证按顺序处理。** 它为每条消息各开一个 `Task`，在全局并发执行器上解码后再跳到处理者所在的 actor，先到的可能后处理。这条通道两个方向都依赖顺序：`changed` 一旦乱序，Dock 会显示旧文字。
- **单向消息会弹回一条空消息。** 处理完一条不要回复的消息后，它仍会发一条没有名字的字典回去，对方的 `errorHandler` 收到 `missingMessageName`。

补的办法有两种：在 App 里让每条消息都等到回复再发下一条，还要加超时，防止一条消息没有回复把后面的全卡住；或者先改 SwiftyXPC 的 fork，而 daemon 那条通道也在用这个库。系统接口两样都不用做。

## 决策日志

| 日期 | 决定 | 理由 |
|------|------|------|
| 2026-11-10 | Created as Draft | 文本输入通道是项目里唯一手写 libxpc 的通道，用户要求改用更高层的 Swift 接口 |
| 2026-11-10 | 起初的方案是 SwiftyXPC，改为系统的 Swift XPC 接口 | SwiftyXPC 不保证处理顺序，单向消息还会弹回空消息；用户让查系统接口，查下来顺序、单向消息、`Codable`、签名要求都满足，也不用新增依赖 |
| 2026-11-10 | 用户批准，开始实现 | 实现放在 `feature/text-input-swift-xpc` |
| 2026-11-10 | 服务类型不标 `@available(macOS 26.0, *)`，只在设签名要求处判断版本，低于 26 拒绝所有连接 | `@Loggable` 给生成的成员写死了 macOS 11 的 `@available`，类上标更高的版本就编不过；判断收在一处，效果相同 |
| 2026-11-10 | 实现完成，待部署到测试机验证、用户看过后收尾 | 开发机上全部单元测试通过（新增 19 个），`RunScript.sh` 构建通过、三个切片都在，辅助进程只多链接了系统的 `libswiftXPC.dylib` |
| 2026-11-10 | 部署到测试机留到回家后在 Ultra 上直连做 | 从公司那台部署要经 Mac mini 转发，转发约 10 分钟就断，断在半途会弄坏 MacBook 上的 App |
