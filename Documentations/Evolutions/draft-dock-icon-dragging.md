# Draft - Launchpad 开着时拖动 Dock 栏里的图标

- **状态**: In Progress
- **创建日期**: 2026-11-16
- **最后更新**: 2026-11-16
- **关联提案**: [在 macOS 27 的 Dock 中复刻 macOS 15 的 Launchpad](draft-launchpad-replica.md)
- **实现分支 / PR**: `feature/dock-icon-dragging`（worktree `.worktrees/LaunchpadAwakener-DockIconDragging`）
- **配套文档**: [Launchpad 复刻：实现说明](../Internal/LaunchpadReplica.md)「Dock 上开始的拖动归 Dock」

## 摘要

macOS 15 的 Launchpad 开着时，Dock 栏照常可用：可以按住 Dock 里的图标拖动，拖出 Dock 松手，图标就「噗」地一下从 Dock 里移除。复刻做不到：在 Dock 上按下交给了 Dock，随后的拖动事件却全被复刻收下，Dock 根本收不到，图标拖不动；松手若不在 Dock 上，Dock 连松手也收不到。本提案让 Dock 上开始的整段手势都归 Dock，并让拖出去的图标落在 Launchpad 上时照样被移除。

## 方案

### Dock 怎样拖图标（逆向，26.6.2 与 27.2 相同）

- `-[DockBarMouseEventHandler _handleTileClickEvent:type:]`（27.2 `0x1000837CC`，26.6.2 `0x1001129A4`）：按下时记住按中的图标与位置；拖动中指针离按下点在任一方向超过 5 点，就开始拖这个图标；松手时如果还没开始拖，才执行点击。
- 开始拖图标（27.2 `sub_100021EA0`）建一个 CoreDrag，调 `CoreDragStartDragging`，**在收到的那次拖动事件里同步跟到松手才返回**。拖动期间鼠标事件照样经 `-[DockAppEventHandler handleDockBarEvent:type:]` 进来，`-[DockBarMouseEventHandler _handleClickEvent:type:]` 用它们调 `-[DragController updateRemoveWithEvent:atLocation:]`，判断指针是否已越过 Dock 外的「移除线」。返回后，能移除就播移除动画并保存，否则放回原位。
- Dock 的 CoreDrag 接收函数装在**整个 Dock 连接**上（`-[DockBar installCoreDragEventHandlers]`，窗口参数为 0），复刻的窗口也在这个连接上。松手落在复刻的窗口上，Dock 会当成「放回 Dock」：`-[DockBar handleDockEventDropInternal:tile:oldPos:context:]` 在没有间隙时把图标插回原位，图标不会被移除。
- 15.5 专门处理了这一点：Launchpad 开着（`springboardIsCapturingEvents`）且拖的不是 Launchpad 自己的东西时，Dock 的跟踪函数（`sub_100118D98`）与接收函数（`sub_100119510`）把消息转给 `-[Springboard handleDragEvent:type:]`，Dock 自己的间隙与放回都跳过，图标的去留只看是否越过移除线。
- 15.5 点 Dock 收起 Launchpad 是在图标的松手动作里（`0x10002CE10`），只有点击才有；拖动不收起 Launchpad。

### 要做的

1. **Dock 上开始的手势整段归 Dock**：左键在 Dock 栏上按下时记下这次手势（`SpringboardDockGesture`）；之后的拖动与松手不论指针在哪都交给 Dock，不经复刻。指针离按下点在任一方向超过 5 点即算拖动，与 Dock 的判断相同；松手时只有没算拖动的才照旧收起复刻（点了 Dock 上的东西），拖过的不收起。
2. **Dock 拖图标期间，复刻的窗口让指针穿过**：把这次手势的拖动事件交给 Dock 之前，给复刻的窗口加上窗口服务器的「忽略鼠标事件」标记（`CGSSetWindowTags` 第 9 位，`-[NSWindow setIgnoresMouseEvents:]` 设的也是它），Dock 处理完这个事件再恢复成建窗时的「接收鼠标事件」（第 10 位）。Dock 拖图标是在其中某个事件里同步跑完的，所以整个拖动期间落点都穿过复刻的窗口，到达底下的窗口，与没开 Launchpad 时一样：越过移除线就移除，否则放回。拖动中嵌套进来的事件不重复设置，只由最外层恢复（`SpringboardPointerPassThrough`）。
3. 文档：实现说明补一段「Dock 上开始的拖动归 Dock」、与 15 的差异与已知降级；逆向结论写进 `/Volumes/RE/Dock/27.2/Notes/DockTileDrag.md`。

宿主接口 `SpringboardWindow` 多一个 `setPassesPointerEventsThrough(_:)`；独立版的窗口盖住了 Dock，不会有 Dock 上开始的手势，实现为空。

### 没有询问就采用的假设

- 拖完图标后**不收起** Launchpad，照 15 只在点击时收起。Dock 拖图标前后会抢、还一次键盘焦点（15 与 27 同样如此），之后复刻若收到「失去键盘焦点」仍按 15 的规则收起；15 实际会不会因此收起没有在虚拟机上核对。
- 拖到 Dock 栏里松手，按 27 的 Dock 照常让出间隙、调整顺序。15 开着 Launchpad 时把跟踪与接收都转走了，推断那时 Dock 里重排不生效；复刻不照搬这一点，按「Dock 归 Dock」处理。
- 只处理左键手势。右键、长按弹出的菜单与以前一样交给 Dock。
- 不另做 hook：只改复刻对事件的分流与自己窗口的标记，不动 Dock 的方法，所以不增加签名核对。`CGSSetWindowTags` 与 `CGSClearWindowTags` 是 26.0 到 27.2 各版 Dock 都导入的 SkyLight 函数，经 `dlsym` 取。

### 落地步骤

1. ✅ 手势分流：`SpringboardDockGesture`（纯值类型，带单元测试）与 `SpringboardController.handle(_:)` 的左键分支。
2. ✅ 拖动时窗口穿透：`SpringboardPointerPassThrough`（带单元测试）、`SpringboardWindow.setPassesPointerEventsThrough(_:)`、Dock 宿主的实现、事件 hook 在交给 Dock 前后调用控制器。
3. 文档与非交互验证。

### 后续项

- Launchpad 开着时拖 Dock 的分隔条调整了 Dock 大小，复刻给 Dock 留的高度要到下次打开才跟上（以前拖动收不到，不会出现这种情况）。

## 决策日志

| 日期 | 决定 | 理由 |
|------|------|------|
| 2026-11-16 | Created as Draft | Launchpad 开着时拖不动 Dock 栏里的图标，15 可以把图标拖出 Dock 移除 |
| 2026-11-16 | 用户调用 `implement-feature` 即批准，提案由 agent 起草、用户事前未审阅 | — |
| 2026-11-16 | 开始实现 | — |
| 2026-11-16 | 另起一份提案，不并进总提案的第 6 批 | 最近的新功能（多显示器、Apps 图标）都是独立提案；这一项与总提案的其余步骤互不依赖 |
| 2026-11-16 | 落点穿透用窗口标记，不装自己的 CoreDrag 接收函数，也不 hook Dock | Dock 的接收与跟踪函数是 C 函数，ObjC hook 够不着；自装接收函数要先逆向 HIServices 怎样在窗口专属与整个连接的处理函数之间选，没有把握；改 `-[WVExpose isWindowsMode]`、`currentDraggedTile` 这类 Dock 方法的返回值会波及别处。窗口标记只影响复刻自己的窗口，作用范围就是一次同步的拖动 |
| 2026-11-16 | 每个交给 Dock 的拖动事件前后都设、恢复标记，不只在越过 5 点的那一次 | 与 Dock 的判断在边界上（Sidecar 的事件用 10 点）有出入时也不会漏；设标记只是一次窗口服务器调用 |
