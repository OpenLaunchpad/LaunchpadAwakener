# Draft - 在 macOS 27 的 Dock 中复刻 macOS 15 的 Launchpad

- **状态**: In Progress
- **作者**: JH
- **创建日期**: 2026-11-05
- **最后更新**: 2026-11-08
- **所属愿景**: 无
- **关联提案**: 无
- **实现分支 / PR**: `feature/launchpad-replica`（worktree `.worktrees/LaunchpadAwakener-LaunchpadReplica`）；验证用原型在分支 `experiment/injection-prototype`
- **配套文档**: [实现说明](../Internal/LaunchpadReplica.md)

## 摘要

macOS 26 停用了 Launchpad，macOS 27 把它的代码从 Dock 里彻底删除。本提案在 27 的 Dock 进程里重新实现 15 的 Launchpad：用注入 Dock 的 payload 接管系统里所有「打开 Apps」的入口，在 Dock 自己的窗口与事件体系上，按 15.5 的类划分用 Swift 重写数据层与界面层；外观与行为和 15 一致，第一版包含网格、翻页、搜索、启动、文件夹、拖动整理、15 的壁纸模糊背景（另可选 27 的液态玻璃）、进出场动画与跟手的捏合手势。布局在首次启动时从 15 留下的数据库导入，之后存进自己的库。只支持 27、只给作者自己使用。

## 动机

- **27 上没有任何可以复活的东西。** 26.6 的 Dock 里 Launchpad 相关的 ObjC 类约 90 个，到 27.2 全部消失（`LP*`、`ECSB*`、`ECPager*`、`Springboard`、`SBSearchPage` 等），与 Launchpad 相关的字符串只剩 `com.apple.launchpad.toggle` 一条；默认布局文件 `LaunchPadLayout.plist` 也从 Dock.app 中删除。
- **26 上的「唤醒」路线走不通到 27。** 2025-09 的 LaunchpadAwakener 在 26 上手动创建 `LPSpringboard` 并调用 `setVisible:reason:`，弹出的全屏窗口不响应任何输入、只能重启。原因已查明：26 的 Dock 用一个恒返回 1 的函数在 23 处把入口改道到 Spotlight，`-[Springboard handleEvent:]` 一开头就因它直接返回。这条路即使修好也只适用于 26。
- **用户的布局还在。** 15 时代的数据库没有随升级删除：作者主力机上有 327 个 App、33 个文件夹、41 页，测试用的 MacBook 上有 150 个 App。
- **系统替代品不满足需求。** 27 的 Launchpad 键、捏合手势和 Dock 里的 Apps 图标都打开 Spotlight 的 Apps 视图，没有手动排列与文件夹。

## 前期调研

材料都在 `/Volumes/RE/Dock/<版本>/`（二进制、整镜像头文件导出、`.i64`）。地址只对所注明的构建有效。

- **15.5 的 Launchpad 规模与结构**（Dock 2341.4.7，arm64e UUID `B2A20DB0-…`）：约 77 个类、1800 个方法、380 KB 机器码（只计方法本体）。分三层：
  - 数据层 `LP*`：`LPStorage`（SQLite）、`LPAppManager`、`LPAppSource`（FSEvents、DiskArbitration、`_LSScheduleNotificationFunction`）、`LPLayout`（默认布局与排除名单）、`LPRoot` / `LPPage` / `LPGroup` / `LPApp`。
  - 界面层 `ECSB*` / `ECPager*` / `ECItemList*` / `ECTextInputLayer` / `ECAlertPanel`，以 Dock 自带的 `EC*` 图层类为基础。
  - 主控 `Springboard` / `LPSpringboard`。
- **15.5 依赖的 Dock 内部组件在 27.2 都还在**：`WALayerKitWindow`、`ECTextLayer`、`ECShadowTextLayer`、`ECImageGridLayer`、`ECProgressLayer`、`ECStatusLabelLayer`、`ECFlagLayer`、`ECTooltipLayer`、`ECGridLayer`、`ECModalEventController`；`Environment` 改成了 Swift 类。界面贴图 `ecsb_*`、`ectl_*` 也仍在 27.2 的 Dock.app 里。
- **15.5 怎么显示**：`-[Springboard init]` 在 Dock 的连接上建 `WALayerKitWindow`（tags 1024、level 20），桌面背景层依次叠加高斯模糊、饱和度、颜色矩阵三个 `CAFilter`；`-[Springboard prepareForEnterAnimation]`（`0x10002D57C`）把 Launchpad 窗口设到 27 层、Dock 窗口设到 29 层，并调用 `CPSStealKeyFocusOnConnection(cid, 1152)`；`-[Springboard _cleanupBeforeExitAnimation]` 调 `CPSReleaseKeyFocusOnConnection`。
- **15.5 怎么接收事件**：`-[DockAppEventHandler handleMachMessage:size:]` 每取到一个事件，先看 Launchpad 是否在接管，是就交给 `handleSpringboardEvent:type:`；后者让落在 `-[DockBar rect]` 里的点击继续交给 Dock。
- **27.2 的入口与事件**（Dock 2571.1.32.402，arm64e UUID `C53975B1-2956-3ED4-B699-D4CE2E6A602C`，与测试机 MacBook 上的二进制 md5 一致）：
  - 所有「打开 Apps」的路径都汇到 `-[Spotlight sendLaunchAppsBrowsing]`（6 处调用，其中 `-[DockBarSystemDefinedEventHandler handleSystemDefinedEvent:type:]` 对按键代码 104 的处理已经汇编核实）。
  - 每个事件都经过 `-[DockAppEventHandler handleDockBarEvent:type:]`。
  - Dock 自己的窗口几乎铺满屏幕（MacBook 上是 1169×717），不能用它的范围判断点击是否落在 Dock 上。
  - 鼠标划过 Dock 时，`-[DockBar rect]` 和 `-[DockBar setRollTile:]` 都不会被调用。`DockBar` 只存在于一个未导出的全局变量里（这个构建是 `0x100329BA8`）。
- **26.x 的停用方式**：26.0 的 `sub_1002AD300` 与 26.6 的 `0x1002acffc` 都是 `mov w0, #1; ret`，`DockAgent.launchPad` 改为可空。
- **旧数据库**：`$(getconf DARWIN_USER_DIR)com.apple.dock.launchpad/db/db`，schema version 13，表 `items` / `apps` / `groups` / `downloading_apps` / `categories` / `app_sources` / `image_cache`。`image_cache` 存有 256 点的 PNG 图标。根下按顺序排第一的 `HOLDINGPAGE` 是隐藏的空页。
- **27.2 系统里仍可用的私有接口**：IconServices（`ISIcon`、`ISCreateCGImageFromBindingWithSizeScaleAndOptions`）、`_LSScheduleNotificationFunction`、`SLSHWCaptureWindowList`、MultitouchSupport。Wallpaper 的 `WallpaperDisplayAssertion` 仍在，但初始化方法多了 `attributes:` 参数。
- **原型验证过的**（2026-11-05，在 MacBook 上，系统 27.2 26B123）：
  - hook `sendLaunchAppsBrowsing` 后，Launchpad 键与打开 Apps.app 都改为打开原型。
  - 窗口盖住菜单栏，Dock 浮在它上面。
  - 读旧库画出了第一页的 35 个图标。
  - hook `handleDockBarEvent:type:` 加上抢键盘焦点后，打字搜索、Esc、点图标启动、点空白关闭都正常。
  - 通过 `DockBar` 全局变量拿到 Dock 栏区域（`{271,635} 627×82`）后，点 Dock 能打开 App 并关闭窗口。
- **被证伪的假设**：
  - 用 Dock 窗口的范围判断点击是否落在 Dock 上——它近乎全屏。
  - 靠 `rect` 或 `setRollTile:` 被调用来拿到 `DockBar`——这两个方法都不会被调用。
  - App 只按文件是否存在来判断 payload 已暂存——重新编译后会一直注入旧 payload（这是 InjectionScaffold 模板的问题）。
- **前人的做法**：开源的独立 App [LaunchNext](https://github.com/RoversX/LaunchNext) 读旧库导入布局，支持手势与热角；它没法让菜单栏被盖住的同时 Dock 浮在上面，也拿不到 App Store 的下载进度。

## 提议方案

在 Dock 进程里运行一个 Swift payload，由 LaunchpadAwakener（InjectionScaffold 结构：App、特权 daemon、payload）负责注入与自动重新注入。payload 分四层：

1. **宿主接口层**：对每个用到的 Dock 方法核对签名；以 Dock 可执行文件的 UUID 为键，查一张「构建档案」表，取各构建特有的事实（如 `DockBar` 全局变量的地址）。遇到不认识的构建，一个 hook 都不装，入口退回系统的 Apps。
2. **数据层**：仿 15.5 的 `LPStorage` / `LPAppManager` / `LPAppSource` / `LPLayout`。自己的 SQLite 库沿用 15 的表结构；首次启动从旧库导入，旧库只读。App 的发现照 15.5 的做法，监听应用目录与 LaunchServices 的变更。
3. **界面层**：仿 15.5 的 `ECSB*` / `ECPager*` 用 Swift 重写，底层复用 27 的 Dock 里仍在的 `EC*` 图层类；尺寸、间距与动画参数取自 15.5。
4. **集成层**：
   - hook `-[Spotlight sendLaunchAppsBrowsing]`，接管所有「打开 Apps」的入口。
   - hook `-[DockAppEventHandler handleDockBarEvent:type:]`，在 Launchpad 显示期间接管事件，落在 Dock 栏上的点击照常交给 Dock。
   - 窗口用 Dock 连接上的 `WALayerKitWindow`，层级、键盘焦点的拿与还都照 15。
   - 跟手的捏合手势接入 27 的 Dock 手势系统。

**开发期的保险**一直保留：
- 退回开关：存在 `/tmp/LaunchpadAwakener.disabled` 时，入口退回系统的 Apps，正在显示的界面收起。
- Esc 关闭。
- 开发构建 20 秒无输入就自动关闭；正式构建去掉这一条。

### 非目标

- 删除 App：抖动模式里 App Store 应用左上角的关闭按钮、确认气泡与卸载。抖动模式本身已经做了（见决策日志）。
- 图标角标、App Store 购买时图标飞入与下载进度、VoiceOver 等辅助功能、15 的 Games 分组。
- 支持 macOS 26，或 27.2 26B123 以外的构建。新构建靠补构建档案逐个适配，不追求自动兼容。
- 公开发布：不做公证、自动更新与安装引导。
- 逐方法对照 15.5 的汇编来还原；只要求外观与行为一致。
- 多显示器：第一版只在主显示器上显示。
- 回写旧数据库。

## 详细设计

模块按 InjectionScaffold 的分层放在 `LaunchpadAwakenerPackage/Sources/LaunchpadAwakenerPayloadCore/` 下，以子目录区分：`Host`（宿主接口与构建档案）、`Data`、`Interface`、`Integration`。下面是各层的主要类型；方法细节在实现时按 15.5 对应类的公开行为确定。

```swift
// Host —— 每个 Dock 构建的事实；未知构建返回 nil，整个 payload 不安装任何 hook
struct DockBuildProfile: Sendable {
    let executableUUID: UUID
    let dockBarGlobalAddress: UInt
    static func current() -> DockBuildProfile?
}

// Data —— 对应 15.5 的 LPStorage / LPRoot / LPPage / LPGroup / LPApp
struct LaunchpadItemIdentifier: Hashable, Sendable { let rowIdentifier: Int64 }

enum LaunchpadItem: Sendable {
    case application(LaunchpadApplication)
    case folder(LaunchpadFolder)
}

final class LaunchpadStore {
    init(databaseURL: URL) throws
    func pages() throws -> [LaunchpadPage]
    func moveItem(_ itemIdentifier: LaunchpadItemIdentifier, toIndex targetIndex: Int, onPage pageIdentifier: LaunchpadItemIdentifier) throws
    func makeFolder(merging firstItemIdentifier: LaunchpadItemIdentifier, with secondItemIdentifier: LaunchpadItemIdentifier, title: String) throws -> LaunchpadItemIdentifier
}

enum LegacyLaunchpadImporter {
    /// 只读旧库；跳过 HOLDINGPAGE 一类的隐藏页
    static func importLayout(fromLegacyDatabaseAt legacyDatabaseURL: URL, into store: LaunchpadStore) throws
}

// Interface —— 对应 15.5 的 Springboard / ECSBSpringboard
@MainActor
final class SpringboardController {
    func toggle(reason: String)
    func show(reason: String, animated: Bool)
    func hide(reason: String, animated: Bool)
    /// 返回事件是否被 Launchpad 消费；没消费的交给 Dock
    func handle(_ inputEvent: SpringboardInputEvent) -> Bool
    /// 跟手捏合：0 为完全隐藏，1 为完全显示
    func updateGestureProgress(_ progress: Double)
    func endGesture(velocity: Double)
}
```

关键流程：

- **显示**：入口 hook 调 `SpringboardController.toggle(reason:)`。显示时先在窗口最底层铺上背景（见下面的「玻璃背景」），再按 15 的方式设置窗口层级、抬起 Dock 窗口、拿键盘焦点。隐藏时按相反顺序复原。再次打开回到上次收起时的页与开着的文件夹，与 15 一样只记在内存里。
- **事件**：在事件 hook 里，把 `CGEvent` 转成可跨线程传递的 `SpringboardInputEvent`，到主线程上交给 `handle(_:)`。落在 Dock 栏上（`DockBar` 的 `rect`）的点击照常交给 Dock；松开时，若点的是 Dock 栏，就关闭 Launchpad。点的若是 Apps 图标，它随后发来的打开请求不再把界面打开，所以点 Apps 图标能关掉 Launchpad。
- **背景**：照 15 每次打开时截取当前空间的壁纸、加 15 的三个滤镜（中途试过改成 Dock 的液态玻璃，用户看过后改回）。`springboard-background` 设为 `glass` 时改用 Dock 自己的液态玻璃（画 Dock 与 Cmd-Tab 切换器的那套控制器），固定深色，向屏幕外扩出 64 点；它由窗口服务器采样窗口身后的一切，App 的窗口也会被模糊进来。
- **跟手捏合（待验证）**：27.2 的 Dock 新增了 `DockSystemGestureManager` 与 `Gestures.framework`。需要先逆向出捏合手势的进度回调，再接到 `updateGestureProgress(_:)` 和 `endGesture(velocity:)`。如果拿不到进度，就把这一批降级为「捏合触发、播放固定动画」，并写进决策日志。

## 替代方案考量

- **独立 App（不注入 Dock）**：不改系统、能分发。否决的理由：
  - 改不了 Dock 窗口的层级，做不到「盖住菜单栏、Dock 浮在上面」。
  - 收不到 Dock 的事件与手势，也拿不到 App Store 的下载进度。
- **唤醒 26 残留的原版代码**：27 上已经没有这些代码，只对 26 有效，而本提案只支持 27。
- **把 15 或 26 的 Launchpad 机器码搬进 27 的 Dock**：这些代码与当年 Dock 的内部状态、全局变量、私有框架版本紧紧绑在一起，跨版本运行不可控。
- **仿照 27 的 Cmd-Tab 切换器全局抢占事件**（独立连接加 `CGSSetEventCapture`）：一旦失去控制，整台机器的输入都会被锁住——这正是 26 那次只能重启的情形。原型改用 15 的做法：拿键盘焦点，再接管 Dock 的事件总入口，风险更小。
- **界面层自己用 CALayer 写**：系统更新时要适配的地方最少，但观感离原版更远。作者选择复用 Dock 的 `EC*` 图层类，接受每次系统更新可能要跟着适配。
- **逐方法对照汇编还原**：最忠实，但约 1800 个方法的工作量与收益不相称。作者选择只要求外观与行为一致。
- **直接读写旧数据库**：能和 15 共用布局，但会改动系统留下的那份数据。作者选择导入后自己存。

## 影响

### 用户可见变化

- Launchpad 键、捏合手势、Dock 里的 Apps 图标，以及其他所有「打开 Apps」的路径，都改为打开复刻版的 Launchpad；系统的 Apps 视图不再出现。
- 恢复办法：创建退回开关文件后，所有入口立即退回系统的 Apps；在 App 里卸载 daemon 并重启 Dock，就完全复原。

### 可发现性

- 安装 LaunchpadAwakener、批准 daemon 后，默认开启自动注入：登录时和 Dock 每次重启后都会自动注入。这款工具本身就是 Launchpad 的替代品，默认开启符合预期。

### 数据与配置兼容

- 旧数据库只读不写。首次启动时导入一次，之后存在 `~/Library/Application Support/LaunchpadAwakener/` 下自己的库里。
- 导入失败时，按 App 的发现结果从零生成布局，并在日志里写明原因。
- 15 的偏好键（`springboard-rows`、`springboard-columns`、`springboard-show-duration`、`springboard-hide-duration`、`springboard-page-duration`）照样生效。

### 平台与最低版本

- 只支持 macOS 27.2（26B123，Dock 2571.1.32.402）；其他构建在补上构建档案之前不安装任何 hook。
- 运行的机器需要已关闭 SIP。开发与验证只在测试用的 MacBook 上进行。

### 发布

- 只供作者自用，用开发者证书签名，不公证。
- 默认布局表（`LaunchPadLayout.plist`）从 15.5 复制一份进仓库；界面贴图在运行时从 27 的 Dock.app 中读取，不复制进仓库。

## 落地步骤

每一批都在 MacBook 上验证通过后才进入下一批。

1. **基础与入口**，分四步提交：
   1. ✅ 结构：把原型的 InjectionScaffold 结构（App、daemon、payload 三个外壳与本地包）搬进功能分支，payload 按 `Host` / `Data` / `Interface` / `Integration` 分目录。InjectionScaffold 的两处绕过一并保留：依赖钉在 `exact: "0.1.4"`；App 每次启动后的第一次注入都重新暂存 payload。
   2. ✅ 宿主与集成：构建档案、宿主接口校验、两个入口 hook、`DockBar` 获取、窗口与层级、键盘焦点、保险机制。原型的界面作为过渡界面保留，到第 2 批换掉。
   3. ✅ 数据层：自己的库、旧库导入、App 的发现与变更监听，带单元测试。
   4. ✅ App 侧：默认开启自动注入，并随登录启动。
   - 验证：重启 Dock 后自动注入；导入的页数、文件夹数与旧库一致。
   - ✅ 2026-11-05 在 MacBook 上验证：部署后与 App 运行中重启 Dock，都只注入一次、两个 hook 装上、5 个 Dock 方法签名全部吻合；首次导入 3 页、2 个文件夹、149 个 App，与旧库从根出发可见的部分一致；对账加入 16 个 15 之后安装的 App，删掉 16 个已卸载的（逐个用 Spotlight 确认不在机器上）。
2. ✅ **主界面**：用 `EC*` 图层类重写网格、分页、页码指示与双指翻页，再加上搜索、键盘方向键导航与启动。验证：与 15 截图并排比较尺寸与间距。
   - 2026-11-05 已做的验证：几何按 15.5 规格里 1470×956 屏的手算示例写成单元测试，逐项吻合；在 MacBook 上，16 个 Dock 方法签名全部吻合，开发构建启动时离屏建一次界面，日志显示 Dock 自己的 `ECGridLayer` 按数据源建出第一页全部 29 个图标、标题由 `ECShadowTextLayer` 绘制、图标与标题位置符合 15 的公式；149 个图标按 Dock 当前的图标样式渲染，无失败，Dock 未崩溃。
   - 待用户验证：打开后的观感与 15 截图并排比较；翻页、搜索、方向键、点击启动的手感。
   - 2026-11-07 用户指出后补上两处行为：再次打开回到上次收起时的页与开着的文件夹；打开时点 Dock 上的 Apps 图标会关掉 Launchpad。单元测试覆盖位置在布局变化后的换算与「打开 Apps」请求的应答规则。MacBook 上用截图与模拟点击核对：翻到第 2 页后 Esc 关闭，再打开仍在第 2 页；开着文件夹时用「打开 Apps」关闭，再打开时文件夹仍开着；打开时点 Apps 图标，界面关闭且不再弹回，关闭时再点则打开。测试后已翻回第 1 页。
3. ✅ **文件夹与拖动整理**：文件夹的打开、关闭与改名，拖到图标上建文件夹，拖动重排与跨页拖动，全部写回自己的库。验证：改动在 Dock 重启后依然保留。
   - 2026-11-06 已做的验证：库的移动、溢出、建文件夹、放入、改名、拖出后解散都有单元测试，并验证重开数据库后仍在；打开的文件夹与拖动命中按 15.5 规格的手算示例写成单元测试；在 MacBook 上 19 个 Dock 方法签名全部吻合，离屏自检显示文件夹图标的方圆与 Dock 的 `ECImageGridLayer` 缩略图尺寸符合规格，Dock 未崩溃。
   - 2026-11-06 用户看过后的修正：打开文件夹补上动画；拖到 App 上建文件夹按 15 的逐帧时序重做（快速松手原地变成文件夹、两张图片先后缩进缩略图、0.75 秒后自动弹开；停住 1 秒弹开一个还没存进库的文件夹，在里面松手才写库，拖出去就解散）；拖进文件夹时主页留下的空位保留到文件夹关闭后 250 毫秒。库在任何编辑让文件夹只剩一个或零个 App 时都会解散它，配了单元测试。MacBook 上 21 个 Dock 方法签名全部吻合，Dock 未崩溃。
   - 待用户验证：打开、关闭、改名文件夹，拖动重排、跨页、建文件夹、拖出文件夹的手感与动画，以及 Dock 重启后改动仍在。
   - 2026-11-06 用户要求后补上抖动模式与搜索框的点击：在图标上按住 1 秒（按着 Shift 要 5 秒）或按住 Option 进入，图标照 15 的参数抖动；再长按、Esc、点空白处或松开 Option 退出；抖动中点开文件夹，抖动带进文件夹。搜索框点进去即激活：放大镜与占位文字左移，出现闪烁的光标。单元测试覆盖抖动参数、Option 规则与图标的抖动开关。MacBook 上实测并截图核对：长按进入（按住的图标放大到 1.1 倍且不抖）、Esc 先退出抖动再关文件夹、点空白处只退出抖动、抖动带进文件夹、搜索框点击后的样子与 15.5 虚拟机里一致。Option 与 Shift 没法用现有的模拟输入工具按住，没有实测。
   - 2026-11-08 用户对照 15.5 指出后修正改名的两处问题（见决策日志）：只有按在标题文字上才开始改名，标题那一行文字以外的地方照面板外处理、按下就关文件夹；打字时文字不再一闪一闪，标题与搜索框换字时同样直接换上。单元测试覆盖标题的命中区，以及三处文字图层在离屏渲染器里换字后不带动画，都先确认修改前失败。MacBook 上改前改后各录一段 60 帧录屏逐帧对照：改前每打一个字，旧名字在原处淡出、新名字左移半个字宽淡入，两行叠在一起，点标题右边约 100 点处也会进入改名；改后打字一帧之内换上，同一处点击关上文件夹，提交改名时标题直接换成新名字。测试用的文件夹已改回原名。
   - 2026-11-08 用户指出改名不能移动光标后，照 15 的文本框补上编辑（见决策日志）：进入时整个名字选中，打字替换；←→ 按字、Option 按词、Command 与 ↑↓ 到头尾，Shift 扩选，Command-A 全选；Delete、Option-Delete、Command-Delete、Fn-Delete；点击放光标、拖选、双击选词；放不下时横向滚动。Esc 改为与 Return 一样按当前文字提交。单元测试覆盖这些编辑规则、按键的读法、字间位置与滚动。先在 15.5 虚拟机里看了原版（进入时全选的蓝底、→ 与 ← 的效果、Esc 后名字不变），再在 MacBook 上截图、录屏核对：全选、中间插字、拖选、横向滚动、Esc 提交都与原版一致，选区高度相同。双击与 Shift、Option 组合模拟工具发不出，只有单元测试。测试用的文件夹已改回原名。
4. ✅ **背景与动画**：壁纸模糊背景，以及进出场的放大缩小动画。验证：与 15 录屏逐帧比较。
   - 2026-11-06 已做的验证：在 MacBook 的 Dock 里截取壁纸窗口成功（2338×1434 像素，5 毫秒），15 的三个滤镜都建得出来，Dock 未崩溃。
   - 2026-11-06 用户看过后的修正：背景改为 Dock 自己的液态玻璃（见决策日志）。MacBook 上离屏自检建出的玻璃是一个由窗口服务器采样、带 `glassBackground` 滤镜的 `CABackdropLayer` 加 SDF 图层，向屏幕四边外扩 64 点，Dock 未崩溃。
   - 2026-11-06 经用户同意，在 MacBook 上用截图、录屏和模拟的鼠标事件自测：玻璃背景铺满全屏（此前背景透明的原因是界面按窗口根图层定大小，而它当时是 0×0）；文件夹打开有面板放大与图标飞出的动画；快速把 App 松在另一个 App 上，原地变成文件夹、两张图片缩进缩略图、随后自动弹开；从弹开的文件夹里把 App 拖出去，面板关闭后文件夹解散回原来的 App。测试用的文件夹已拆掉，页面恢复原样。
   - 2026-11-06 用户看过玻璃后要回原版效果：背景改回 15 的模糊壁纸，截图核对与 15 一致（壁纸重度模糊压暗，窗口、小组件与菜单栏都被挡住）；录屏核对按下文件夹里的图标不再出现变暗的方块。
   - 2026-11-06 文件夹开合动画照 15 的机制重做（见决策日志）：图片从缩略图飞出、在格子里长大，标题在图片下方淡入，全部用同一个事务里的隐式动画；页面网格照 15 关掉裁剪。MacBook 上以 60 帧录屏逐帧核对：打开第一帧 9 张图片正好盖在文件夹图标的缩略图上、没有被裁掉，随面板展开飞进格子；关闭时缩回缩略图，文件夹图标无缝接上。随后在用户提供的 macOS 15.5 虚拟机里录下真正的文件夹开合，与复刻逐帧对照：图片飞出、标题与页面的走法一致；唯一的差别是 15 的面板半透明、透出正在淡出的主网格，据此把面板改成单纯的白色半透明（见决策日志）。虚拟机录屏会掉帧，时间曲线没法量，两边都用 Core Animation 的默认隐式动画。
   - 待用户验证：背景与文件夹毛玻璃的观感、进出场与 15 的录屏逐帧比较。
5. ✅ **跟手捏合**：逆向 27 的手势系统，接入渐进进度与松手判断。验证：捏到一半松手会弹回。
   - 2026-11-06：照 15 的状态机读 Dock 收到的原始 DockSwipe 事件，跟手与松手弹簧都有单元测试。只有关掉 Spotlight 自己的捏合（`defaults write com.apple.spotlight trackpadAppBrowseEnabled -bool NO`）后才接管，这一步由用户决定。
   - 待用户验证：Dock 是否真的收得到捏合事件（开发构建会把每个捏合事件写进日志），以及捏到一半松手会弹回。

**收尾时必须判断两件事**（判断结果写进决策日志，不允许沉默跳过）：

- **要不要配套专题文章**：有「从 API 签名看不出来的调用方契约」就写使用指南；有「下次维护会踩、代码本身看不出来的决策」就写实现说明（构建档案的维护与新系统构建的适配流程，大概率要写）。写了就登记到头部的「配套文档」。
- **有没有引入新术语**：有就在同一批次登记进术语表（项目级 `Documentations/Glossary.md`）。

## 决策日志

| 日期 | 变更 | 说明 |
|------|------|------|
| 2026-11-05 | Created as Draft | 27 的 Dock 已删除 Launchpad；原型在 MacBook 上验证了入口接管、窗口层级、读旧库出图与键盘鼠标，可以进入完整移植 |
| 2026-11-05 | 走注入 Dock 的路线，不做独立 App | 只有在 Dock 里才能复现层级、焦点与事件；独立 App 的局限见「替代方案考量」 |
| 2026-11-05 | 复刻程度定为外观与行为一致，类的划分参照 15.5 | 逐方法对照汇编的工作量与收益不相称 |
| 2026-11-05 | 只支持 macOS 27 | 26 上原版代码仍在，另当别论；同时适配两个系统会让测试量翻倍 |
| 2026-11-05 | 首次启动从旧库导入，之后存进自己的库 | 不改动系统留下的数据 |
| 2026-11-05 | 只给作者自用 | 可以接受只认特定系统构建的做法，系统更新后再适配 |
| 2026-11-05 | 第一版在基本功能之外，加上文件夹与拖动整理、壁纸模糊背景与进出动画 | 抖动编辑与删除、角标、下载进度、辅助功能留到以后 |
| 2026-11-05 | 全部替代系统的 Apps，保留退回开关 | 与 15 的体验一致 |
| 2026-11-05 | 用 Swift 实现 | 与原型一致，便于使用新的语言特性 |
| 2026-11-05 | 界面层复用 Dock 的 `EC*` 图层类 | 观感更接近原版；作者接受系统更新时跟着适配的代价 |
| 2026-11-05 | 代码继续放在 LaunchpadAwakener 仓库 | 原型与注入基础设施都已在这里 |
| 2026-11-05 | 捏合手势做成跟手渐进 | 与 15 的体验一致；需要额外逆向 27 的手势系统 |
| 2026-11-05 | 用户批准，开始实现 | 实现放在 `feature/launchpad-replica`；第 1 批拆成四步，各自能构建通过 |
| 2026-11-05 | 自己的库直接沿用 15 的表与触发器，旧库按树导入 | 排序靠 15 的触发器维护，行为与 15 一致；导入只走从根出发能到达的页，跳过 `HOLDINGPAGE` 一类的隐藏页、断了父项的页、正在下载的 App、空页与空文件夹 |
| 2026-11-05 | App 只在确实卸载时才从布局里删除 | 搜索目录里没找到、书签也解析不到、LaunchServices 也不认识，三者都成立才删，避免装在别处的 App 被误删 |
| 2026-11-05 | App 的变更只靠 FSEvents 监听应用目录，没有接 LaunchServices 的私有通知 | 目录监听已覆盖安装与删除；`_LSScheduleNotificationFunction` 的签名没有逆向确认，调错会让 Dock 崩溃 |
| 2026-11-05 | 15.5 的 `LaunchPadLayout.plist` 放进测试资源，排除名单与默认首页以 Swift 常量随 payload 发布 | 注入的框架里用 `Bundle.module` 找不到资源时会直接让 Dock 崩溃；测试逐项核对常量与原文件一致 |
| 2026-11-05 | 注入后 Dock 连续 3 次在 15 秒内退出，就自动关掉自动注入并说明原因 | 自动注入默认开启后，一个加载即崩溃的 payload 会让 Dock 反复崩溃；这条保护属于开发期的保险 |
| 2026-11-05 | daemon 已就绪时 App 启动不弹主窗口，只留菜单栏图标 | 随登录启动后每次都弹窗口太打扰；菜单栏里加了「Show Window」 |
| 2026-11-05 | 第 1 批验证时发现同一个 Dock 被注入两次，改成每个进程、每次暂存都只进行一次 | App 启动时的注入与进程监视的注入同时开始，两边都在等待途中通过了「还没注入」的检查；第二次暂存会在第一次加载框架时删掉它 |
| 2026-11-05 | 界面层的纯计算（网格几何、搜索匹配、翻页与方向键规则）做成包内可见的类型，作为单元测试的落点 | `EC*` 图层与事件接线只能在 Dock 里验证；这几块规则可以离开 Dock，用 15.5 规格里的手算数值独立检验 |
| 2026-11-05 | Dock 的厚度取 27 的 Dock 栏矩形，不照搬 15 的「图标大小 + 上下留白」 | 27 的 Dock 外面多了一圈玻璃，15 的算法会让网格压到它；代价是小屏上图标比 15 小一档（MacBook 当前分辨率下是 48 点） |
| 2026-11-05 | 搜索框直接把 Dock 收到的按键当文字，不接输入法 | 15 用另一进程里的真文本框，复刻成本高；没有输入法就打不出中文，标题匹配不上时仍会按 App 文件名匹配。接输入法列为后续工作 |
| 2026-11-05 | 触控板翻页用滚动事件自带的阶段判断开始与结束，没接 15 用的手势事件；三指轻扫翻页暂不支持 | 两者给出的开始、结束时刻相同，滚动事件更简单；轻扫翻页留到做捏合手势时一起接 |
| 2026-11-05 | 图标经 IconServices 的 `initWithURL:` 取，描述符复制 Dock 自己的 `iconDescription` | 与 Dock 栏同一套样式；Dock 走的 `_LSBindingCreateWithURL` 是 C 函数，签名无法校验。透明与着色样式下 Dock 在图标背后画的玻璃底没有复刻 |
| 2026-11-05 | 在第 3 批之前，从图标上拖动按翻页处理，文件夹图标暂用 `ecsb_group` 贴图加 3×3 缩略图 | 拖动整理与文件夹外观属于第 3 批 |
| 2026-11-05 | 开发构建启动时离屏建一次界面，把 Dock 图层类的产物写进日志 | 打开界面属于交互操作，由用户进行；这样不打开界面也能从日志核对第 2 批的接线 |
| 2026-11-06 | 文件夹图标照 15 用图层画：半透明浅色方圆加 Dock 的 `ECImageGridLayer` 3×3 缩略图，不用 `ecsb_group` 贴图 | 逆向确认 15.5 根本不引用那批贴图，它们是 10.7–10.9 时代的遗留 |
| 2026-11-06 | 拖动只在松手时写库；拖到文件夹上停 1 秒会打开它继续摆放，拖到 App 上则松手时才建文件夹、不先弹开 | 与 15 一样不在拖动途中写库；15 会把 App 先换成新文件夹并打开，复刻它要在库外维护一个尚未存在的文件夹，代价大、收益小 |
| 2026-11-06 | 不支持把图标拖到 Dock 上、不支持拖动搜索结果、文件夹里不支持方向键导航，拖动时文件夹不额外加一行 | 都是次要路径；拖到 Dock 要模拟 Dock 自己的拖放协议，风险高 |
| 2026-11-06 | 改名同搜索框一样直接处理按键，不接输入法；Esc 取消改名、保留原名 | 15 的远端文本框按 Esc 时的行为没能查清，取消更符合直觉 |
| 2026-11-06 | 界面层把翻页（滚动层、页码、跟手与回弹）抽成主界面与打开的文件夹共用的一块 | 15 的文件夹面板本身就是一个独立的翻页器，规则与主界面相同 |
| 2026-11-06 | 背景每次打开时截取 WindowManager 的壁纸窗口，套 15 的三个滤镜；截不到就用 15 自带的径向渐变 | 27 的壁纸窗口归 WindowManager，Dock 手里已经没有桌面图层；截图沿用 15 的调用与参数，动态壁纸同 15 一样停在打开那一刻。读壁纸图片文件那一级降级要用 AppKit，跳过 |
| 2026-11-06 | 进出场照 15：整体淡入淡出加网格 1.05 倍缩放，0.25 秒；退场一开始就交还输入，点图标启动的动画与退场同时播放 | 15 的行为 |
| 2026-11-06 | 捏合手势不走 27 的 Dock 手势系统，改为在已有的事件 hook 里读原始 DockSwipe 事件，照搬 15 的状态机与弹簧；只在用户关掉 Spotlight 自己的捏合后才接管 | 逆向发现 27 的捏合由 Spotlight 进程识别，Dock 的手势系统里已经没有它，但 Dock 很可能仍收到原始事件；两边同时响应会一起打开，所以默认不接管 |
| 2026-11-06 | 配套文档：写实现说明，不写使用指南；新术语登记进项目术语表 | 实现说明记下了代码看不出来的决策与新 Dock 构建的适配流程；没有面向调用方的契约，不需要使用指南。构建档案、DockSwipe、退回开关、离屏自检、Springboard 这几个词在本项目有特定含义 |
| 2026-11-06 | 实现完成，待用户看过后收尾 | 5 批都已实现并在 MacBook 上做了非交互验证；需要看画面、动手操作的验证留给用户 |
| 2026-11-06 | 用户同意在测试用的 MacBook 上关掉 Spotlight 自己的捏合 | 让复刻版接管捏合；Spotlight 当即撤掉了它的手势注册，删掉 `com.apple.spotlight` 的 `trackpadAppBrowseEnabled` 即可恢复 |
| 2026-11-06 | 背景改用 Dock 自己的液态玻璃（Cmd-Tab 切换器同一套控制器），固定深色、不随背后亮度变化，向屏幕外扩 64 点；不再截取壁纸。玻璃取不到时退回带 15 三个滤镜的窗口服务器模糊 | 用户看过后反馈背景透明、没有模糊，希望改成更贴合新系统的玻璃。固定深色是为了让沿用 15 的白色标题看得清；外扩让玻璃的边缘高光落在屏幕外。Dock 的 `DockGlobals` 全局变量地址随之记进构建档案，因为取玻璃环境的方法在它不存在时会让 Dock 崩溃 |
| 2026-11-06 | 文件夹面板的毛玻璃改由窗口服务器采样，并移出遮罩 | 背景不再是窗口里画出来的图像，只采样本窗口的面板会没有东西可模糊；遮罩会把内容放到屏幕外绘制，那里采样不到窗口身后 |
| 2026-11-06 | 打开文件夹前先把面板的起始状态提交上屏，并先排好面板里的图标 | 用户反馈打开文件夹没有动画。原因是 Core Animation 不给从未提交过的图层做隐式动画，新建的面板全是这种图层；图标没排版时飞出动画也被跳过 |
| 2026-11-06 | 拖到 App 上建文件夹照 15 的逐帧时序重做：快速松手时目标原地变成文件夹、两张图片先后缩进缩略图、0.75 秒后自动弹开；停住 1 秒时弹开一个尚未存进库的文件夹，在里面松手才写库，拖回面板外就解散。推翻本日「拖到 App 上只在松手时建文件夹、不先弹开」那条 | 用户看过后指出这段动画与 15 差得多；逆向补齐了 15 三条路径的时序（RE 笔记 4.11） |
| 2026-11-06 | 拖进文件夹弹开时，主页上被拖图标留下的空位保留到文件夹关闭后 250 毫秒才合拢；从文件夹拖出时，主页同样在面板关上 250 毫秒后才让位，只剩一个 App 的文件夹此时解散 | 15 的行为 |
| 2026-11-06 | 库在任何编辑把 App 带出文件夹、让它只剩一个或零个 App 时都解散这个文件夹，而不只是「拖出到主页」这一种编辑 | 从文件夹拖出后放到别的 App 或文件夹上、或拖过最后一页，原文件夹会只剩一个 App 留在库里，与界面上的解散不一致 |
| 2026-11-06 | 新增 `springboard-glass-variant` 偏好，可在 Dock 的三种玻璃（Dock 本体、去掉前景效果、Cmd-Tab）之间切换，下次打开生效 | 玻璃的观感只能看过才能定，换样式不必重新编译 |
| 2026-11-06 | 界面的容器按屏幕尺寸定大小，不取 Dock 窗口根图层的尺寸 | 换成玻璃后用户反馈背景仍然透明。经用户同意在 MacBook 上截图查明：界面建好时窗口的根图层还是 0×0，按它定大小的背景也是 0×0（玻璃只在屏幕左下角露出一小块）；最初的「背景透明」也是这个原因，壁纸截图本身没有问题 |
| 2026-11-06 | 关闭文件夹时不再连带动画被拖出去的图标；图标在缩放中挪位置一律设 bounds 与 position，不设 frame | 在 MacBook 上录屏自测发现：拖出文件夹时，手上的图标随面板关闭消失；解散文件夹时，正在缩小的图标被设了 frame，恢复原大后被放大十倍、挪出原格 |
| 2026-11-06 | 背景改回 15 的模糊壁纸（默认），Dock 的液态玻璃保留为 `springboard-background` 设为 `glass` 时的选项 | 用户看过玻璃后觉得模糊效果不如原版。当初壁纸「透明」的真正原因（容器 0×0）已经修好，照 15 截图加三个滤镜就是原版效果 |
| 2026-11-06 | 文件夹面板的毛玻璃改为把同一张壁纸图再过一遍面板的滤镜、一次算好，不再用实时 backdrop；玻璃背景下仍用窗口服务器采样的 backdrop | 用户反馈点文件夹里的 App 时「也会做动画」。录屏查明是 macOS 27 上实时 backdrop 局部重绘画错：按下图标，那一格和另一块区域的毛玻璃会变暗。面板身后只有静态的壁纸，固定算好的结果与 15 的实时毛玻璃相同 |
| 2026-11-06 | 点图标启动时的放大淡出动画保留，文件夹里的 App 也有；改成模型值取起始状态，结束后移除副本，减少动态效果时不播 | 逆向确认 15.5 文件夹内外走同一条路（`performActionForItem` → `globalBoundsOfIconForItem:` 递归查到文件夹里的图标 → `_launchRunnable:withImageRect:` → `performOpenAnimationForRunnable`）。原先模型值是终点状态，第一帧会闪出放大后的残影 |
| 2026-11-06 | 打开文件夹时，面板从文件夹图标的方圆展开，里面的图标留在各自的格子里随之淡入，不再从缩略图飞出；关闭时仍照 15 缩回缩略图。这是有意偏离 15 | 用户要求打开时图标不动。逆向核对过 15.5 的做法：`_minimizeItemLayers` 先把每个图标的图片挪到缩略图上，动画事务里 `-[ECSBGridLayer _layoutItemLayers]` 再对每个图标调 `layout`、不关隐式动画，所以 15 的图标是从缩略图飞出来的。改成淡入而不是直接露出，是为了第一帧文件夹方圆里不出现正好压在那里的半个图标 |
| 2026-11-06 | 文件夹开合恢复图标从缩略图飞出，并照 15 的机制重做：只动格子里的图片与标题（图片 frame 在缩略图与原位之间变化，标题从图片下方淡入淡出），不再缩放整个格子；页面随一个缩到文件夹单元格的容器平移；全部是同一事务里的隐式动画；关闭时始终收第一页，别的页只随容器滑走；标题与页码移回文件夹图标上下。推翻本日「打开时图标不动」那条 | 用户确认 15 确有这段动画，只是此前的版本与 15 不一样。逆向对出四处差别：旧版用显式的线性动画，与面板的默认缓动不同步；缩放的是整个格子，连标题一起缩小；27.2 Dock 的 `ECGridLayer` 会裁剪格子，15 的 `ECSBGridLayer` 在初始化时关掉了裁剪（15.5 `0x10011DB70`），否则缩略图上的图片会被页面边缘裁掉；动画开始前的一次排版会把图片放回原位，于是照 15 的 `disableLayout` 在动画期间暂停图片与标题的排版 |
| 2026-11-06 | 文件夹面板改成单纯的白色 97%、不透明度一半，不再模糊身后，所有背景样式都一样。推翻本日「文件夹面板的毛玻璃改为把同一张壁纸图再过一遍面板的滤镜」那条 | 在 macOS 15.5 虚拟机里录下真正的文件夹开合对照：开合途中，正在淡出的主网格透过面板清晰可见，只被白色冲淡。15 给面板的 `CABackdropLayer` 设的模糊与饱和度在 `backgroundFilters` 上，backdrop 不执行；同一台虚拟机里程序坞的 backdrop 照常模糊，排除了虚拟机做不了模糊的可能。15 面板的「毛玻璃」只是身后本来就模糊的壁纸 |
| 2026-11-06 | 补上 15 的抖动模式（代码里叫 `deleting`）：长按 1 秒或按住 Option 进入，再长按、Esc、点空白处或松开 Option 退出，抖动参数照 15 的两段叠加关键帧动画；关闭按钮、删除确认与卸载不做 | 用户要求加上长按抖动。删除只对 App Store 下载的 App 有效（15 判定 `uninstallabilityOfFileAtURL:` 为 1），15 的确认气泡由 27.2 已经删掉的 `com.apple.dock.ecap` 服务画，而对照用的 15.5 虚拟机登录不了 Apple ID、装不了 App Store 应用，没法比对，用户决定只做抖动 |
| 2026-11-06 | 搜索框点进去即激活并取得焦点：放大镜与占位文字左移，出现闪烁的白色光标；Tab 切换焦点，失去焦点且没字时退回居中 | 用户反馈点搜索框没反应。15 在按下时就激活文本框（`-[ECSBLayer leftMouseDown:in:]`），样子与 15.5 虚拟机里的截图核对过 |
| 2026-11-07 | 再次打开回到上次收起时的位置：主页的页、开着的文件夹及其页。搜索结果按进入搜索前的页记；正在关闭的文件夹、拖动中还没存进库的文件夹按已关闭记。只记在内存里，Dock 重启后回到第一页 | 用户指出缺了这一项。15 的 Launchpad 在 Dock 的整个生命周期里只建一次，收起时只清搜索、选中与抖动，不动页码、不关文件夹（15.5 `_cleanupBeforeExitAnimation` `0x100030768`、`_cleanupAfterExitAnimation:openCount:` `0x100030EF8`），偏好里也没有记页码的键；它清空搜索时无动画回到进入搜索前的页 |
| 2026-11-07 | 打开时点 Dock 上的 Apps 图标会关掉 Launchpad：点 Dock 收起时记下时刻，此后 0.5 秒内到达的「打开 Apps」请求算作这次点击的，不再打开。没有照 15 按图标类型豁免 | 用户反馈点 Apps 只会打开。27.2 的 Apps 图标经 `-[WVExpose exitAndDoWork:]` 排到主队列的下一轮才发请求（`0x100015028`、`0x1001DD51C`），那时点 Dock 的收起已经执行，请求又把界面打开。15 是在点图标时豁免 Launchpad 图标（docklet 类型 2，`0x10002CE10`）；照做要再依赖 Dock 的命中测试与图标类型两个接口，新构建上多两处可能对不上。代价是点 Dock 上别的图标后 0.5 秒内按 Launchpad 键会被吞掉一次 |
| 2026-11-08 | 只有按在标题文字上才开始改名，松手在哪都算；标题那一行文字以外的地方照面板外处理，按下就关文件夹；改名中点编辑框内照旧不结束改名。会在眼前换字的文字图层（改名编辑框、标题、搜索框）关掉 Core Animation 的交叉淡化 | 用户对照 15.5 指出：原版点标题那一行不会进入改名，只有点文字才会；复刻打字时文字一闪一闪。逆向确认 15 的 `-[ECSBGroup leftMouseDown:in:]`（`0x1000A368C`）只接落在 `labelLayer` 上的按下，抬起时把按下的图层原样交回、与位置无关；左右各宽 200 点的 `labelEditLayer` 平时隐藏，只是编辑框，里面的 `ECTextInputLayer` 收下框内所有按下。用户确认那一行别处会关文件夹。录屏查明闪烁是文字图层换内容时 0.25 秒的交叉淡化：标题居中，新旧两行错开半个字叠在一起 |
| 2026-11-08 | 改名框照 15 的文本框编辑：进入时整个名字选中；方向键配 Option、Command、Shift 移动与扩选，Command-A 全选，几种删除，点击放光标、拖选、双击选词，放不下时横向滚动。Esc 与 Return 一样按当前文字提交，推翻 2026-11-06「Esc 取消改名、保留原名」那条。复制粘贴、撤销、输入法不做 | 用户指出改名不能移动光标。逆向 15.5 的文本输入服务 `com.apple.dock.ecti`：改名框是真正的 `NSTextField`，建好即调 `selectText:` 全选（`_handleSetupMessage:forPeer:` `0x100001198`），Esc 的 `cancelOperation:` 与 Return 一样当成编辑结束、按当前文字提交（`control:textView:doCommandBySelector:` `0x100000FBC`），有焦点时方向键照常移动光标。用户选择照 15 连选区一起做、Esc 照 15 改成提交。在 15.5 虚拟机里量了选区色 `#3F638B` 与选区、光标的高度。payload 里没有 AppKit，剪贴板用不了，复制粘贴先不做 |
| 2026-11-08 | 给 Dock 留的高度改照 15 从格子大小算：经 `-[DockBar desiredTileSize]` 与 `tileSize` 读格子，套 15.5 的留白表，默认大小下是 79 点。推翻 2026-11-05「取 27 的 Dock 栏矩形」那条 | 用户觉得图标大小与原版有差别。量 15.5 虚拟机的截图，原版在默认大小下留 77–81 点，而不是逆向笔记推测的 59 点；27.2 算格子的方法没变，只是玻璃 Dock 的留白表与栏高（94 点）更大。按栏高留，在 1487×936、1512×982 等屏幕上图标比 15 小一档；MacBook 当前的 1739×1080 上两种算法都是 120 点，只是行高差 2 点。照搬 15 的算法也不会压到 Dock，只是界面比 15 更贴近它 |
