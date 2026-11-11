# 0012 - 多显示器：照 macOS 15 开在 Dock 所在的那块屏

- **状态**: Implemented
- **创建日期**: 2026-11-11
- **最后更新**: 2026-11-11
- **实现分支**: `feature/multi-display`
- **配套文档**: [Launchpad 复刻：实现说明](../Internal/LaunchpadReplica.md)「开在 Dock 所在的那块屏，显示期间 Dock 不换屏」；[独立版实现说明](../Internal/StandaloneLaunchpad.md)「Dock 在哪块屏，问窗口服务器」

## 摘要

两版 Launchpad 现在都写死在主显示器上（`CGMainDisplayID()`），接了第二块屏（比如经随航把 iPad 当显示器）也不会出现在那里。改为照 macOS 15：开在 Dock 当前所在的那块屏；显示期间不让 Dock 换屏；显示器插拔或改分辨率时收起；失去键盘焦点（比如去另一块屏点了别的 App）时收起；Dock 换到别的屏时，按那块屏的尺寸提前渲染图标。

## 方案

**15.5 的做法**（逆向所得，地址属于 15.5 的 Dock）：

- 只开在 Dock 所在的屏：`-[Springboard display]`（`0x100008248`）就是 `[[DockBar display] identifier]`，窗口 frame 取这块屏的 `CGDisplayBounds`（`-[Springboard totalScreenBounds]`，`0x10000B6AC`）。所有入口——F4、触发角、点 Dock 里的图标、捏合——都只切换显隐，不带显示器参数，没有哪条用指针所在的屏或主屏。
- 显示期间 Dock 不换屏：指针推到另一块屏底边时，Dock 经 `-[DockVisibility forceDockOntoDisplay:]`（`0x1000551AC`）换屏，这个方法在 Launchpad 可见或 stack 展开时直接返回。27.2 的同一方法（`0x100035694`）只剩 stack 那一条检查。
- 显示器重配置就收起：Dock 的重配置回调（`sub_10010CEB4`）在 Begin 之后的第一个回调里调 `[Springboard setVisible:NO reason:@"display reconfig"]`，再更新 Dock 自己所在的屏。
- 失去键盘焦点就收起：`-[Springboard lostKeyFocus:]`（`0x10009262C`），由 CGEvent 类型 21、字段 0x40 的事件转来；0x4000、有警告面板、文本框正在输入时不收。

**复刻要做的：**

- **选屏**（共用模块）：宿主报告 Dock 在哪块屏（`SpringboardHost.dockDisplayIdentifier`），共用代码取它；读不到、或那块屏已不在活动显示器里时，用主显示器。
  - 注入版读 `DockBar.display` 的 `identifier`（`DisplayDescriptor`，编码 `I16@0:8`，26.0 到 27.2 的头文件里都有）。用 `display` 而不是 `realDisplay`：前者是 Dock 换屏一开始就设好的目标屏，后者要等旧屏上的 Dock 窗口撤下才跟上，15 用的也是前者。
  - 独立版问窗口服务器：`SLSGetDockRectWithOrientation` 给出 Dock 的矩形，取中心点所在的屏；中心点不在任何屏上（Dock 藏起来时）取与矩形相交的屏。
- **用选出的屏**：`SpringboardController` 开窗口、截壁纸、算尺寸、预渲染图标，共用的离屏自检与独立版的自检，都改用选出的屏。`dockGeometry` 改成按屏取（`dockGeometry(onDisplay:)`），独立版的刘海高度取那块屏的。建窗口、截壁纸、文本框与删除确认的定位本来就按屏或按全局坐标，不用改。
- **显示期间拦住 Dock 换屏**（注入版）：替换 `-[DockVisibility forceDockOntoDisplay:]`（编码 `v20@0:8I16`，26.0 到 27.2 的头文件里都有）：Launchpad 显示时不转给 Dock；没显示时照常转，再按目标屏预渲染图标。独立版的窗口本来就盖住 Dock，不拦。
- **显示器重配置就收起**（共用）：注册 `CGDisplayRegisterReconfigurationCallback`，Begin 之后的回调到来时，显示中的 Launchpad 不带动画收起，再按此时 Dock 所在的屏预渲染图标。
- **失去键盘焦点就收起**（注入版）：在已有的事件 hook（`-[DockAppEventHandler handleDockBarEvent:type:]`）里认出 15 的那种事件，照 15 的例外判断后收起。独立版已经在失去激活时收起。
- **测试**：选屏规则；Dock 矩形到显示器的换算；重配置回调的判断；失焦事件的判断；新用到的 Dock 方法与 hook 的编码记进 `DockSignatureTests`。多屏的实机效果只能在接着第二块屏的真机上看，开发机上只跑单元测试。

**没有询问就采用的假设：**

- 显示期间重配置一律不带动画收起，不在新尺寸下原地重排。15 也是收起。
- 图标缓存不清旧尺寸：每多用一种图标尺寸就多一份缓存，份数以接过的显示器为限。15 存的是一份 256 点的图，不分尺寸，复刻按屏幕尺寸渲染，所以多出这一份。
- 独立版拦不住 Dock 换屏；换了也只是 Launchpad 留在原屏，下次打开才跟过去。
- 不做：同时在几块屏上显示；跟着指针选屏。

**落地步骤**（每步各自构建、测试通过）：

1. ✅ 选屏与按屏取值：宿主接口、两个宿主、`SpringboardController`、自检，以及单元测试与签名测试。
2. ✅ 显示器重配置就收起，并预渲染图标。
3. ✅ 注入版拦住 Dock 换屏、换屏后预渲染图标。
4. ✅ 注入版失去键盘焦点就收起。
5. ✅ 文档同步：注入版与独立版的实现说明、`CLAUDE.md`。

## 决策日志

| 日期 | 决定 | 理由 |
|------|------|------|
| 2026-11-11 | Created as Draft | 用户经随航接上 iPad 当第二块屏，发现两版都只开在主显示器上，要求支持多显示器 |
| 2026-11-11 | 开在 Dock 所在的屏，不跟指针 | 用户选定；与 15 一致 |
| 2026-11-11 | 用户批准方案、要求直接开工；提案由 agent 起草，用户事前未审阅 | 方案先在对话里给用户看过，用户选了「写提案并开工」 |
| 2026-11-11 | 开始实现 | 实现放在 `feature/multi-display` |
| 2026-11-11 | `DisplayDescriptor` 的 `identifier` 单独写成一个 proxy，不进装 hook 前的那批核对 | 它对不上时只是选不了屏、退回主显示器，不该连带整批 hook 都不装；与项目「可选功能的方法单独成协议」的做法一致 |
| 2026-11-11 | Dock 换屏后的预渲染排在 Dock 自己的换屏之后，不再替换 `-[DockBar setDisplay:]` | 逆向确认 `forceDockOntoDisplay:` 只是把换屏 `dispatch_async` 到主队列，转给 Dock 之后再排一个块就能读到新屏；少一个 hook 就少一处新构建上可能对不上的地方 |
| 2026-11-11 | 显示器重配置后等 1 秒再预渲染 | Dock 在自己的重配置回调里更新所在的屏，与复刻的回调谁先谁后不定 |
| 2026-11-11 | 失去键盘焦点照 15 的码与例外判断，每个通知的码都写进 info 日志 | 在另一块屏点别的 App 时 Dock 收到的是 0x1000 还是 0x4000 无法静态确定，要在真机上看日志 |
| 2026-11-11 | 独立版的 Dock 矩形按左上角原点的全局坐标读，用开发机上的一条测试坐实 | 单块屏上分不出两种原点；换成 AppKit 坐标后它正好接在可用区域的下沿 |
| 2026-11-11 | 自审 9 条：修 3 条，6 条登记进已裁决清单 | 修的是：`forceDockOntoDisplay:` 的 hook 移出主批、单独成一批可选安装（带回归测试，修前失败），对不上时不再连带打开 Launchpad 的 hook 一个都不装；失焦注释的歧义；新标识符里的 `rect` 缩写 |
| 2026-11-11 | 后续项：基线代码里的 `rect` 缩写（`rectInContainer`、`currentBarRect` 等）不在这条分支上改 | 与这项功能无关，改名会和别的分支冲突 |
| 2026-11-11 | 实现完成，待用户看过后收尾 | 开发机上 `swift test` 555 个测试通过，`RunScript.sh` 完整构建与三个架构切片校验通过；多屏效果没有在真机上看过。文档：两份实现说明、`CLAUDE.md`、已裁决清单已同步；没有新术语 |
| 2026-11-11 | 合进 `main` 时，「拖到 Dock」的拖动窗口改建在界面所在的屏 | 那项功能先一步合进本地 `main`，拖动窗口写死在主显示器上，它的已裁决清单里「不修」的理由正是「Launchpad 只在主显示器上显示」；多显示器合进来后理由不再成立，改为 `SpringboardDisplay.current`，那条裁决改记为已修 |
| 2026-11-11 | 用户看过后收尾，状态改 Implemented，编号 0012 | 用户认为没问题，与同时收尾的「拖到 Dock」一起推送 `main`。实现说明两份已写（注入版、独立版），登记为配套文档；没有给外部调用方的契约，不需要使用指南；没有新术语。后续项：在另一块屏点别的 App 时 Dock 实际收到的失焦码（0x1000 还是 0x4000），要在接着第二块屏的真机上看日志确认；基线代码里的 `rect` 缩写 |
