# Draft - 两个 App 的界面改用 AppKit 重写，不再用 SwiftUI

- **状态**: In Progress
- **作者**: JH
- **创建日期**: 2026-11-09
- **最后更新**: 2026-11-09
- **所属愿景**: 无
- **关联提案**: [0002 不注入 Dock 的独立版 Launchpad](0002-standalone-launchpad.md)、[0003 照 DockIconOverride 重做注入版 App 的控制面板](0003-app-control-panel.md)、[0005 在注入版 App 里整理 Launchpad 的布局](0005-launchpad-organizer.md)
- **实现分支 / PR**: `feature/appkit-rewrite`（worktree `.worktrees/LaunchpadAwakener-AppKitRewrite`）
- **配套文档**: [AppKit 界面层的实现说明](../Internal/AppKitInterface.md)；同步更新了[控制面板](../Internal/ControlPanel.md)、[整理窗口](../Internal/LaunchpadOrganizer.md)与[独立版](../Internal/StandaloneLaunchpad.md)的实现说明

## 摘要

注入版 App（LaunchpadAwakener）与独立版 App（Launchpad）的界面现在都是 SwiftUI：两个 App 的入口、控制面板、菜单栏菜单、整理窗口、独立版的设置窗口。本提案把它们全部改用 AppKit 重写，引入 UIFoundation、AppKitPlus、swift-navigation 与 SnapKit 四个库，写法与 ApplicationScaffold 脚手架生成的项目一致，仓库里不再有 `import SwiftUI`。界面代码从 Xcode 外壳搬进本地包：新建一个两个 App 共用的界面模块（分组表单、主菜单、启动来源的判断）和一个注入版 App 的界面模块；视图里的判断逻辑挪进 AppCore 并补单元测试。外观与行为保持现状，只有一处有意改变：开机启动打开时，手动打开 App 也会弹出控制面板，只有登录时的自动启动不弹。

## 动机

两个 App 的界面要统一到 AppKit 与 UIFoundation、AppKitPlus 这一套上，与脚手架生成的其他 App 用同一套写法。除此之外，SwiftUI 在这两个 App 里已经多次逼出绕行写法，或挡住了要修的问题：

- **开机启动打开时，手动打开 App 也不弹窗口。** [已裁决清单](../Internal/ReviewAdjudications.md) 2026-11-09 的一条记为「不修（本次）」：要分辨这次是不是登录时启动，得读启动时的 Apple Event，可 SwiftUI 在什么时机读 `defaultLaunchBehavior`（`LaunchpadAwakener/LaunchpadAwakenerApp.swift:45`）不清楚，只能按「开机启动打开就一律不弹」处理。AppKit 在 `applicationDidFinishLaunching(_:)` 里自己决定开不开窗口，这一条就能修。
- **App 已在运行时再打开它，弹窗口要绕一圈。** `openWindow` 只能从视图树里取，窗口关掉后视图树里只剩菜单栏图标，所以 delegate 只能给 `ApplicationReopenRequest` 的计数加一，再由菜单栏图标的 `onChange` 去开窗口（`LaunchpadAwakenerApp.swift:79-112`）。
- **独立版没法直接打开自己的设置窗口。** macOS 14 起 SwiftUI 的 Settings 场景不响应沿响应链发来的 `showSettingsWindow:`，`StandaloneSettings.show()` 只好在 App 菜单里找 ⌘, 那一项再模拟执行（`StandaloneCore/StandaloneSettingsView.swift:34-56`）。菜单一变它就失效，失效时只留一条日志。
- **窗口尺寸靠几个修饰符互相配合。** 控制面板曾因 `.fixedSize` 与 `.windowResizability(.contentSize)` 叠在一起，内容一高过屏幕窗口就伸到 Dock 后面，最后靠 `defaultWindowPlacement` 才压住（[控制面板实现说明](../Internal/ControlPanel.md)「窗口按内容开」一节）。
- **判断逻辑写在视图里，测试碰不到。** 横幅的文案、图标与配色（`MainView.swift:450-543`），Dock 构建与注入两行的文字和颜色（`MainView.swift:249-306`、`:371-399`），整理窗口的搜索结果、浏览记录、拖放规则与选中修正（`OrganizerView.swift:171-200`、`:355-463`、`:489-504`），都是 SwiftUI 视图的私有成员。[整理窗口的实现说明](../Internal/LaunchpadOrganizer.md)还记着一次 SwiftUI 的坑：侧栏的 tag 写成 `Optional` 后，怎么点都选不中。

## 前期调研

### 现状代码

| 位置 | 行数 | 内容 |
|---|---|---|
| `LaunchpadAwakener/LaunchpadAwakenerApp.swift` | 216 | `@main` 的 SwiftUI `App`：控制面板窗口、整理窗口、`MenuBarExtra`；`ApplicationDelegate` 持有全部控制器并跑启动流程 |
| `LaunchpadAwakener/MainView.swift` | 700 | 控制面板（横幅与四节分组表单）、菜单栏菜单 |
| `LaunchpadAwakener/OrganizerView.swift` | 707 | 整理窗口：`NavigationSplitView`、工具栏、右键菜单、拖放、两个 sheet、一个确认框 |
| `LaunchpadAwakenerStandalone/LaunchpadApp.swift` | 15 | 独立版入口，只有一个 Settings 场景 |
| `StandaloneCore/StandaloneSettingsView.swift` | 76 | 独立版设置：快捷键录制与「Open at Login」 |

AppCore 的控制器都是 `@Observable`，界面经 `@Environment` 拿到它们；它们本身不依赖 SwiftUI，这次不改接口。payload、daemon、文本输入辅助进程与 SpringboardCore 里没有 SwiftUI。注入版 App 的 target 只链接一个包产物（`LaunchpadAwakenerAppCore`），这是有意的：多链接一个产物，Xcode 有可能把 payload 框架也链进 App（见控制面板实现说明最后一条决策）。

### 四个库（版本是 2026-11-09 各自最新的 tag）

- **UIFoundation 0.44.0**：`XiblessViewController` / `XiblessWindowController`、`hierarchy {}`、`VStackView` / `HStackView`、`NSToolbar` 与 `NSMenu` 的 result builder。必须开 `AppKitPlus` trait：本包要直接链接 AppKitPlus，不开的话 UIFoundation 会另声明一份 `NSEdgeInsets: Equatable`，两个模块都可见时 `==` 有歧义（脚手架 `Package.swift` 的注释）。它的 `UIFoundationSettingsUI` 模块用 SwiftUI，这次不链接。
- **AppKitPlus 0.21.0**（二进制 xcframework，仓库 `AppKitPlus-Release`）：diffable data source、cell registration、`NSListContentConfiguration`、`NSContentUnavailableConfiguration`、`NSButton.Configuration`、拖放 interaction、`updateProperties()` 等。xcframework 只有一个 `macos-arm64_arm64e_x86_64` 切片，最低 macOS 12。**它自己链接 `SwiftUI.framework`**（查的是 0.20.0 的二进制，不是 weak 链接），所以两个 App 的进程里仍会加载 SwiftUI；本提案说的「不再用 SwiftUI」指本仓库的代码。framework 约 24 MB，两个 App 各嵌一份。
- **swift-navigation 2.11.101**（MxIris-Library-Forks 的 fork，2026-11-06）：AppKitNavigation 的 `observe {}`、`@UIBindable` / `UIBinding`，`NSSwitch` / `NSButton` / `NSMenuItem` 的 `bind(isOn:)`，表格与大纲的单选绑定，`present(item:style:)` 等。fork 的 `main` 上还有一批弹出 API 的重做（`NSWindow.sheet(isPresented:)` 能弹 `NSAlert`），还没有打 tag，这次只用 2.11.101 已有的接口。
- **SnapKit 6.0.0**。

### 其他事实

- **AppKit 的 `@main` 不会建 delegate。** 27.2 SDK 里 `NSApplicationDelegate.main()` 的实现只有 `exit(NSApplicationMain(...))`，delegate 要由主 nib 实例化。两个 App 都不用 nib，所以外壳要用 `main.swift` 自己建 delegate 并交给 `NSApplication`。
- **KeyboardShortcuts 3.1.0**（锁定的 revision `772133d`）有 AppKit 的录制控件 `KeyboardShortcuts.RecorderCocoa(for:)`，是 `NSSearchField` 的子类，独立版的设置不必用 SwiftUI 的 `Recorder`。
- **分辨「登录时启动」**：在 `applicationDidFinishLaunching(_:)` 里读 `NSAppleEventManager.shared().currentAppleEvent`，是 `kAEOpenApplication` 且 `keyAEPropData` 为 `keyAELaunchedAsLogInItem`。独立版已经这样写（`StandaloneCore/StandaloneLaunchpad.swift:174-179`），但没在真机登录时验证过；sindresorhus/LaunchAtLogin-Modern 用 `SMAppService.mainApp` 登记登录项，它的 `wasLaunchedAtLogin` 也是同一个判断。**推测**：对 `SMAppService.mainApp` 登记的登录项成立；要在测试 MacBook 上注销再登录确认。
- **macOS 27 上表格与大纲视图改用 gesture recognizer 处理点击**，点击不再让它们成为 first responder；27 SDK 下被别的视图盖住的系统控件收不到点击（`apple-os27-regressions`、`appkit-mouse-event-routing` 两个 skill）。整理窗口的两个列表、横幅里的按钮都要照这两条写。

### 没验证的风险

- **Xcode 27 的旧 package PIF 构建器认不认 package trait。** `RunScript.sh` 靠 `-IDEEnableNewPackagePIFBuilder=NO` 保住 x86_64 切片；UIFoundation 的 `AppKitPlus` trait 能不能经旧构建器传到编译参数里，没有先例（InjectionPlatform 用 UIFoundation 时没开 trait，x86_64 是靠排除解决的）。落地第 1 步先验证。

## 提议方案

1. **依赖**：本地包加 UIFoundation（开 `AppKitPlus` trait）、AppKitPlus、swift-navigation 的 fork、SnapKit，写法照脚手架的 `Package.swift`。
2. **模块**：
   - 新建 `LaunchpadAwakenerSharedUI`：两个 App 共用的 AppKit 部件——系统设置风格的分组表单（节、行、节标题）、按内容定高的窗口尺寸规则、用代码搭的标准主菜单、「是不是登录时启动」的判断。
   - 新建 `LaunchpadAwakenerAppUI`：注入版 App 的全部界面——`ApplicationDelegate`、控制面板、菜单栏图标与菜单、整理窗口。注入版 App 的 target 改为只链接它，AppCore 经它间接链接。
   - `LaunchpadAwakenerAppCore`：加上从视图里挪出来的判断逻辑——横幅的呈现、两行状态的文字与颜色、整理窗口的视图模型——并补单元测试。
   - `LaunchpadAwakenerStandaloneCore`：设置窗口改为 AppKit 的窗口控制器，直接打开；delegate 搭主菜单。
3. **外壳**：两个 Xcode target 的 Swift 代码各只剩一个 `main.swift`。删掉四个 SwiftUI 文件；`StandaloneSettingsView.swift` 换成 AppKit 的设置窗口，里面不属于 SwiftUI 的 `StandaloneSettings`、`StandaloneLoginItem` 原样搬过去。
4. **写法**：照脚手架——`Xibless*` 控制器加 `hierarchy {}` 与 SnapKit 布局；`observe {}` 跟踪 `@Observable` 控制器刷新界面（不与 AppKitPlus 的 `updateProperties()` 混用）；开关用 `bind(isOn:)`；sheet 用 `present(item:style:)`；列表用 AppKitPlus 的 diffable data source、cell registration 与 `NSListContentConfiguration`。
5. **外观**：控制面板与独立版设置尽量还原现在的分组表单。整理窗口按现有结构对应到 AppKit：左边侧栏（页下面挂文件夹），右边多选列表，工具栏里放搜索框。动手前先在两台测试机上给 SwiftUI 版截一组图，AppKit 版逐张对照。
6. **行为**：全部照旧，只改一处：只有登录时的自动启动不弹控制面板，从 Finder 或 Dock 手动打开都弹。

### 非目标

- 不改 AppCore 里控制器的接口与行为：启动流程、注入、自动再注入、闪退保护、状态刷新都不动。
- 不碰 payload、daemon、文本输入辅助进程、SpringboardCore，以及独立版里 Launchpad 本身的宿主。
- 整理窗口不加新功能，撤销、隐藏 App 仍是已知降级。
- 不照搬脚手架的七层模块与门面模块，只取它的依赖与写法；本项目仍按「哪个二进制链接它」分模块。
- 不加「禁止直接构造有对应 UIFoundation 子类的系统控件」的检查脚本。
- 不改 x86_64 的去留；第 1 步若发现旧 PIF 构建器不认 trait，停下来问用户。
- 不做本地化。

## 详细设计

### 模块与依赖

```swift
// LaunchpadAwakenerPackage/Package.swift — additions only
products: [
    // Linked by the app target, and the only product it links: AppCore comes with it.
    .library(name: "LaunchpadAwakenerAppUI", targets: ["LaunchpadAwakenerAppUI"]),
],
dependencies: [
    // The trait is required: this package links AppKitPlus itself, and without the trait UIFoundation
    // declares a second `NSEdgeInsets: Equatable`, so `==` turns ambiguous wherever both are visible.
    .package(url: "https://github.com/Mx-Iris/UIFoundation", from: "0.44.0", traits: ["AppKitPlus"]),
    // A binary framework with no API or ABI stability promised yet; read the release notes before updating.
    .package(url: "https://github.com/AppKitSupportProgram/AppKitPlus-Release", from: "0.21.0"),
    .package(url: "https://github.com/MxIris-Library-Forks/swift-navigation", from: "2.11.101"),
    .package(url: "https://github.com/SnapKit/SnapKit", .upToNextMajor(from: "6.0.0")),
],
targets: [
    // AppKit pieces both apps use: the grouped form, content-sized windows, the main menu, and whether
    // this launch is the one at login. Never linked by the payload or the daemon.
    .target(
        name: "LaunchpadAwakenerSharedUI",
        dependencies: [
            .product(name: "UIFoundation", package: "UIFoundation"),
            .product(name: "UIFoundationToolbox", package: "UIFoundation"),
            .product(name: "AppKitPlus", package: "AppKitPlus-Release"),
            .product(name: "AppKitNavigation", package: "swift-navigation"),
            .product(name: "SnapKit", package: "SnapKit"),
        ]
    ),
    // The injected app's interface: its delegate, the control panel, the menu bar item, the organizer.
    .target(
        name: "LaunchpadAwakenerAppUI",
        dependencies: [
            "LaunchpadAwakenerAppCore",
            "LaunchpadAwakenerSharedUI",
            // UIFoundation, UIFoundationToolbox, AppKitPlus, AppKitNavigation and SnapKit, as above.
        ]
    ),
    // LaunchpadAwakenerStandaloneCore gains LaunchpadAwakenerSharedUI and the same five products.
    .testTarget(name: "LaunchpadAwakenerSharedUITests", dependencies: ["LaunchpadAwakenerSharedUI"]),
]
```

### 外壳

```swift
// LaunchpadAwakener/main.swift
import AppKit
import LaunchpadAwakenerAppUI

// Not `@main` on the delegate: AppKit's synthesized `main()` only calls `NSApplicationMain`, which takes
// the delegate from the main nib, and this app has none. `NSApplication.delegate` is weak; this global
// keeps the delegate alive for the life of the process.
let applicationDelegate = ApplicationDelegate()
NSApplication.shared.delegate = applicationDelegate
_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
```

独立版的 `LaunchpadAwakenerStandalone/main.swift` 相同，建的是 `StandaloneApplicationDelegate`。

### 共用模块 `LaunchpadAwakenerSharedUI`

分组表单仿照 SwiftUI 的 `Form` + `.formStyle(.grouped)`：节有可选的图标与标题，行左边是标题（下面可带一行说明），右边是控件。尺寸与颜色以改写前的截图为准调整。

```swift
/// A System Settings–style grouped form: sections stacked in a scroll view, scrolling only when taller
/// than its frame.
public final class FormView: XiblessView {
    public init(sections: [FormSectionView])
    /// The height that shows every section without scrolling, for sizing the window to its content.
    public var fittingContentHeight: CGFloat { get }
}

/// One rounded group of rows under an optional header. A hidden row takes its separator with it.
public final class FormSectionView: XiblessView {
    public init(title: String? = nil, symbolName: String? = nil, rows: [FormRowView] = [])
    public var rows: [FormRowView] { get set }
    /// Colours the header, as the Last Error section's red one.
    public var headerTintColor: NSColor? { get set }
}

/// What `LabeledContent` and `Toggle` render as in a grouped `Form`: a title with an optional subtitle on
/// the leading side, an accessory on the trailing side.
public final class FormRowView: XiblessView {
    public init(title: String, subtitle: String? = nil, accessoryView: NSView? = nil)
    /// A row that is one view across its whole width, such as a warning with its button.
    public init(contentView: NSView)
    public var subtitle: String? { get set }
    public var subtitleTextColor: NSColor { get set }
}

/// Where a window sized to its content opens: as tall as the content, never taller than the screen's
/// visible area minus the title bar and a margin, never shorter than its minimum.
public struct ContentSizedWindowPlacement: Equatable {
    public init(fittingContentHeight: CGFloat, minimumContentHeight: CGFloat, visibleFrame: CGRect, screenEdgeAllowance: CGFloat)
    public var contentHeight: CGFloat { get }
}

/// The main menu both apps build in code: the application menu, Edit, View and Window, item for item
/// as SwiftUI built them.
public enum StandardMainMenu {
    public static func make(applicationName: String, settingsItem: NSMenuItem? = nil) -> NSMenu
}

/// How this launch came about.
public enum ApplicationLaunch {
    /// Whether the app was opened at login, as an item under Open at Login, rather than by the user.
    /// Only meaningful inside `applicationDidFinishLaunching(_:)`, while the open event is still current.
    @MainActor public static var wasLaunchedAtLogin: Bool { get }
    /// The rule, separated from the event manager for tests.
    static func isLaunchAtLogin(openEvent: NSAppleEventDescriptor?) -> Bool
}
```

### AppCore 的新增

从视图里挪出来的判断。它们只读控制器的状态、不碰视图，全部有单元测试。

```swift
/// What a status reads as at a glance: the banner, the status dots and their text.
public enum StatusTint: Sendable {
    case progress, positive, caution, critical, paused, neutral
}

/// How one ControlPanelReadiness reads in the banner. Moved from MainView.swift; `tint` replaces SwiftUI's `Color`.
public struct ReadinessPresentation: Equatable, Sendable {
    public let title: String
    public let nextStep: String
    public let symbolName: String
    public let tint: StatusTint
    /// The one-click next step, where there is one.
    public let action: ReadinessAction?
    public init(_ readiness: ControlPanelReadiness)
}

public enum ReadinessAction: Sendable {
    case installDaemon, openLoginItems, turnLaunchpadBackOn, injectNow, restartDock
    public var title: String { get }
}

/// One status line in the control panel: its text, the colour of its dot, its help tag.
public struct StatusLine: Equatable, Sendable {
    public let text: String
    public let tint: StatusTint
    public let help: String

    /// The Dock build row: which macOS the Dock ships with, and whether this build is supported.
    public static func dockBuild(reportedBy payload: PayloadInjectionCoordinator.ResidentPayload?) -> StatusLine
    /// The Dock row of the injection section: which process, and what its payload says about itself.
    public static func injection(
        injectedProcessIdentifiers: Set<pid_t>,
        residentPayloads: [PayloadInjectionCoordinator.ResidentPayload]
    ) -> StatusLine
}

extension StatusTint {
    public init(_ registrationStatus: SMAppService.Status)
}

/// The organizer window's state: what is shown, what is selected, where Back goes, and what a drop does.
@MainActor
@Observable
public final class LaunchpadOrganizerViewModel {
    public init(organizer: LaunchpadOrganizer)

    public var selectedContainer: LaunchpadOrganizer.Container?   // recorded for Back unless Back set it
    public var selectedItems: Set<LaunchpadOrganizer.ItemIdentifier>
    public var searchText: String
    public var canGoBack: Bool { get }
    /// The list: the selected page's or folder's items, or every matching application with where it is.
    public var rows: [Row] { get }
    public var title: String { get }
    public var subtitle: String { get }

    public func goBack()
    /// Double-click or Return: a folder opens; an application found by searching is shown where it is.
    public func open(_ itemIdentifiers: Set<LaunchpadOrganizer.ItemIdentifier>)
    /// Drops selected items the layout no longer has, and falls back to the first page.
    public func layoutDidChange()

    /// The whole selection when the dragged row is part of it, else just that row.
    public func draggedItems(startingWith itemIdentifier: LaunchpadOrganizer.ItemIdentifier) -> Set<LaunchpadOrganizer.ItemIdentifier>
    /// Nil when the drop is refused: nothing dragged, a row onto itself, an edit already running.
    public func dropOperation(of draggedItems: Set<LaunchpadOrganizer.ItemIdentifier>, onto target: DropTarget) -> DropOperation?
    public func perform(_ operation: DropOperation) async

    public var folderNaming: FolderNaming?
    public var folderBeingDissolved: LaunchpadOrganizer.Folder?
    public var categoryGrouping: CategoryGrouping?
}

extension LaunchpadOrganizerViewModel {
    public enum DropTarget: Equatable { case container(LaunchpadOrganizer.Container), row(LaunchpadOrganizer.ItemIdentifier), listBackground }
    public enum DropOperation: Equatable {
        case move(Set<LaunchpadOrganizer.ItemIdentifier>, to: LaunchpadOrganizer.MoveDestination)
        case arrange(LaunchpadOrganizer.Container, inOrder: [LaunchpadOrganizer.ItemIdentifier])
    }
}
```

拖放规则、浏览记录（最多 50 步，跳过已不在布局里的页或文件夹）、搜索结果的位置文字都照 `OrganizerView.swift` 现在的写法搬过来，不改语义。

### 注入版 App 的界面 `LaunchpadAwakenerAppUI`

对外只有 `ApplicationDelegate`，其余都是 `internal`。

- **`ApplicationDelegate`**：持有的控制器、启动流程、`applicationDidBecomeActive(_:)` 里重跑停下的启动流程，都照现在的写法搬过来。`applicationDidFinishLaunching(_:)` 里多做三件事：装主菜单、建菜单栏图标、`ApplicationLaunch.wasLaunchedAtLogin` 为假时打开控制面板。`applicationShouldHandleReopen(_:hasVisibleWindows:)` 直接打开控制面板，`ApplicationReopenRequest` 删掉。
- **窗口与 Dock 图标**：两个窗口控制器在窗口显示时调 `ApplicationActivationPolicyController.windowDidAppear()`，在 `windowWillClose(_:)` 里调 `windowDidDisappear()`，各自记着自己是否在屏上，不去数 `NSApp.windows`，所以「关闭中的窗口还在 `windows` 里」的问题不存在。这个控制器的注释随之改写。
- **控制面板**：`ControlPanelWindowController` 宽 520 点，高度由 `ContentSizedWindowPlacement` 定（最小 320 点，屏幕可见区域减 72 点封顶），只能竖向调整大小，退出时开着也不在下次启动时恢复。`ControlPanelViewController` 上面是横幅，下面是四节表单（General、Launchpad、Dock Injection、Last Error），每组一起变化的属性一个 `observe {}`；视图出现时启动每 3 秒一次的刷新任务，消失时取消。横幅：SF Symbol 用层级渲染，换图标时用 `setSymbolImage(_:contentTransition:)` 的替换动画；圆角背景与描边画在横幅自己的 layer 上，不放会盖住按钮的兄弟视图。
- **菜单栏**：`StatusItemController` 持有 `NSStatusItem`（`square.grid.3x3.fill` 模板图标），菜单项与现在一一对应，标题、可用状态与勾选状态经 `observe {}` 跟着控制器走。
- **整理窗口**：`OrganizerWindowController` 默认 900×620、最小 760×480。两个窗口记不记得上次的位置与大小，照第 1 步在测试机上记下的现状做。工具栏用 UIFoundation 的 builder：Back（⌘[）、Move To、New Folder、Move Out of Folder、Arrange，以及 `NSSearchToolbarItem`。窗口内容是 `NSSplitViewController`：
  - 侧栏是 source list 风格的 `NSOutlineView`：页是父项，文件夹是子项，默认全部展开，计数放在行尾。选中经 swift-navigation 的大纲单选绑定接到视图模型。
  - 列表是多选的 `NSTableView`：AppKitPlus 的 diffable data source 加 `NSListContentConfiguration`（28 点图标、标题，搜索时加一行位置）；双击与 Return 走 `open(_:)`；右键菜单作用于点中的行（点中的行在选中项里时作用于整个选中项）；加载中、不可用、空、无结果四种状态用 `NSContentUnavailableConfiguration`。照 macOS 27 的变化，内容变化后把 first responder 交给列表。
  - 拖动的内容用一个私有的剪贴板类型带编号，侧栏的行、列表的行和列表空白处都接受放下，放下做什么由 `dropOperation(of:onto:)` 决定。
  - 底部状态条显示「Updating Launchpad…」或最近一次错误；命名文件夹、按分类归类两个 sheet 经 `present(item:style: .sheet)` 弹出；解散文件夹用带破坏性按钮的 `NSAlert`，以 sheet 弹出。
  - 窗口在屏上时每 3 秒刷新一次状态与布局，与现在相同。

### 独立版 `LaunchpadAwakenerStandaloneCore`

- `StandaloneSettingsWindowController` + `StandaloneSettingsViewController`：一节表单两行——「Show Launchpad:」配 `KeyboardShortcuts.RecorderCocoa(for: .toggleLaunchpad)`，「Open at Login」配 `NSSwitch`。开关显示前从 `SMAppService.mainApp.status` 读，改动经 `StandaloneLoginItem.setOpensAtLogin(_:)` 写后再读回，与现在相同。宽 380 点，不可调整大小。
- `StandaloneSettings.show()`：先收起 Launchpad（不变），激活 App，再直接显示窗口控制器，不再去 App 菜单里找 ⌘, 那一项。
- `StandaloneApplicationDelegate` 在 `applicationDidFinishLaunching(_:)` 里装 `StandardMainMenu`（App 菜单带「Settings…」⌘,）；登录时启动的判断改用 `ApplicationLaunch.wasLaunchedAtLogin`，删掉私有的那一份。

## 替代方案考量

- **保留 SwiftUI 视图，用 `NSHostingView` 嵌进 AppKit 窗口。** 否：仍是 SwiftUI 代码，与目标相反。
- **只加 UIFoundation 与 AppKitPlus，用 AppKitPlus 的 `updateProperties()` 观察控制器，布局只用 stack 与系统 Auto Layout。** 依赖更少，但用户选了与脚手架一致的四个库，让写法与其他 App 统一。
- **界面代码留在 Xcode 外壳**（现在的 SwiftUI 视图与脚手架都是这样）。否：本项目约定代码都在本地包、外壳只放入口；放进包里，测试 target 也能链接。
- **控制面板改成简洁的原生排版**（节标题下面放两列 `NSGridView`，不画分组的圆角底）。省事，但看起来和现在不一样；用户要尽量还原。
- **主菜单用 MainMenu.xib**（脚手架的做法）。否：用代码搭与 UIFoundation 不用 xib 的写法一致，diff 可读，两个 App 共用一份。
- **行为严格不变，「手动打开不弹窗口」另开改动修。** 否：改用 AppKit 后，判断登录时启动与否工作量一样，用户决定这次一起修。
- **照搬脚手架的七层模块与门面模块。** 否：本项目按「哪个二进制链接它」分模块，加两个模块就够，不必为界面再分层。

## 影响

### 用户可见变化

- 控制面板、菜单栏菜单、整理窗口、独立版设置窗口的外观与操作保持现状，以两台测试机上改写前后的截图对照为准。对不上而又不打算改的，写进实现说明的「与提案的差异」。
- 有意的改变：开机启动打开时，从 Finder 或 Dock 手动打开注入版 App 会弹出控制面板；只有登录时的自动启动不弹。
- 主菜单改由代码搭，菜单项照改写前的截图逐项对齐。

### 可发现性

没有新功能，不涉及。

### 数据与配置兼容

- 偏好设置的键不变：自动再注入、开机启动的默认值、独立版的首次登记、KeyboardShortcuts 存的快捷键。
- 登录项与 daemon 的登记不变：bundle ID、服务名都没动。
- SwiftUI 若存过窗口的位置，改写后不再读取，窗口第一次按默认位置打开。

### 平台与最低版本

不变：注入版 App 的部署目标 macOS 15.0（功能上只支持 26 与 27），独立版 26.0。四个库的最低版本都不高于 macOS 12。x86_64 与 arm64 切片照旧保留，前提是第 1 步验证通过。

### 发布

不需要新的权限或 entitlement。两个 App 各嵌一份 AppKitPlus.framework（约 24 MB），随 App 一起签名，公证不受影响。项目没有自动更新。

## 落地步骤

每一步单独构建通过、单独提交。构建一律经 `queued-build ./RunScript.sh`，两个 scheme 都要编，daemon 与 payload 的切片校验仍须是 `x86_64 arm64 arm64e`。

1. **截改写前的对照图。**（MacBook 已截；26 虚拟机当时没开机，留到部署 AppKit 版之前补截）部署前先看 MacBook 上跑的是谁的构建。把当前 `main` 的两个 App 部署到 MacBook（27.2）与 26 虚拟机，截控制面板、菜单栏菜单、主菜单、整理窗口（侧栏、列表、搜索、右键菜单、两个 sheet、确认框）、独立版设置窗口与主菜单，并记下两个窗口关掉再开时是否回到上次的位置与大小。图存在仓库以外的临时目录。
2. **依赖与空模块。**（已完成）加四个库、两个新模块与测试 target，App target 改为只链接 `LaunchpadAwakenerAppUI`（第 7 步之前，SwiftUI 外壳经它拿到 AppCore），这样这一步就用 Xcode 编到了 UIFoundation。确认 trait 在旧 PIF 构建器下生效（`LayerBackedView` 继承自 `NSLayerBackedView`，没有 `NSEdgeInsets` 的 `==` 歧义），不生效就停下来问用户。
3. **AppCore。**（已完成）横幅呈现、两行状态、整理窗口的视图模型，加单元测试；SwiftUI 视图暂时改调它们，行为不变。
4. **共用模块。**（已完成）分组表单、窗口尺寸规则、标准主菜单、登录时启动的判断，加单元测试。
5. **注入版 App 的控制面板、菜单栏与 delegate。**（已完成；delegate 挪到第 7 步）
6. **整理窗口。**（已完成）
7. **注入版 App 的外壳换成 `main.swift`**（已完成），删掉三个 SwiftUI 文件。
8. **独立版**（已完成）：设置窗口、主菜单、`main.swift`，删掉两个 SwiftUI 文件。
9. **测试机验证。**（MacBook 已完成；26 虚拟机还没做；注销再登录经用户决定跳过） 两台机器上逐张对照截图，调到一致；交互逐项过一遍：三个开关（测后还原）、立即注入、重启 Dock、横幅按钮、菜单栏每一项，整理窗口的每种编辑与拖放（测前备份布局库，测后还原）。MacBook 上打开开机启动后注销，**由用户在 MacBook 上手动登录**（它没开自动登录，ssh 进不了登录窗口），确认控制面板不弹；再退出后从 Finder 打开，确认弹出。独立版：从 Dock 菜单与 ⌘, 打开设置，录一个快捷键再清掉，「Open at Login」测后还原。
10. **文档。**（已完成） 更新控制面板、整理窗口、独立版三份实现说明，项目 `CLAUDE.md` 的结构表与构建说明，已裁决清单里「手动打开不弹窗口」那条改判为已修，文档索引。

**收尾时必须判断两件事**（判断结果写进决策日志，不允许沉默跳过）：

- **要不要配套专题文章** —— 分组表单的尺寸取自截图对照、`main.swift` 而不是 `@main` 这类决策，是写进现有实现说明，还是单独写一份 AppKit 界面层的实现说明。
- **有没有引入新术语** —— 有就同批次登记进 `Documentations/Glossary.md`。

## 决策日志

| 日期 | 变更 | 说明 |
|------|------|------|
| 2026-11-09 | Created as Draft | 用户要求用 UIFoundation 与 AppKitPlus 把 App 端改写成 AppKit，不再有 SwiftUI。整个界面层重写、加依赖，属于大型重构，走完整档：两轮澄清提问后写成本提案。 |
| 2026-11-09 | 范围包括独立版 | 两个 App 都改，仓库里不留 `import SwiftUI`；独立版顺带去掉模拟执行菜单项来打开设置的绕法。只改注入版的方案被否。 |
| 2026-11-09 | 四个库都加 | 与脚手架一致：UIFoundation、AppKitPlus、swift-navigation、SnapKit。只加前两个、靠 `updateProperties()` 观察的方案被否。 |
| 2026-11-09 | 界面代码进本地包 | 新建注入版 App 的界面模块，外壳只留入口，符合项目「代码都在本地包」的约定。留在外壳的方案被否。 |
| 2026-11-09 | 外观尽量还原 | 控制面板照现在的分组表单还原，要自己拼分组的圆角底与行间分隔线。简洁原生排版的方案被否。 |
| 2026-11-09 | 手动打开不弹窗口的问题这次一起修 | 改用 AppKit 后，判断登录时启动与否工作量相同；验证要在测试 MacBook 上注销再登录。 |
| 2026-11-09 | 两台测试机都做界面验证 | MacBook（27.2）与 26 虚拟机上都截图、点击，先给 SwiftUI 版截图再逐张对照；整理窗口测完还原布局。 |
| 2026-11-09 | 其余做法经用户同意 | 两个 App 共用一个界面模块；独立版设置留在 StandaloneCore；写法照脚手架；菜单栏用 `NSStatusItem`，主菜单用代码搭；整理窗口为侧栏加多选列表加搜索框；判断逻辑进 AppCore 并补测试。 |
| 2026-11-09 | Accepted | 用户批准，开始实现。功能分支 `feature/appkit-rewrite`，从 `main` 切出。 |
| 2026-11-09 | In Progress；第 1 步先截 MacBook | 26 虚拟机没开机。它上面装的仍是 SwiftUI 版，所以对照图留到给它部署 AppKit 版之前再截，先截 MacBook。 |
| 2026-11-09 | 旧 PIF 构建器认 trait | 第 2 步实测：`-IDEEnableNewPackagePIFBuilder=NO` 下 UIFoundation 的编译参数带 `-DAppKitPlus`，daemon 与 payload 仍是 `x86_64 arm64 arm64e`，App 是 `x86_64 arm64`，嵌了 AppKitPlus.framework。另加一个只在编译期起作用的检查（`LayerBackedView` 必须是 `NSLayerBackedView` 的子类），trait 丢了就编不过，而不是悄悄换掉基类。风险解除，x86_64 不受影响。 |
| 2026-11-09 | 主菜单用 UIFoundation 的 `MainMenu` | UIFoundation 自带按 Xcode 模板搭标准主菜单的 `MainMenu`，各项可按标识增删，详细设计里打算自己写的 `StandardMainMenu` 不再需要。两个 App 的菜单项照改写前的截图对齐：没有 File 菜单，Close 在 Window 菜单里，Window 菜单列出两个窗口，Help 菜单只有「<App> Help」。 |
| 2026-11-09 | 控制面板按完整内容定高 | 改写前的 SwiftUI 版在 MacBook 上开出来是 670 点高（含标题栏），最后一行被截掉、要滚动：`sizeThatFits` 给表单的理想高度比内容矮。代码注释的意图是「按内容开、不超过屏幕可见区域」，AppKit 版照意图按完整内容定高，屏幕放得下时不必滚动。 |
| 2026-11-09 | 第 3 步不改 SwiftUI 视图 | 横幅呈现、状态行与整理窗口的视图模型都进了 AppCore 并有测试；原来的 SwiftUI 视图第 7 步整个删掉，这期间不改调新类型，省掉一次马上作废的改动。视图模型的编辑都经它转给 `LaunchpadOrganizer`，每次编辑或刷新之后就地修正选中项，不靠观察布局的变化来触发：观察闭包里写被观察的属性会让它不停重跑。整理窗口测试用的样例布局与替身通道改成测试 target 内共用。 |
| 2026-11-09 | 表单的尺寸取自改写前的截图 | 在 MacBook 的截图上量出：分组圆角 12 点，节与节之间 30 点，节标题与分组之间 10 点，行内边距 10 点（一行字的行 36 点高，带一行说明的 52.5 点），分隔线 1 点、缩进 10 点。分组底色取 `tertiarySystemFill`（深色下与截图同为 4.7% 的白），分隔线取系统分隔线色的一半不透明度（与截图同为约 6% 的白）。这些数写进了共用模块的测试。滚动交给 AppKitPlus 的 `NSScrollViewController`，表单本身只负责排列。 |
| 2026-11-09 | delegate 与外壳切换同一步 | `ApplicationDelegate` 要引用整理窗口，放在第 5 步就得留个空壳才能单独编过；改为第 7 步与 `main.swift` 一起落地。第 5 步只交控制面板与菜单栏。控制器的开关只有 `setEnabled(_:)` 这样的方法、没有可写属性，`UIBinding` 绑不上：界面跟着状态走用 `observe {}`，用户的操作经动作调方法。菜单项的闭包动作用 AppKitPlus 的 `NSAction`。 |
| 2026-11-09 | 整理窗口的几处取舍 | 侧栏用 AppKitPlus 的大纲 diffable 数据源，子类里覆盖它公开的 `validateDrop` / `acceptDrop` 接受放下；列表用 AppKit 自带的表格 diffable 数据源加子类，放在文件夹行上是放进文件夹，放在两行之间是插到下一行前面，与 SwiftUI 版的规则一致。列表是多选，swift-navigation 的选中绑定只做单选，所以选中在代理回调与 `observe {}` 之间手动同步，用标志位挡回声。解散文件夹的确认用 swift-navigation 的 `AlertState` 生成 `NSAlert`，回车不触发破坏性的「Dissolve」。表格子类覆写 `mouseDown(with:)` 保留 AppKit 原来的点击跟踪，避开 macOS 27 上点击不让表格成为第一响应者、选中行发灰的问题。整理窗口沿用 SwiftUI 存窗口位置用的名字 `organizer`。 |
| 2026-11-09 | `main.swift` 包在 `MainActor.assumeIsolated` 里 | App target 是 Swift 5 语言模式，`main.swift` 的顶层代码不算主线程隔离，不能直接调 `@MainActor` 的 delegate 构造器；进程从这里起就在主线程，包一层即可。delegate 靠 `withExtendedLifetime` 活到 `NSApplicationMain` 返回，也就是进程结束。 |
| 2026-11-09 | 进程里的 SwiftUI 来自依赖 | 改写后本仓库的代码不再导入 SwiftUI。App 的 debug dylib 仍链接 SwiftUI.framework：导入 AppKitPlus 时它的 Swift 接口把 SwiftUI 一并自动链接进来，与提案前期调研的判断一致。 |
| 2026-11-09 | 独立版的设置窗口直接打开 | 设置窗口改成 AppKit 的窗口控制器，「Settings…」与 Dock 菜单都直接打开它，不再去 App 菜单里找 ⌘, 那一项模拟执行。录制快捷键用 KeyboardShortcuts 的 `RecorderCocoa`。登录时启动的判断改用共用模块的 `ApplicationLaunch`，删掉独立版私有的一份。构建日志里 x86_64 的一条 `points before section` 链接警告来自 FrameworkToolbox 的目标文件，改写前 `main` 的 payload 构建里就有，与这次无关。 |
| 2026-11-09 | MacBook 上逐张对照后的修正 | 部署到 MacBook（27.2）与改写前的截图对照，改了这些：表单里的开关用 mini 尺寸（SwiftUI 的分组表单是 36×16 点）；作为附件的 `NSStackView` 设水平抱紧，状态才靠右；横幅要显式打开四边描边，图标列定为 33 点高；整理窗口工具栏只显示图标、「New Folder」与「Move Out of Folder」合成一组、侧栏按钮挪到侧栏右缘；侧栏用 medium 行高、强调色图标、普通数字计数；列表行至少 38 点；关掉窗口标签页（SwiftUI 的窗口不分标签，否则 View 与 Window 菜单会多出标签页命令）；View 菜单在没有侧栏或不能自定义工具栏时隐藏对应项；独立版「Settings…」的齿轮在 macOS 27 上要设 `preferredImageVisibility = .visible` 才显示。 |
| 2026-11-09 | 三个只在真机上才看得出的坑 | 菜单工具栏项把菜单当下拉菜单用，第一项被当成标题不显示，「Move To」会丢掉「Page 1」、「Arrange」会丢掉「Sort by Name」，所以开头垫一个空项。`NSScrollViewController` 只对关掉自动转换约束的文档视图做 Auto Layout，按分类归类的列表因此是空白，表单则是碰巧被 SnapKit 关掉了，两处都改成显式设置。swift-navigation 2.11.101 在窗口上弹 `NSAlert` 时跳过了 `beginSheetModal(for:)`，alert 没排版、露出 nib 里的占位控件，解散确认改为直接调 `beginSheetModal(for:)`。 |
| 2026-11-09 | 文档 | 新写 [AppKit 界面层的实现说明](../Internal/AppKitInterface.md)：外壳与模块、表单尺寸、主菜单、登录时启动的判断，以及只在真机上才看得出的三个坑，都是下一任维护者会踩、代码里看不出来的决策。控制面板、整理窗口、独立版三份实现说明改了结构表与过时的 SwiftUI 段落；已裁决清单里「手动打开不弹窗口」改判为已修；项目 `CLAUDE.md` 改了结构表并加了「界面」一节。没有新术语，术语表不动。这是 App，不需要使用指南。 |
| 2026-11-09 | 实现完成，待用户看过后收尾 | MacBook（27.2）上对照与交互都做完了。还没做：26 虚拟机上的对照（虚拟机没开机），以及注销再登录确认登录时启动不弹控制面板（MacBook 没开自动登录，要用户手动登录）。 |
| 2026-11-09 | 注销再登录的真机验证这次不做 | 用户决定跳过。手动打开会弹控制面板已在 MacBook 上验过；登录时不弹这一半由 `ApplicationLaunchTests` 用构造的 Apple 事件覆盖，真机上没验证过。26 虚拟机上的对照等用户开机后再做；合进 main 要等主检出里另一份草案的未提交改动处理完。 |
