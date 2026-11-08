# Draft - 不注入 Dock 的独立版 Launchpad

- **状态**: In Progress
- **作者**: JH
- **创建日期**: 2026-11-08
- **最后更新**: 2026-11-08
- **所属愿景**: 无
- **关联提案**: [在 macOS 27 的 Dock 中复刻 macOS 15 的 Launchpad](draft-launchpad-replica.md)（注入版，本提案复用它的数据层与界面层）；[0001 用常驻辅助进程给搜索框与改名框接上输入法](0001-input-method-helper.md)（独立版不需要这个辅助进程）
- **实现分支 / PR**: `feature/standalone-app`（worktree `.worktrees/LaunchpadAwakener-StandaloneApp`）
- **配套文档**: [独立版 Launchpad：实现说明](../Internal/StandaloneLaunchpad.md)

## 摘要

新做一个独立的 App「Launchpad」：不注入 Dock，不需要关闭 SIP（系统完整性保护），自己开一扇盖住整块主屏幕（包括菜单栏与 Dock）的窗口，画出与注入版相同的 macOS 15 Launchpad。注入版的数据层与界面层搬进一个两边共用的模块，界面层里用到 Dock 的地方改成「宿主」接口：注入版照旧用 Dock 自己的图层类、窗口与卸载器，独立版用自己画的等价图层与普通的 AppKit 窗口。第一版从它在 Dock 里的图标或一个全局快捷键打开，不申请任何系统权限，只给作者自己使用。

## 动机

- **注入版的门槛与维护成本都在 Dock 上。** 它要关 SIP、装特权 daemon 并在登录项里批准；每个新的 Dock 构建都要先补一条构建档案才会生效（实现说明「适配新的 Dock 构建」），26.7 上就因为档案里没有这个构建而完全不生效过（注入版提案决策日志 2026-11-08）。独立 App 不碰 Dock 的内部，任何 26、27 的构建都能直接运行。
- **当初否决独立 App 的主要理由已不成立。** 注入版提案 2026-11-05 否决独立 App，首要理由是「改不了 Dock 窗口的层级，做不到盖住菜单栏、Dock 浮在上面」。作者现在接受独立版把 Dock 一起盖住，剩下的局限（收不到 Dock 的入口与手势）在本提案里明确列为非目标或后续项。
- **一万行复刻不必重写。** 数据层（`Data/`）完全不碰 Dock；界面层（`Interface/`）不用 AppKit，对 Dock 的依赖集中在 11 个文件、约 50 处调用（见「前期调研」）。把这些调用换成接口，整套 15 的复刻——几何、翻页、搜索、文件夹、拖动、抖动、动画——两边共用，修一次两边都好。
- **有几件事在普通 App 里本来就是现成的。** 注入版为了让搜索框与改名框用上输入法，专门做了一个托管文本框的辅助进程（提案 0001）；键盘焦点要经 SkyLight 去抢，事件要 hook Dock 的事件总入口。独立 App 是普通的前台 App，这三样都由 AppKit 直接提供。

## 前期调研

- **界面层对 Dock 的依赖**（2026-11-08 在 `main` 上逐行查过，路径相对 `LaunchpadAwakenerPackage/Sources/LaunchpadAwakenerPayloadCore/`）：

  | 文件 | 用到的 Dock 能力 |
  |---|---|
  | `Interface/SpringboardPageGrid.swift`、`Interface/SpringboardItemLayer.swift`、`Interface/SpringboardFolderPanel.swift`、`Interface/SpringboardControlLayers.swift` | 经 `DockLayerFactory` 建 `ECGridLayer`、`ECImageGridLayer`、`ECTextLayer`、`ECShadowTextLayer`，调 Dock 给 `CALayer` 加的 `setMaterialControl:appearance:`；共 13 个方法签名（`Host/DockLayerFactory.swift:45`） |
  | `Interface/SpringboardWindow.swift` | `WALayerKitWindow`；经 SkyLight 设窗口层级（自己 27、Dock 29）、抢与还键盘焦点 |
  | `Interface/SpringboardController.swift` | `WallpaperSnapshot` 截壁纸；`DockEnvironment` 读 Dock 的方向、厚度与刘海高度；`DockBarReference` 判断点击是否落在 Dock 栏上 |
  | `Interface/SpringboardIconProvider.swift` | 复制 Dock 的图标描述符（`DockEnvironment.iconAppearance`），再经 `IconServicesBridge` 取图 |
  | `Interface/SpringboardInterface+Deleting.swift` | `DockApplicationUninstaller`：Dock 的 `SystemApplicationUninstaller` |
  | `Interface/SpringboardRemoteTextField.swift` | `TextInputHelperClient`：文本输入辅助进程 |
  | `Interface/SpringboardBackground.swift` | `DockGlassMaterial`：可选的玻璃背景 |
  | `Interface/SpringboardSelfCheck.swift` | 开发构建的离屏自检，核对上面这些 |

  不依赖 Dock、在 App 里照样能用的：`QuartzCorePrivate`（Core Animation 的私有滤镜）、`SystemPasteboard`（HIServices 的 Pasteboard Manager）、`ApplicationLauncher`（LaunchServices 的 `LSOpenCFURLRef`）。`SpringboardPreferences` 读 `UserDefaults.standard`（`Interface/SpringboardPreferences.swift:9`），在 Dock 里它就是 `com.apple.dock` 域。
- **布局库的位置本来就是配置项**：`LaunchpadLibrary.Configuration` 带 `databaseURL` 与 `legacyDatabaseURL`（`Data/LaunchpadLibrary.swift:12`），换一个库、换一个导入来源都不用改数据层。注入版的库沿用 15 的表与触发器（实现说明「自己的库沿用 15 的表与触发器」），所以现有的旧库导入器原则上也能读它（推测，第 3 批用单元测试验证）。
- **Dock 图层类的行为都有逆向记录**（`/Volumes/RE/Dock/27.2/Notes/ECLayerReuse.md`）：`ECGridLayer` 的格子按 bounds 与行列取整、从左上角按行排、新图层插到最底下、只在初始化时问一次数量（1.1）；`ECImageGridLayer` 的条目层放在 `CAScrollLayer` 里、失效后重新问数量（1.3）；`ECShadowTextLayer` 在 `drawInContext:` 里按 `contentsScale`（大于 1 时再乘 0.6）缩放阴影后画字，`ECTextLayer` 打开字体的亚像素量化（1.4）。`ECImageGridLayer` 的 `scrollToTop` 与 `scrollToAvailableSpace` 还没细看。
- **图标样式不经 Dock 也能取**：`+[SLSIconAppearanceConfiguration fetchCurrentIconAppearanceConfiguration]` 取系统的图标外观配置，再按逆向笔记 3.2 的表自己给 `ISImageDescriptor` 设 `appearance`、`appearanceVariant`、`background`（笔记 3.3「做法 B」）。着色样式的色值怎么算还没查。
- **系统卸载服务不对第三方开放**：`uninstalld`（`/System/Library/PrivateFrameworks/Uninstall.framework/Resources/uninstalld`）只服务带 `com.apple.private.uninstalld.client` 权限的进程，Dock 带着这项权限（2026-11-08 在 27.2 上用 `codesign -d --entitlements` 与 `strings` 查）。第三方 App 拿不到苹果的私有权限。退一步移到废纸篓也有门槛：抽查本机 `/Applications`，带 App Store 收据的 App 有的属于 `root:wheel`，移动它们要管理员授权。
- **壁纸**：注入版用 `SLSHWCaptureWindowList` 截壁纸窗口（27 归 WindowManager，26 归 Dock 自己，`Host/WallpaperSnapshot.swift:26`）。第三方进程截别的进程的窗口要「录屏」权限；壁纸窗口是否例外没有验证（推测）。
- **界面贴图在运行时读得到**：27.2 的 `Dock.app/Contents/Resources` 里有 46 个 `ecsb_*`、`ectl_*` PNG 散文件，独立 App 能直接读。
- **15 总给 Dock 留位置**：不论 Dock 是否自动隐藏，15 都按 Dock 的格子大小留出它的厚度，`LPSpringboard.showsDock` 恒为 YES（`/Volumes/RE/Dock/15.5/Notes/LaunchpadMainInterface.md` 1.2）。
- **名字不冲突**：27.2 的 `/System/Applications` 里只有 `Apps.app`，没有 `Launchpad.app`。
- **前人的做法**：开源的独立 App [LaunchNext](https://github.com/RoversX/LaunchNext) 读 15 的旧库导入布局，支持手势与触发角（注入版提案「前期调研」），可见独立 App 这条路走得通。
- **dyld 在 macOS 上目前还允许 `dlopen` 主可执行文件**（`dyld/DyldAPIs.cpp` 里 `canBeExecutable` 只对 macOS 为真，注释写着以后也要禁），所以理论上能把 Dock 的可执行文件载进独立 App、借用它的 `EC*` 类；没有实测，取舍见「替代方案考量」。
- **看门狗能绕开 AppKit 收窗口**：SkyLight 导出 `SLSOrderWindow`，CoreGraphics 以 `CGSOrderWindow` 的名字转出（2026-11-08 用 `dyld_info -exports` 在 27.2 上查）。

## 提议方案

1. **拆出共用模块。** 新建 `LaunchpadAwakenerSpringboardCore`，放现在 payload 模块里的 `Data/` 与 `Interface/`（含全部纯计算）以及宿主接口。它不链接 AppKit，也不认识 Dock。`LaunchpadAwakenerPayloadCore` 只留下 `Host/`、`Integration/` 与 `PayloadEntry`，实现 Dock 宿主。新建 `LaunchpadAwakenerStandaloneCore` 实现 App 宿主，链接 AppKit。
2. **界面层经宿主接口拿 Dock 能力。** 进程启动时选定一次宿主：Dock 里由 payload 选，App 里由 App 外壳选。注入版的宿主就是今天的 `Host/` 代码，行为不变。
3. **独立版自己画四种图层。** `ECGridLayer`、`ECImageGridLayer`、`ECTextLayer` 与 `ECShadowTextLayer`、选中高亮的材质，照逆向笔记写成纯 Core Animation 的等价实现，放在共用模块里（单元测试里也建得出来）。注入版继续用 Dock 自己的，只在开发构建的离屏自检里把两套各画一遍、比对像素。
4. **一扇盖住一切的窗口。** 无边框 `NSWindow`，层级 27（与 15 的 Launchpad 窗口相同，高于菜单栏的 24 与 Dock 的 20），铺满主显示器；在所有空间与全屏 App 之上都能出现。窗口收到的每个事件都转成与注入版相同的 `SpringboardInputEvent`，交给同一个 `SpringboardController`。
5. **打开与收起。** 启动、点它在 Dock 里的图标、按全局快捷键时打开；Esc、点空白处、启动一个 App、App 失去激活（Cmd-Tab、点到别处）时收起，收起后把焦点交还给之前的 App。App 一直在后台运行，再打开不用重新读库与图标；默认随登录启动。
6. **输入法在自己的视图里接。** 承载界面的视图实现 `NSTextInputClient`，搜索框与改名框照现在的图层画，只是多出「组字中」的文字；不需要文本输入辅助进程。
7. **壁纸、图标与布局库。** 已经有录屏权限时照注入版截壁纸窗口，否则读壁纸文件，都套 15 的三个滤镜，绝不弹权限请求；图标样式按系统的图标外观配置自己建描述符；布局存在独立版自己的库里，首次启动从注入版的库导入，没有就从 15 的旧库导入。
8. **开发期的保险照旧，外加看门狗。** Esc 关闭、开发构建 20 秒无输入自动收起、存在 `/tmp/LaunchpadAwakener.disabled` 时不显示；另加一个后台线程盯着主线程，主线程卡住超过 3 秒就经窗口服务器直接把窗口移出屏幕，免得一扇卡住的全屏窗口挡住整台机器。运行与验证只在测试机上做，与注入版相同。

### 未经询问采用的做法

以下几项由 agent 定下，审阅时可以推翻：

- 快捷键用 [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts)（MIT，基于 Carbon 的 `RegisterEventHotKey`，不需要权限）提供录制控件与全局注册，只有独立版的模块依赖它。
- Release 的 bundle ID 是 `com.MxIris.LaunchpadAwakener.Launchpad`，Debug 加 `.debug` 后缀，让开发构建与装好的正式版不在 LaunchServices 里互相顶替；两者共用同一个布局库。
- 布局库在 `~/Library/Application Support/LaunchpadAwakener/Standalone/Launchpad.db`。
- 15 的 `springboard-*` 偏好键照样从 `com.apple.dock` 域读，与注入版同一份；快捷键、随登录启动这些独立版自己的设置存在它自己的域里。
- 开发构建带启动参数 `--self-check` 时只离屏建一次界面、把结果写进日志、不显示窗口，用作测试机上的非交互验证（打开界面属于交互操作，与注入版的做法一致）。
- 设置窗口只有两项：快捷键、随登录启动。
- 日志沿用 subsystem `com.MxIris.LaunchpadAwakener`，按模块分 category。

### 非目标

- 接管系统的入口：Launchpad 键、Dock 上的 Apps 图标、触发角、`Apps.app`。拦它们要「辅助功能」或「输入监控」权限，留作后续。
- 捏合手势。要用私有的 MultitouchSupport 自己识别拇指加三指的捏合，还要用户关掉系统的捏合，留作后续。
- 删除 App。系统卸载服务不对第三方开放；改成移到废纸篓留作后续。抖动模式照常用来整理，不显示关闭按钮。
- 把图标拖到 Dock 上：Dock 被盖住了。
- 玻璃背景选项：Dock 的玻璃控制器只在 Dock 进程里有，独立版只有 15 的模糊壁纸。
- 让 Dock 浮在界面上方：独立 App 改不了 Dock 窗口的层级。
- 注入版改用自己画的图层：注入版的观感保持不变。
- 与注入版共用同一个布局库，或两边实时同步。
- 公证、分发、App Store 与沙盒。
- 多显示器：与注入版一样只在主显示器上显示。
- 注入版也没有的：角标、下载进度、15 的 Games 分组、VoiceOver。

## 详细设计

### 模块与产物

```
LaunchpadAwakenerPackage/Sources/
├── LaunchpadAwakenerSpringboardCore/   # 新：Data/、Interface/、宿主接口、自己画的图层。不链接 AppKit
├── LaunchpadAwakenerPayloadCore/       # Host/、Integration/、PayloadEntry：Dock 宿主
├── LaunchpadAwakenerStandaloneCore/    # 新：App 宿主（窗口、事件、输入法、壁纸、图标样式、快捷键、设置）
└── ……                                   # Shared、HookKit、AppCore、DaemonCore、TextInputCore 不变

LaunchpadAwakenerStandalone/            # 新的 App 外壳，产物 Launchpad.app
```

依赖方向：`PayloadCore → SpringboardCore`，`StandaloneCore → SpringboardCore`，两个宿主互不依赖。payload 照旧不链接 AppKit；独立 App 不带 daemon、payload 与文本输入辅助进程，也不需要 arm64e 切片。现有测试改为测 `SpringboardCore`。

### 宿主接口

每个进程只有一个宿主，在第一次显示之前选定，形状照 swift-log 的 `LoggingSystem.bootstrap`：调用方在入口处一次性选定后端，库内只依赖接口。

```swift
// LaunchpadAwakenerSpringboardCore

/// What the springboard needs from the process it is drawn in: the Dock, or the standalone app.
@MainActor
package protocol SpringboardHost: AnyObject {
    /// macOS 15's `springboard-*` keys: the Dock's own defaults in the Dock, `com.apple.dock` in the app.
    var preferences: UserDefaults { get }
    var dockGeometry: SpringboardDockGeometry { get }
    /// The style application icons are drawn in; nil draws the default style.
    var iconStyle: SpringboardIconStyle? { get }
    /// Deletes applications; nil keeps the close boxes out of jiggle mode.
    var applicationUninstaller: (any SpringboardApplicationUninstaller)? { get }

    func makeWindow(onDisplay displayIdentifier: CGDirectDisplayID) -> (any SpringboardWindow)?
    func wallpaperImage(onDisplay displayIdentifier: CGDirectDisplayID) -> CGImage?
    /// A text field another process hosts so input methods work in it; nil edits in place.
    func makeHostedTextField(configuration: SpringboardHostedTextFieldConfiguration) -> (any SpringboardHostedTextField)?
    /// Whether a click at `globalPoint` belongs to a Dock drawn above the springboard.
    func isOnDock(_ globalPoint: CGPoint) -> Bool
}

/// Stand-ins for the Dock's `EC*` layer classes. Read without isolation: Core Animation copies item
/// layers on its own threads, and their initialisers make text layers.
package protocol SpringboardLayerFactory: Sendable {
    /// One page: cells sized from the bounds, filled from the top left row by row (`ECGridLayer`).
    func makePageGridLayer(source: SpringboardGridSource, rowCount: Int, columnCount: Int, scaleFactor: Float) -> (any SpringboardPageGridLayer)?
    /// A folder icon's thumbnails (`ECImageGridLayer`).
    func makeThumbnailGridLayer(source: SpringboardThumbnailSource, rowCount: Int, columnCount: Int, spacing: UInt, scaleFactor: Float) -> (any SpringboardThumbnailGridLayer)?
    /// With a shadow, the shadow is drawn with the text rather than as a layer shadow (`ECShadowTextLayer`).
    func makeTextLayer(withShadow: Bool) -> CATextLayer
    func setTextShadow(of textLayer: CATextLayer, color: CGColor, offset: CGSize, blur: CGFloat)
    /// 15's selection highlight: grey 232 ⁄ 255 that darkens what lies behind it.
    func applySelectionMaterial(to layer: CALayer)
}

package protocol SpringboardPageGridLayer: AnyObject {
    var layer: CALayer { get }
    /// Lays out and fills the items; Core Animation never calls it by itself.
    func layout()
}

package protocol SpringboardThumbnailGridLayer: AnyObject {
    var layer: CALayer { get }
    func layout()
    /// Asks the source for the item count and every item again.
    func invalidateContent()
    /// Shows the slot after the last item while an icon is held over the folder, or scrolls back to the top.
    func scroll(toAvailableSpace: Bool)
}

/// The window the springboard is drawn in, above every application window.
@MainActor
package protocol SpringboardWindow: AnyObject {
    var displayBounds: CGRect { get }
    var backingScaleFactor: CGFloat { get }
    var rootLayer: CALayer { get }
    func windowPoint(fromGlobalPoint globalPoint: CGPoint) -> CGPoint
    /// Puts the window on screen and takes the keyboard.
    func orderIn()
    /// Gives the keyboard back as the exit animation starts.
    func releaseKeyFocus()
    func orderOut()
}

package enum SpringboardHostSystem {
    /// Chooses this process's host. Call once, before the first show; a second call traps.
    package static func bootstrap(host: some SpringboardHost, layerFactory: some SpringboardLayerFactory)
}
```

`SpringboardDockGeometry`（Dock 的方向、厚度、刘海高度）与 `SpringboardIconStyle`（描述符模板、样式编号、给图标图片的合成滤镜名）是普通的值类型。今天直接调 `DockLayerFactory`、`DockEnvironment`、`WallpaperSnapshot` 等的地方，改为经 `SpringboardHostSystem` 取。

| 能力 | 注入版（`PayloadCore/Host/`） | 独立版（`StandaloneCore`） |
|---|---|---|
| 图层 | `ECGridLayer` 等 Dock 的类（不变） | 共用模块里自己画的等价实现 |
| 窗口与焦点 | `WALayerKitWindow`，SkyLight 设层级、抢焦点（不变） | `NSWindow`，层级 27，`makeKeyAndOrderFront` |
| Dock 几何 | 读 `DockBar`（不变） | 读 `com.apple.dock` 的 `tilesize` 与 `orientation`，套 15 的留白表；刘海取 `NSScreen.safeAreaInsets`。Dock 放不下、格子被缩小时读不到缩小后的大小，按设定的大小留（已知降级） |
| 壁纸 | 截壁纸窗口（不变） | 有录屏权限就截，否则读壁纸文件 |
| 图标样式 | 复制 Dock 的描述符（不变） | 按 SkyLight 的图标外观配置自己建 |
| 文本框 | 文本输入辅助进程，不可用时本地编辑（不变） | 本地编辑加 `NSTextInputClient` |
| 卸载 | Dock 的卸载器（不变） | 无 |
| 点在 Dock 上 | `DockBar` 的 `rect`（不变） | 恒为否：Dock 被盖住 |

### 自己画的图层

放在 `SpringboardCore`，只用 Core Animation 与 Core Text，行为逐条照 `ECLayerReuse.md`：

- **页面网格**（`ECGridLayer`）：一个 `masksToBounds` 的裁剪层里放条目层；格子宽高为 bounds 除以行列后取整；条目层由 source 的 `makeLayerForLayer:` 创建，插到最底下（越靠后的条目越低）；从左上角按行摆，行与列之间没有间距；数量只在创建时问一次——与今天每页内容一变就重建网格的用法一致。注入版今天为 15 关掉的那层裁剪，在这里同样关掉。
- **文件夹缩略图**（`ECImageGridLayer`）：条目层放在 `CAScrollLayer` 里，条目大小为格子减间距，失效后重新问数量；滚到末尾空位与滚回顶部的行为先补逆向再实现。
- **文字**（`ECTextLayer` / `ECShadowTextLayer`）：`CATextLayer` 子类，左对齐，画字前打开字体亚像素量化；带阴影的在 `draw(in:)` 里用 `setShadow(offset:blur:color:)` 把阴影与字一起画，偏移与模糊乘以 `contentsScale`，大于 1 时再乘 0.6。
- **选中高亮**（`setMaterialControl:3 appearance:1`）：灰 232/255 加 `kCAFilterPlusD`（plus-darker）合成滤镜。

校验分两处：单元测试按逆向笔记的布局规则逐项检查（格子大小、条目位置与层级、阴影换算），并用离屏 `CARenderer` 画出来比对像素；注入版的开发构建自检在 Dock 里把同一个图标、同一行标题用两套图层各画一遍，把最大像素差写进日志。页面与文件夹从此能在单元测试里用这套图层建出来，注入版自审时因为建不出 Dock 的网格类而没有测试 seam 的两条修复（弹出删除确认时还能翻页、页面重建后残留选中高亮）也能补上测试。

### 窗口、事件与焦点

- 窗口：无边框 `NSWindow` 子类，`canBecomeKey` 为真，`level` 为 27，`collectionBehavior` 含 `.canJoinAllSpaces`、`.fullScreenAuxiliary`、`.stationary`、`.ignoresCycle`；内容视图是层托管（layer-hosting）视图，根图层交给界面。按屏幕尺寸铺界面，不按根图层（实现说明里 0×0 根图层那一条同样适用）。
- 事件：窗口覆写 `sendEvent(_:)`，取 `NSEvent.cgEvent` 转成 `SpringboardInputEvent`（`Integration/SpringboardInputEvent+CoreGraphics.swift` 的转换随之搬进共用模块），交给 `SpringboardController.handle(_:)`；控制器没消费的再交给 `super`。
- 收起后调 `NSApp.hide(nil)`，焦点回到之前的 App；`applicationDidResignActive` 时收起。
- 看门狗：后台线程每秒向主线程打一次招呼，超过 3 秒没回应就调 SkyLight 的 `SLSOrderWindow` 把窗口移出屏幕（窗口服务器的调用不经 AppKit，可以在后台线程做），并写一条日志。

### 输入法

承载界面的视图实现 `NSTextInputClient`。按键先照现有规则分流（照 15 的 `-[ECSBLayer keyDown:]`：哪些键归搜索框、改名时全归改名框）；归文本框的交给 `inputContext.handleEvent(_:)`，组字期间所有键都先给输入法——与注入版转发给辅助进程的规则相同。

- `insertText(_:replacementRange:)` 写进当前框的 `SpringboardFieldEditor`；`doCommand(by:)` 按选择子读成现有的 `SpringboardTextEditingCommand`。
- `setMarkedText(_:selectedRange:replacementRange:)` 与 `unmarkText()`：`SpringboardFieldEditor` 新增组字中的文字，画在插入点、加下划线，不进入搜索匹配，提交后才进文字；组字时占位文字「搜索」让开（与注入版相同）。
- `firstRect(forCharacterRange:actualRange:)` 按几何规格算出框的位置，不从图层换算——打开文件夹与进场动画会让界面暂时缩放（与注入版辅助进程的做法相同）。

```swift
// LaunchpadAwakenerSpringboardCore
extension SpringboardFieldEditor {
    /// Text an input method is composing: drawn underlined at the insertion point, not yet in `text`.
    mutating func setMarkedText(_ markedText: String, selectedRange: NSRange)
    /// Commits the composed text as typed.
    mutating func unmarkText()
}
```

### 壁纸

1. `CGPreflightScreenCaptureAccess()` 为真（用户早已允许录屏）：照注入版截壁纸窗口。这个函数只查询、不弹窗。
2. 否则读 `NSWorkspace.shared.desktopImageURL(for:)` 指向的文件：普通图片直接读；动态 HEIC 按当前外观与时间取对应的那一帧；视频壁纸等读不出来的退到第 3 条。
3. 15 自带的径向渐变（注入版截不到时用的同一张）。

三种来源都放进同一个栅格化容器，套 15 的三个滤镜，与注入版相同。哪种来源生效写进日志。

### 图标样式

照逆向笔记 3.3「做法 B」：`+[SLSIconAppearanceConfiguration fetchCurrentIconAppearanceConfiguration]` 取 `iconAppearanceTheme` 与 `appearanceTheme`，按 3.2 的表建 `ISImageDescriptor` 并设 `appearance`、`appearanceVariant`、`background`，合成滤镜名也按表取；之后与注入版一样经 `IconServicesBridge` 取图。每个方法调用前照注入版的规矩按类型编码核对。着色样式的色值算法要先补逆向，查清之前着色样式退回默认样式，并写进已知降级。

### 打开、常驻与快捷键

```swift
// LaunchpadAwakenerStandaloneCore
@MainActor
public final class StandaloneLaunchpad {
    public static let shared: StandaloneLaunchpad

    /// Chooses the host, opens the library and registers the shortcut. Call once, at launch.
    public func start()
    public func show(reason: String)
    public func hide(reason: String)
}

// LaunchpadAwakenerStandalone (the app shell)
@main
struct LaunchpadApp: App {
    @NSApplicationDelegateAdaptor private var applicationDelegate: LaunchpadApplicationDelegate

    var body: some Scene {
        Settings { StandaloneSettingsView() }
    }
}
```

`LaunchpadApplicationDelegate` 在 `applicationDidFinishLaunching` 里调 `start()` 并显示（带 `--self-check` 时改为离屏自检），在 `applicationShouldHandleReopen` 里显示，在 `applicationDidResignActive` 里收起。随登录启动用 `SMAppService.mainApp`，首次启动时注册，设置里可以关掉。快捷键默认不设（15 的「显示 Launchpad」快捷键默认也是空的）。

### 布局库

```swift
LaunchpadLibrary.Configuration(
    databaseURL: applicationSupportDirectory.appending(path: "LaunchpadAwakener/Standalone/Launchpad.db"),
    // The injected build's library has 15's tables, so the legacy importer reads it as it reads 15's own.
    legacyDatabaseURL: injectedLibraryExists ? injectedLibraryURL : LegacyLaunchpadImporter.defaultLegacyDatabaseURL,
    …
)
```

两份来源都只读。导入失败时与注入版一样按 App 的发现结果从零生成布局。

## 替代方案考量

- **给独立版复制一份界面层另改**：起步快、不碰注入版，但每个修复都要做两遍，两份会越走越远。用户选择共用。
- **并进现有的 LaunchpadAwakener.app 作第二种模式**（SIP 关着注入、开着自己显示）：只装一个，但一个 App 要同时照顾两套入口、设置与权限状态。用户选择新做一个 App。
- **注入版也改用自己画的图层**：只剩一套画法，注入版少依赖 13 个 Dock 方法；但注入版的观感会变，要重新与 15 逐项对照。用户选择注入版保持不变。
- **两边共用同一个布局库**：一边整理另一边看得到，但要加「库被另一个进程改了就重读」的机制，两边同时开着时改动会互相覆盖。用户选择各用各的。
- **申请录屏权限截壁纸**：与 15 完全一致，但第一次要授权，macOS 15 起系统还会定期再弹窗确认。用户选择不弹权限、改读壁纸文件。
- **删除 App 改为移到废纸篓**：保留关闭按钮与确认气泡；但属于 root 的 App Store 应用要经访达，需要「自动化」权限并输入管理员密码。用户选择第一版不做。
- **第一版就接管 Launchpad 键、触发角或捏合**：更接近 15 的入口，但要「辅助功能」「输入监控」权限与权限引导，捏合还要私有的 MultitouchSupport。用户选择第一版只用 Dock 图标与快捷键。
- **用真正的 `NSTextField` 盖在界面上**：输入法行为完全是系统的；但它是窗口里的视图，不在图层树里，文件夹开合、进出场的缩放动画里不跟着动。界面层的文字、选区与光标已经画得完整，只差组字。
- **在同一进程里照注入版的辅助进程，把文本框放进离屏窗口再用 `CALayerHost` 贴进来**：一个进程同一时刻只有一个 key 窗口，界面窗口是 key 时，离屏窗口里的文本框拿不到输入法。
- **用 `CABackdropLayer` 实时模糊身后**：窗口在所有 App 之上，会把 App 的窗口一起模糊进来；15 只模糊壁纸。
- **用 `NSApplication.presentationOptions` 隐藏 Dock 与菜单栏**：系统会把 Dock 与菜单栏动画收起、收起界面时再弹回，15 没有这一下；高层级窗口直接盖住更接近 15。
- **独立 App 用 `dlopen` 载入 Dock 的可执行文件，借用它的 `EC*` 类**：两边会是完全相同的画法，但 dyld 的注释已经写明以后要禁止 `dlopen` 主可执行文件；载入会跑 Dock 的静态初始化，后果没查过；独立版也会重新绑回每个 Dock 构建；`ECShadowTextLayer` 与 `ECImageGridLayer` 在 27.2 里已经没人用，随时可能被删掉。没有实测。

## 影响

### 用户可见变化

- 多一个 App「Launchpad」：打开后盖住整块主屏幕，包括菜单栏与 Dock，界面与注入版相同；从它在 Dock 里的图标或设置里录好的快捷键打开。可以把它放到 Dock 上原来 Apps 图标的位置。
- 与注入版相比少了：Launchpad 键、Dock 的 Apps 图标、触发角与捏合手势都打不开它；打开时看不到 Dock，也拖不了图标到 Dock 上；抖动模式里没有关闭按钮；没有玻璃背景选项。
- 注入版的行为与外观不变。两个都装时各开各的：Launchpad 键与 Dock 的 Apps 图标打开注入版，独立版的图标打开独立版。

### 可发现性

- 装进 `/Applications/Launchpad.app` 后，从访达或 Spotlight 打开一次即可；它默认随登录启动，此后一直在后台运行，Dock 上有运行圆点。
- 界面打开时菜单栏被盖住，所以设置窗口有两个入口：Dock 图标的右键菜单里的「设置…」（`applicationDockMenu(_:)`），以及用 Cmd-Tab 切到它之后菜单栏里的「Launchpad › 设置…」。Cmd-Tab 应当不发「重新打开」事件，切过去只激活 App、不打开界面（推测，第 3 批在测试机上验证）。

### 数据与配置兼容

- 独立版只读注入版的库与 15 的旧库，不写它们；自己的库在 `~/Library/Application Support/LaunchpadAwakener/Standalone/Launchpad.db`。删掉这个文件，下次启动会重新导入。
- 15 的 `springboard-rows`、`springboard-columns`、`springboard-show-duration`、`springboard-hide-duration`、`springboard-page-duration` 在两边都生效，读的是同一份。
- 注入版的库、偏好、daemon 与辅助进程都不受影响。

### 平台与最低版本

- 独立版支持 macOS 26.0 起的任何构建，不需要构建档案，不需要关 SIP，产物是 arm64 与 x86_64。它仍用到几处系统私有接口（Core Animation 的滤镜、IconServices、SkyLight 的图标外观配置与截图），每处调用前照注入版的规矩按类型编码核对；新系统上对不上时只降级那一处（图标退回默认样式、背景退回渐变），界面照常打开。
- 只在主显示器上显示。
- 注入版的支持范围不变（26.0 到 27.2 的已登记构建）。

### 发布

- 只供作者自用：用开发者证书签名，不公证，不开沙盒，没有新的 entitlement。
- 不申请任何隐私权限。已经允许过录屏时会用到它截壁纸，但从不发起请求。
- 运行与验证只在测试机上做（27 用测试用的 MacBook，26 用虚拟机），与注入版相同；项目 `CLAUDE.md` 补上独立版的部署命令。

## 落地步骤

每一步都能单独构建通过、测试通过后提交；同批更新文档（项目 `CLAUDE.md` 的结构表与部署命令、实现说明、术语表）。前两批只在注入版上验证，确认注入版没有变化后才开始做独立 App。

1. **拆出共用模块，注入版行为不变**：
   1. ✅ 宿主接口：界面层的 Dock 调用全部改走 `SpringboardHostSystem`，payload 启动时选定 Dock 宿主。这一步不搬文件。
   2. ✅ 搬文件：`Data/`、`Interface/` 与事件转换移进 `LaunchpadAwakenerSpringboardCore`，跨模块用到的声明改为 `package`；测试改测新模块。
   3. ◐ 回归（27.2 已做，26 虚拟机待做）：单元测试全过；部署到 MacBook（27.2）与 26 虚拟机，日志里 23 个 Dock 方法签名全部吻合、两个 hook 装上、离屏自检的结果与改动前一致。
2. ✅ **自己画的图层**：先补逆向 `ECImageGridLayer` 的两个滚动方法；再写四种等价图层与单元测试（布局规则与像素比对）；注入版的离屏自检加上两套图层的像素比对，在 MacBook 上看日志。可以顺带给翻页与选中高亮补上测试。
3. ◐ **独立 App 的骨架**（MacBook 已验证，26 虚拟机待做）：新 target、`LaunchpadAwakenerStandaloneCore`、窗口与事件、打开与收起、常驻与随登录启动、开发期保险与看门狗、布局库与首次导入、偏好、壁纸、图标样式、`--self-check`。验证：单元测试（从注入版的库导入、壁纸来源的挑选、Dock 几何的换算）；在 MacBook 与 26 虚拟机上用 `--self-check` 做非交互验证，日志里的页数、文件夹数、App 数与注入版的库一致，壁纸来源与图标样式符合预期。
4. ◐ **输入法**（代码与单元测试完成，真机交互验证待用户）：`NSTextInputClient` 与编辑器的组字支持。验证：组字规则的单元测试；真机上的输入法要打开界面，属于交互操作，由用户进行或经用户同意后做。
5. **快捷键与设置窗口**：录制、注册、随登录启动的开关。

打开界面的效果、手感，以及 Cmd-Tab 切换器、音量提示、通知横幅这些系统窗口是否出现在独立版上方，都要打开界面才看得到，由用户进行或经用户同意后在 MacBook 上做。

落地时在注入版提案的决策日志里加一行，说明独立 App 另起了本提案。

**收尾时必须判断两件事**（判断结果写进决策日志，不允许沉默跳过）：

- **要不要配套专题文章**：宿主接口的契约（每个进程只选定一次、图层工厂在主线程之外读）与看门狗大概率要写进实现说明；有调用方契约才写使用指南。写了就登记到头部的「配套文档」。
- **有没有引入新术语**：「宿主」「注入版」「独立版」在本项目有特定含义，落地时登记进 `Documentations/Glossary.md`。

## 决策日志

| 日期 | 变更 | 说明 |
|------|------|------|
| 2026-11-08 | Created as Draft | 作者接受独立版把 Dock 一起盖住，注入版提案否决独立 App 的首要理由不再成立；调研确认数据层与界面层能够复用 |
| 2026-11-08 | 数据层与界面层两边共用，界面层用到 Dock 的地方改成宿主接口 | 用户选择；修一次两边都好，代价是要改动注入版并在测试机上回归 |
| 2026-11-08 | 只给作者自用，照用系统私有接口，不公证、不开沙盒 | 用户选择；求与 15 一致 |
| 2026-11-08 | 第一版从独立版在 Dock 里的图标或全局快捷键打开，不申请任何权限 | 用户选择；Launchpad 键、触发角、捏合要权限或私有框架，留作后续 |
| 2026-11-08 | 新做一个 App，不并进 LaunchpadAwakener.app | 用户选择；独立版不带 daemon、payload 与辅助进程 |
| 2026-11-08 | 独立版用自己的布局库，首次启动从注入版的库导入，没有就从 15 的旧库导入 | 用户选择；两边同时运行也不会互相覆盖 |
| 2026-11-08 | 注入版继续用 Dock 自己的图层类，自己画的图层只给独立版用 | 用户选择；注入版的观感不变，不必重新与 15 对照 |
| 2026-11-08 | 截壁纸只在用户已允许录屏时做，否则读壁纸文件，从不请求权限 | 用户选择 |
| 2026-11-08 | 第一版不做删除 App，抖动模式不显示关闭按钮 | 用户选择；系统卸载服务只服务带苹果私有权限的进程 |
| 2026-11-08 | 名叫 Launchpad、先沿用 LaunchpadAwakener 的图标；收起后常驻、默认随登录启动；失去激活即收起；快捷键默认不设；输入法在自己的视图里接；支持 26 与 27 的任何构建、只在主显示器上显示；先拆模块并回归注入版，再做独立 App | agent 提出的默认做法，用户确认 |
| 2026-11-08 | 界面照 15 给 Dock 留出位置，Dock 被盖住的那一条显示模糊壁纸 | 15 不论 Dock 是否自动隐藏都留（`LPSpringboard.showsDock` 恒为 YES），这样网格与 15 一致 |
| 2026-11-08 | 用户批准，开始实现 | 提案随功能分支 `feature/standalone-app` 提交，不先落到 `main`：`main` 的检出同时被别的会话使用 |
| 2026-11-08 | 宿主接口按现有调用的形状落地：图层工厂沿用 `DockLayerFactory` 的形状，网格对调用方就是 `CALayer`，由造它的工厂负责排版、填充与滚动；偏好、布局库配置与图层工厂作为宿主的 `nonisolated` 属性；玻璃背景、卸载器与托管文本框也经宿主取得，没有宿主时（单元测试）用一个什么都不提供的宿主 | 「详细设计」里网格各自一个协议的草图会让每处调用都多一层包装；照现有调用的形状，注入版这边只是把静态调用换成经宿主调用，最不容易改出行为差异 |
| 2026-11-08 | 第 1 批第 1 步完成：界面层的 Dock 调用全部改走宿主，`swift test` 201 个测试通过，`RunScript.sh` 构建的 daemon 与 payload 仍带 arm64e 切片 | 离屏自检里「玻璃不可用」与「玻璃排不出来」两条日志合成一条，因为是否可用现在由宿主判断 |
| 2026-11-08 | 第 1 批第 2 步完成：`Data/`、`Interface/` 与几处系统框架的桥接（Core Animation 私有滤镜、IconServices、SkyLight、截壁纸、剪贴板、启动 App）搬进 `LaunchpadAwakenerSpringboardCore`；测试拆成两个目标，Dock 构建档案的测试留在 payload 一侧 | 系统框架的桥接不认识 Dock，独立版也要用，所以跟着搬；payload 用到的十来个声明改为 `package`。`swift test` 合计 201 个测试照旧通过，`RunScript.sh` 构建的切片不变 |
| 2026-11-08 | 第 1 批第 3 步：MacBook（27.2）上回归通过；26 虚拟机当时没有运行，没做 | 先用 MacBook 上原有的构建（`main` 的最新构建）重启一次 Dock 取基线日志，再部署拆分后的构建：23 个方法签名吻合、两个 hook 装上，离屏自检的几何、网格、可删 App 数、新装标记数、壁纸尺寸与基线逐行一致，玻璃自检通过，Dock 没有崩溃。26 虚拟机要用户开起来后再补 |
| 2026-11-08 | 第 2 批完成：四种等价图层与选中材质照逆向写进共用模块，单元测试 10 个；没有宿主时（单元测试）的默认图层也换成它们，原有测试照旧通过。开发构建的离屏自检在 Dock 里逐项对照，MacBook（27.2）上页面网格、缩略图与滚动、选中材质、标题像素全部一致 | `ECImageGridLayer` 的滚动、选中材质与文字图层的绘制细节由逆向补齐，写在 `/Volumes/RE/Dock/27.2/Notes/ECLayerReuse.md` 第 5 节。给翻页与选中高亮补测试这一项没做，留作后续：它们在第 6 批自审时就有回归说明，这一批的目标是等价图层本身 |
| 2026-11-08 | 新增实现说明 `Internal/StandaloneLaunchpad.md`，登记为配套文档 | 宿主接口的形状、等价图层里看代码看不出的规则，下次维护会踩 |
| 2026-11-08 | 第 3 批：独立 App 的骨架完成。新 target `LaunchpadAwakenerStandalone`（产物 `Launchpad.app`）、模块 `LaunchpadAwakenerStandaloneCore` 及其测试目标；`RunScript.sh --scheme LaunchpadAwakenerStandalone` 只构建、从不启动它 | MacBook（27.2）上 `--self-check` 通过：从注入版的库导入 4 页、6 个文件夹、149 个 App，壁纸读文件、没弹权限，图标样式与 Dock 相同，窗口 27 层铺满屏幕，什么都没上屏。26 虚拟机仍没开，待补 |
| 2026-11-08 | 宿主加 `offersGlassBackground`：没有玻璃的宿主上，`springboard-background` 设成 `glass` 也显示 15 的模糊壁纸 | 退到替代模糊会把盖在下面的 App 窗口一起模糊进来，独立版的窗口在一切之上，这种退路没有意义 |
| 2026-11-08 | 独立版（bundle ID 前缀 `com.MxIris.LaunchpadAwakener.Launchpad`）加进标准排除名单；它与 27 的 `Apps.app` 作为「启动器」即使装着也从布局里拿掉，排除名单的其余部分只挡新加入 | 部署后注入版把独立版当新 App 加进了测试机的布局。第一版把「被排除就拿掉」用在整张名单上，结果测试机布局里本来就有的 App Cleaner & Uninstaller（15 的规则排除名字带 Uninstall 的）也被拿掉了；改为只对启动器生效，先写了能复现的测试（修前失败、修后通过）。测试机上被拿掉的那一项先备份库、再按 15 的排序触发器放回原位（第 3 页第 21 个），两边的库都回到 149 个 App |
| 2026-11-08 | 第 4 批：独立版的输入法完成。宿主多一项 `inputMethod`，界面层在原来转交托管文本框的几处把按键先交给它（改名与组字时每个键，搜索框里只是会打字的键）；组字中的文字记在共用的编辑模型里，显示时代替选区、加下划线，不进搜索与撤销；按下鼠标、改名结束、收起时当作打出的字收下 | 照提案用 `NSTextInputClient`：窗口的内容视图做第一响应者。没有在同进程里照搬辅助进程（真文本框加 `CALayerHost`）：同时只有一扇 key 窗口，还得用 AppKit 私有的 `_contextForLayerHosting`。注入版不受影响：它的宿主不给输入法，没有组字时两个框画出的字与改动前一模一样。单元测试 13 个；真机上打开界面属于交互操作，没有试输入法 |
