# Draft - 在 macOS 27 的 Dock 中复刻 macOS 15 的 Launchpad

- **状态**: In Progress
- **作者**: JH
- **创建日期**: 2026-11-05
- **最后更新**: 2026-11-05
- **所属愿景**: 无
- **关联提案**: 无
- **实现分支 / PR**: `feature/launchpad-replica`（worktree `.worktrees/LaunchpadAwakener-LaunchpadReplica`）；验证用原型在分支 `experiment/injection-prototype`
- **配套文档**: 待定 —— 落地时登记实现说明 / 使用指南的链接

## 摘要

macOS 26 停用了 Launchpad，macOS 27 把它的代码从 Dock 里彻底删除。本提案在 27 的 Dock 进程里重新实现 15 的 Launchpad：用注入 Dock 的 payload 接管系统里所有「打开 Apps」的入口，在 Dock 自己的窗口与事件体系上，按 15.5 的类划分用 Swift 重写数据层与界面层；外观与行为和 15 一致，第一版包含网格、翻页、搜索、启动、文件夹、拖动整理、壁纸模糊背景、进出场动画与跟手的捏合手势。布局在首次启动时从 15 留下的数据库导入，之后存进自己的库。只支持 27、只给作者自己使用。

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

- 抖动编辑与删除 App。
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

- **显示**：入口 hook 调 `SpringboardController.toggle(reason:)`。显示时先从 Dock 取当前桌面的壁纸图层或图片，叠加 15 的三个滤镜，再按 15 的方式设置窗口层级、抬起 Dock 窗口、拿键盘焦点。隐藏时按相反顺序复原。
- **事件**：在事件 hook 里，把 `CGEvent` 转成可跨线程传递的 `SpringboardInputEvent`，到主线程上交给 `handle(_:)`。落在 Dock 栏上（`DockBar` 的 `rect`）的点击照常交给 Dock；松开时，若点的是 Dock 栏，就关闭 Launchpad。
- **壁纸背景（待验证）**：优先沿用 15 的做法，在 27.2 的 Dock 里找出当前空间的桌面图层来源。找不到时，退而取静态桌面图片再加同样的滤镜。动态壁纸会因此变成静态，届时记入实现说明的降级项。
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
   3. 数据层：自己的库、旧库导入、App 的发现与变更监听，带单元测试。
   4. App 侧：默认开启自动注入，并随登录启动。
   - 验证：重启 Dock 后自动注入；导入的页数、文件夹数与旧库一致。
2. **主界面**：用 `EC*` 图层类重写网格、分页、页码指示与双指翻页，再加上搜索、键盘方向键导航与启动。验证：与 15 截图并排比较尺寸与间距。
3. **文件夹与拖动整理**：文件夹的打开、关闭与改名，拖到图标上建文件夹，拖动重排与跨页拖动，全部写回自己的库。验证：改动在 Dock 重启后依然保留。
4. **背景与动画**：壁纸模糊背景，以及进出场的放大缩小动画。验证：与 15 录屏逐帧比较。
5. **跟手捏合**：逆向 27 的手势系统，接入渐进进度与松手判断。验证：捏到一半松手会弹回。

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
