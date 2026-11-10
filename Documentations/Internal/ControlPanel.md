# 注入版 App 的控制面板：实现说明

> 配套提案见 [照 DockIconOverride 重做注入版 App 的控制面板](../Evolutions/0003-app-control-panel.md)。
> 本文记录实际落地的实现、与提案的差异，以及没在代码里写明、下一任维护者会踩到的决策。面向维护者。

## 背景与目标

注入版 App 是个菜单栏工具：装 daemon、把 payload 注入 Dock、Dock 重启后再注入，窗口说明现在能不能用、卡在哪一步。它的规则大多来自同一套脚手架生成的姊妹项目 DockIconOverride，那边每条都是在真机上出过事才定下的；这里的代码注释说明了没有这条规则时会出什么事。

## 结构

| 位置 | 是什么 |
|---|---|
| `AppUI/Application/ApplicationDelegate.swift` | `ApplicationDelegate`：持有全部控制器，跑启动流程（检查 daemon → 找已在的 payload → 注入），处理「App 已在运行时再打开」；外壳 `LaunchpadAwakener/main.swift` 只建它并运行 |
| `AppUI/ControlPanel/`、`AppUI/MenuBar/` | 窗口：状态横幅，以及常规（开机启动、daemon、输入法辅助进程）、Launchpad（退回开关、Dock 构建、打开整理窗口）、注入、错误四节；菜单栏菜单。界面层怎么搭见 [AppKit 界面层的实现说明](AppKitInterface.md) |
| `AppUI/Organizer/` 等 | 整理 Launchpad 的窗口，见[它的实现说明](LaunchpadOrganizer.md) |
| `AppCore/ReadinessPresentation.swift`、`StatusLine.swift` | 横幅与两行状态的文字、图标与颜色角色 |
| `AppCore/PayloadInjectionCoordinator.swift` | 暂存、注入、自动再注入、重启 Dock、payload 通道、状态刷新、闪退保护 |
| `AppCore/PrivilegedDaemonController.swift` | daemon 的登记与连接；`ensureDaemonUsable()` 连不上或版本不对就重装，60 秒冷却 |
| `AppCore/ControlPanelReadiness.swift` | 横幅说什么：按顺序检查，返回第一个挡路的原因 |
| `AppCore/PayloadChannel.swift` | App 这一侧的 [payload 通道](../Glossary.md#payload-channelpayload-通道)，以及读 daemon 注册表的 `InjectedPayloadRegistry` |
| `AppCore/MachOFileUUIDReader.swift` | 读包里 payload 每个切片的 `LC_UUID` |
| `AppCore/LaunchAtLoginController.swift`、`TextInputAgentController.swift`、`KillSwitchController.swift` | 开机启动、文本输入辅助进程、[退回开关](../Glossary.md#kill-switch退回开关)三个开关的状态，每次都从系统读回；辅助进程还有它在不在运行、是不是旧版，以及重启 |
| `AppCore/TextInputHelperState.swift`、`ProcessTable.swift` | 从进程表认出正在运行的输入法辅助进程，判断它是不是这个 App 里的那份、启动后有没有被换过 |
| `PayloadInterface/PayloadRequests.swift` | 通道上的请求与回报类型，两边只共享这一个文件 |
| `PayloadCore/Integration/PayloadPeer.swift` | payload 这一侧的通道：监听、把端点登记进 daemon、回答状态 |

## 关键设计决策

**输入法辅助进程看进程表，旧版本自动换掉。** 辅助进程是 LaunchAgent，launchd 拉起后一直常驻到注销，重新构建或覆盖安装 App 都不会换掉它，重装 daemon 也不碰它；旧进程读不懂新消息时输入法就失效（提案 [在控制面板里显示输入法辅助进程，并自动换掉旧版本](../Evolutions/0009-text-input-helper-status.md)）。所以「Input method helper」一行在注册启用之后，改为显示进程的状态：没在运行（下次打开 Launchpad 时由 launchd 拉起）、在运行且是当前版本、在运行但是旧版本。旧版本分两种：这个 App 里的那份在进程启动后被换过，或者运行的是别处的一份。认进程按可执行文件名加所在 `.app` 的 bundle ID，Debug 与 Release 不会混。「被换过」比的是文件的状态变更时间（ctime）与进程的启动时间：构建、拷贝、改名都会更新 ctime，而 `rsync -a` 会把修改时间（mtime）拷成源文件的，不能用来比。路径按 `realpath` 解析，与 `proc_pidpath` 报的一致（`URL.resolvingSymlinksInPath()` 会把 `/private/var` 写回 `/var`）。行上的「Restart」给它发 `SIGTERM`，下次打开 Launchpad 时 launchd 拉起这个 App 里的那份。App 启动时只自动重启「这个 App 里的那份被换过」的情况，与 daemon 版本不符时自动重装一个道理；「别处的一份」只提示不自动处理：同一个服务名可能正被另一份构建注册着，自动重启会让两份来回抢。

**payload 是不是旧的，比镜像 UUID。** payload 是映射进 Dock 的镜像，卸不掉；重新编译后再注入，Dock 里跑的还是旧代码。DockIconOverride 让 payload 报一个手写的版本号，这边 payload 改得太勤，版本号一定会忘了递增。所以 payload 报自己镜像的 `LC_UUID`（`#dsohandle` 指向的头），App 读包里 payload 每个切片的 UUID，都对不上才算旧的。链接器按内容算 UUID，代码不变 UUID 就不变，正好是「是不是同一份代码」。包里那份读不出来时不判旧，免得叫用户白白重启 Dock。

**payload 不答话，只断通道，不撤注入记录。** 「payload 不答」不等于「Dock 没了」，也不等于「没注入」：镜像卸不掉，注入过就一直在。DockIconOverride 曾把两者混为一谈：通道一断就把 Dock 从已注入列表里删掉，下一轮发现又把它当成没注入过，每隔几秒注入一次。判断表在 `HostRefreshDecision`，刚注入的 payload 还有 30 秒握手宽限：那时就断开，等于关掉它正要连的端点。

**先读注册表，再决定哪个 Dock 没注入。** 进程监视器在启动流程之前就开始跑，一启动就看到 Dock；它要是先注入，会把一个已经有 payload 的 Dock 当成没注入（第二次 `dlopen` 什么也不做），再用一个 payload 永远不会来连的新通道顶掉刚找回的那条——payload 的通道只在它启动时开一次。测试机上实测过：找回通道一百毫秒后，监视器又「注入」了一次。所以每次注入在确认 daemon 可用之后，先确认注册表读过（`hasReadRegistry`），没读过就先读。注册表里有某个 Dock 就说明它有 payload，即使 payload 这次没答话，也照样记为已注入。

**同时到达的请求合成一次。** 启动时启动流程、监视器的首次发现、首轮发现几乎同时检查 daemon。各查各的，第一个去重装，其余的被 60 秒的重装冷却挡下，报一次「冷却中」的失败，还触发 15 秒的自动重试退避，可 daemon 一秒后就好了。`SingleFlight` 让后到的等前一个的结果；读注册表也一样。

**等 payload 一律限时，而且限时不靠任务组。** 握手最多等 5 秒，每次问状态最多 2 秒（`withTimeLimit`）。任务组要等所有子任务结束才返回：DockIconOverride 那种「组里等两个非结构化任务」的写法，取消组并不取消它等的任务，所以每次注入都要等满 5 秒才出结果；而一个永不回复的 XPC 请求不响应取消，放在组里，限时就失效了，一个卡住的 Dock 会让窗口的刷新循环永远停住。`withTimeLimit` 用续体加锁，先到的结果胜出，另一个只取消、不等它。

**用户点「重启 Dock」，退出的那个 Dock 不算闪退。** 闪退保护（`QuickExitGuard`）把注入后 15 秒内退出的 Dock 算作 payload 弄崩的，连续三次就关掉自动注入。重启按钮先 `prepareForTargetRestart()` 忘掉旧 Dock（连同它的注入时间），再发 `SIGTERM`，所以连按几次不会误关。退出不论是监视器的退出源先看到，还是窗口的状态刷新先发现进程没了，都走同一个 `hostDidExit(_:)` 计数。被忘掉的旧 Dock 在退出之前另记在 `processIdentifiersBeingRestarted` 里，任何注入都跳过它：否则一轮刚好在发信号前跑过的发现会把它当成「漏注入的」，注入一个正在退出的进程，它的退出又被算成一次闪退。别的用户的 Dock（快速切换用户时）发不了信号，就留着不动，也不报错；它仍算在「旧的」那一组里，不会被当成重启后的新 Dock。

**横幅的顺序就是修的顺序。** `ControlPanelReadiness` 依次看：启动是否还在跑、daemon 是否可用、退回开关、有没有注入、hook 装上没有、payload 旧不旧。退回开关排在注入之前：开着它，别的都改变不了 Dock 的行为。「hook 没装上」排在「payload 旧了」之前：Dock 构建不受支持时，重启 Dock 换上新 payload 也一样什么都装不上。注入了但 payload 还没回话，按「可用」算：注入已经发生，没有要修的。

**开机启动只默认打开一次。** 原来开机启动跟着「自动注入」开关一起开关，每次启动都强行打开。现在它是独立的开关，第一次注入成功时，用户没表过态就登记一次，之后以用户为准（`LaunchAtLoginDefault`）。早先版本已经登记过的，原样保留。启动时不弹窗口的条件后来又改了一次：改用 AppKit 之后，只有登录时的自动启动才不弹，从 Finder 或 Dock 手动打开都弹（读启动时的 Apple 事件，见 [AppKit 界面层的实现说明](AppKitInterface.md)）。

**窗口按内容开，但不超过屏幕的可见区域。** SwiftUI 时期照 DockIconOverride 让表单坚持完整高度，内容一高过屏幕，窗口就伸到 Dock 后面（测试 MacBook 的可见高度只有 960 点）。现在 `ControlPanelWindowController` 第一次打开时按完整内容定高，最多到可见区域（已去掉菜单栏和 Dock）减去标题栏的余量 72 点（`ContentSizedWindowPlacement`），再多就在表单里滚动。说明文字都收进了悬停提示，daemon 与输入法辅助进程各占一行，与横幅重复的提示删了，测试 MacBook 上窗口从高过 960 点降到 617 点（含标题栏）。开发构建打开窗口后会把窗口与可见区域的 frame 写进日志（类别 `ApplicationActivationPolicyController`），不看屏幕也能核对。

**App 只链接一个包产物。** 原来是 `LaunchpadAwakenerAppCore`，改用 AppKit 后是 `LaunchpadAwakenerAppUI`，AppCore 经它间接链接。通道的回报类型在 `LaunchpadAwakenerPayloadInterface` 里，AppCore 不把它们放进自己的公开接口，而是转成 `ResidentPayload`。App target 再链接一个包产物，Xcode 有可能把 payload 框架也链进 App 里，而 payload 只该注入别的进程。

## 与提案的差异

- 落地步骤原本把 AppCore 与 payload 通道分成两步。协调器重写时两者分不开，合成了一步。
- 提案外加了一处：横幅在有一键可做的下一步时带一个按钮（安装、打开登录项、重新打开 Launchpad、立即注入、重启 Dock）。

**启动流程停下后，App 回到前台时再跑一次。** 启动流程停下多半是因为 daemon 还在等批准。用户从系统设置切回来时 App 被激活，启动流程就从头再走一遍，走到当前能走到的地方。不这样的话，横幅会一直显示批准之前的原因；自动注入关着时，已经有 payload 的 Dock 也不会被找回。

## 验证

- `LaunchpadAwakenerAppCoreTests`：重装冷却、注入死循环、状态过期、重启 Dock、进程监视器（这五组搬自 DockIconOverride），以及闪退保护、payload 构建识别、横幅顺序、开机启动默认值、退回开关、限时、同时到达的请求、重启时的进程选择与发信号。
- 测试机（MacBook，macOS 27.2）上看日志验证过：daemon 从 1.0.0 自动重装成 1.1.0；payload 装上两个 hook、开通道、把端点登记进 daemon；App 退出重开后从注册表找回了 Dock。
- 真机上的行为（payload 回话、重开 App 后找回 Dock、重启 Dock 后再注入）只能在测试机上看，见项目 `CLAUDE.md`「只在测试机上运行」。
