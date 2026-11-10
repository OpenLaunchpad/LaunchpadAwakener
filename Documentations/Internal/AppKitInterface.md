# 两个 App 的 AppKit 界面层：实现说明

> 配套提案见 [两个 App 的界面改用 AppKit 重写，不再用 SwiftUI](../Evolutions/0007-appkit-rewrite.md)。
> 本文记录实际落地的实现、与提案的差异，以及没在代码里写明、下一任维护者会踩到的决策。面向维护者。

## 背景与目标

注入版 App 与独立版 App 的界面原来是 SwiftUI，现在是 AppKit，用 UIFoundation、AppKitPlus、swift-navigation 与 SnapKit 写成，写法与 ApplicationScaffold 生成的项目一致。外观与行为以改写前 SwiftUI 版在测试 MacBook 上的截图为准，只有一处有意改变：手动打开注入版 App 时总会弹出控制面板，只有登录时的自动启动不弹。各窗口各自的业务决策仍记在[控制面板](ControlPanel.md)、[整理窗口](LaunchpadOrganizer.md)与[独立版](StandaloneLaunchpad.md)的实现说明里；本文只讲界面层本身。

## 模块结构

```
LaunchpadAwakener/main.swift                        # 注入版入口：建 ApplicationDelegate 并运行
LaunchpadAwakenerStandalone/main.swift              # 独立版入口：建 StandaloneApplicationDelegate 并运行
LaunchpadAwakenerPackage/Sources/
├── LaunchpadAwakenerSharedUI/                      # 两个 App 共用
│   ├── FormView.swift                              # 分组表单：FormView、FormSectionView、FormRowView
│   ├── ContentSizedWindowPlacement.swift           # 按内容定高，屏幕可见区域封顶
│   ├── ApplicationMainMenu.swift                   # SwiftUI 版那套主菜单
│   ├── ApplicationLaunch.swift                     # 这次是不是登录时启动
│   └── AppKitPlusTraitCheck.swift                  # UIFoundation 丢了 AppKitPlus trait 就编不过
├── LaunchpadAwakenerAppUI/                         # 注入版的界面，App target 只链接这一个产物
│   ├── Application/ApplicationDelegate.swift       # 控制器、两个窗口、菜单栏图标、启动流程
│   ├── Components/                                 # 状态点、颜色、跟踪窗口显隐的窗口控制器基类
│   ├── ControlPanel/                               # 控制面板：横幅、四节表单、窗口
│   ├── MenuBar/StatusItemController.swift          # 菜单栏图标与菜单
│   └── Organizer/                                  # 整理窗口：侧栏、列表、工具栏、菜单、对话框、拖放
├── LaunchpadAwakenerAppCore/                       # 新增 ReadinessPresentation、StatusLine、StatusTint、
│                                                   #   LaunchpadOrganizerViewModel
└── LaunchpadAwakenerStandaloneCore/StandaloneSettings.swift   # 独立版的设置窗口
```

## 关键设计决策

**外壳是 `main.swift`，delegate 上不写 `@main`。** AppKit 为 `@main` 合成的 `main()` 只调 `NSApplicationMain`，delegate 要靠主 nib 实例化，两个 App 都没有 nib，写 `@main` 的话 delegate 从不被调用。外壳自己建 delegate、交给 `NSApplication`，用 `withExtendedLifetime` 保活（`delegate` 属性是 weak 的）。App target 是 Swift 5 语言模式，`main.swift` 的顶层代码不算主线程隔离，所以包在 `MainActor.assumeIsolated` 里。

**App target 只链接 `LaunchpadAwakenerAppUI`。** 理由与改写前「只链接 AppCore」相同：多链接一个包产物，Xcode 有可能把 payload 框架也链进 App。AppCore 经 AppUI 间接链接。

**判断在 AppCore，界面层只排版、只转发。** 横幅的文案与图标（`ReadinessPresentation`）、两行状态的文字与颜色（`StatusLine`）、整理窗口的浏览、搜索、选中修正与拖放规则（`LaunchpadOrganizerViewModel`）都有单元测试；`StatusTint` 是「进行中、正常、要处理、出错、暂停、未设置」这样的角色，颜色在界面层定。

**控制器的开关绑不上 `UIBinding`。** AppCore 的控制器只有 `setEnabled(_:)`、`setEngaged(_:)` 这类方法，没有可写属性；swift-navigation 的 `UIBinding` 只能从可写的 key path 得到。所以状态到界面用 `observe {}`，用户的操作经控件动作调方法。整理窗口的视图模型属性可写，搜索框、侧栏选中、命名与归类两个 sheet 都直接绑定。

**视图模型自己修正选中，不靠观察布局。** 整理窗口的编辑一律经视图模型转给 `LaunchpadOrganizer`，每次刷新或编辑之后就地修正选中项。在 `observe {}` 里根据布局改选中会写入被观察的属性，而 `@Observable` 对相等的值也照样通知，闭包会永远重跑；修正选中时也只在值真的变了时才赋值。

**列表的多选手动同步。** swift-navigation 的表格选中绑定只做单选，列表是多选，所以在代理回调里把选中写回视图模型，在 `observe {}` 里按视图模型选行，用一个标志位挡掉程序自己选行引起的回写。

**列表的表格覆写了 `mouseDown(with:)`。** macOS 27 上表格改用 gesture recognizer 处理点击，点击不再让表格成为第一响应者，选中行画成灰色。覆写之后 AppKit 不装 recognizer，保留原来的点击跟踪；代价是触控板以外的直接触摸只能走鼠标模拟。

**表单的尺寸来自截图，并由测试锁住。** 在改写前的截图上量出：分组圆角 12 点、节与节之间 30 点、节标题与分组之间 10 点、行内边距 10 点（一行字的行 36 点，带一行说明的 52.5 点）、开关是 mini 尺寸（36×16）、分组底色是 `tertiarySystemFill`、行间分隔线是系统分隔线色的一半不透明度。分隔线要按当前外观解析出系统分隔线色、再把它的不透明度减半（深色下 12% 的白减到 6%），见 `FormRowView.separatorColor`。不能写 `separatorColor.withAlphaComponent(0.5)`：它把不透明度直接设成 50%，不是按比例缩小。第一版就是这样写的，线比 SwiftUI 版亮了好几倍。`FormRowView` 会把 `NSSwitch` 附件设成 mini、给 `NSStackView` 附件设水平抱紧——栈视图没有固有尺寸，不设的话会被拉宽，状态就挤到标题旁边去了。

**控制面板按完整内容定高。** 改写前的 SwiftUI 版在 MacBook 上开出来 670 点（含标题栏），最后一行被截掉：`sizeThatFits` 给表单的理想高度比内容矮。AppKit 版照代码注释的本意按完整内容定高，屏幕可见区域减 72 点封顶，所以比原来略高、屏幕放得下时不必滚动。同一次运行里关掉再开，窗口保持用户留下的位置与大小（窗口控制器一直持有窗口，与 SwiftUI 复用窗口的表现相同）；新的一次启动重新按内容定高。整理窗口的位置用 `organizer` 这个名字自动保存，与 SwiftUI 保存它时用的名字相同，原来存下的位置会沿用。

**Dock 图标跟着窗口走，由窗口控制器各自报告。** `ActivationTrackingWindowController` 在窗口显示时报告一次、在 `windowWillClose(_:)` 里报告一次，`ApplicationActivationPolicyController` 据此在 `.regular` 与 `.accessory` 之间切换。不在关闭时数 `NSApp.windows`：那一刻关闭中的窗口还在里面。

**只有登录时的启动才不弹控制面板。** 在 `applicationDidFinishLaunching(_:)` 里读当前 Apple 事件，是带 `keyAELaunchedAsLogInItem` 的 open-application 事件才算登录时启动（`ApplicationLaunch`）；过了这一刻当前事件就换了，所以必须在这里读。独立版原来私有的同一个判断已改用这一份。

**主菜单拼成 SwiftUI 那一套。** 用 UIFoundation 的 `MainMenu` 拼出：没有 File 菜单，Close 在 Window 菜单顶上，两个窗口的打开命令列在 Window 菜单里（窗口自己设 `isExcludedFromWindowsMenu`，免得列两遍）。关掉了窗口标签页（`allowsAutomaticWindowTabbing`），否则 View 与 Window 菜单会多出一组标签页命令。View 菜单在前台窗口没有工具栏、不能自定义工具栏、没有侧栏时隐藏对应的项。独立版「Settings…」的齿轮在 macOS 27 上要设 `preferredImageVisibility = .visible`：27 默认隐藏菜单项的图片。

**三个只在屏幕上才看得出的坑。**
- 菜单工具栏项（`NSMenuToolbarItem`）把菜单当下拉菜单用，第一项被当成按钮标题、不显示。「Move To」会丢掉「Page 1」、「Arrange」会丢掉「Sort by Name」，所以重建菜单时开头垫一个空项。
- AppKitPlus 的 `NSScrollViewController` 只对关掉了 `translatesAutoresizingMaskIntoConstraints` 的文档视图做 Auto Layout，否则按它的 frame 摆。按分类归类的分组列表因此一片空白；控制面板的表单没出事，只是因为 SnapKit 给它自身加约束时顺手关掉了这个开关。两处都改成显式关掉。
- swift-navigation 2.11.101 在窗口上用绑定弹 `NSAlert` 时，把 alert 的窗口直接挂成 sheet，跳过了 `beginSheetModal(for:)`，alert 没排版，露出 nib 里的占位控件（空按钮、帮助按钮、「<Do not show this message again>」）。解散确认改为在 `observe {}` 里直接 `beginSheetModal(for:)`，关闭时写回 nil。fork 的 `main` 上已重做了弹出 API，升到包含它的版本后可以改回绑定。

## 与提案的差异

- 主菜单用 UIFoundation 自带的 `MainMenu` 拼，没有另写提案里的 `StandardMainMenu`。
- `ApplicationDelegate` 随第 7 步与外壳一起落地，不在第 5 步；第 3 步没有让 SwiftUI 视图改调新类型，第 7 步直接删掉了它们。
- 解散文件夹的确认没走 swift-navigation 的 sheet 绑定，原因见上一节。
- 整理窗口列表里的重排交给 AppKitPlus 的 `NSTableViewDiffableReorderableDataSource`，不经 `dropOperation(of:onto:)`（提案写的是放下一律经它）：落点、整块移动与动画都由它做，AppKitPlus 有的不手写。拖到文件夹行上与拖到侧栏仍经 `dropOperation(of:onto:)`，细节见[整理窗口的实现说明](LaunchpadOrganizer.md)。
- 控制面板比改写前的 SwiftUI 版高一些（按完整内容定高）；独立版设置窗口高 3 点（快捷键录制框比 SwiftUI 版的高一点）。
- 注入版的 debug dylib 仍链接 SwiftUI.framework：导入 AppKitPlus 时它的 Swift 接口把 SwiftUI 一并自动链接进来。本仓库的代码里没有 `import SwiftUI`。

## 验证

- 单元测试：AppCore 的 `ReadinessPresentationTests`、`StatusLineTests`、`LaunchpadOrganizerViewModelTests`；SharedUI 的 `FormViewTests`（行高、节高、隐藏行与分隔线）、`ContentSizedWindowPlacementTests`、`ApplicationMainMenuTests`、`ApplicationLaunchTests`（用构造的 Apple 事件）。
- 构建：`RunScript.sh` 两个 scheme 都编过，daemon 与 payload 仍是 `x86_64 arm64 arm64e`，App 是 `x86_64 arm64`；旧 package 构建器下 UIFoundation 的编译参数带 `-DAppKitPlus`。
- 测试 MacBook（27.2）上与改写前的截图逐张对照：控制面板、菜单栏菜单、五个主菜单、整理窗口（侧栏、列表、搜索结果、选中文件夹、Arrange 与 Move To 菜单、改名 sheet、解散确认、按分类归类 sheet）、独立版设置窗口与它的 App 菜单。
- 测试 MacBook 上的交互：开机启动开着时用 `open` 手动打开 App，控制面板弹出（日志「Launched by the user」）；退回开关开、关与横幅的「Turn Back On」；自动再注入开、关；「Restart Dock」后换了 Dock 进程并自动再注入；关掉窗口后 App 变回 UIElement、没有 Dock 图标，再打开时回到前台并弹出控制面板；从菜单栏菜单打开整理窗口；列表改用可重排数据源后的四种拖放（同一文件夹里重排，录屏里看得到行在滑动；拖到文件夹行上放进去；拖到侧栏的页上；从搜索结果拖到侧栏的文件夹上），测前备份布局库，测后还原并在整理窗口里核对过。
- 没做：26 虚拟机上的对照（当时没开机）；登录时启动不弹控制面板只有单元测试覆盖，真机上要注销再登录才能验，这次经用户决定跳过；右键菜单、多选与「New Folder」sheet（发事件的工具没有右键和修饰键）；Dock 拒绝重排时列表退回原顺序（造不出 Dock 拒绝的情形）。

## 已知降级

- 经 ssh 用 `open` 启动时，系统不让这个菜单栏程序抢前台，窗口显示了但没激活，要点一下。用户自己双击打开时不受影响；改写前的 SwiftUI 版走的是同一段激活代码。
- swift-navigation 升级到包含新弹出 API 的版本之前，解散确认是手动弹出的。
