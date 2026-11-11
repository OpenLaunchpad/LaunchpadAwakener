# 独立版 Launchpad：实现说明

> 配套提案见 [不注入 Dock 的独立版 Launchpad](../Evolutions/0002-standalone-launchpad.md)。
> 本文记录实际落地的实现、与提案的差异，以及当前覆盖范围与已知降级。面向维护者。
> 注入版的实现说明见 [Launchpad 复刻：实现说明](LaunchpadReplica.md)，两版共用的界面层细节都在那里。

## 背景与目标

独立版是一个普通的 App，自己开一扇盖住 Dock 所在那块屏幕的窗口，画出与注入版相同的 macOS 15 Launchpad，不注入 Dock、不需要关 SIP。两版共用 `LaunchpadAwakenerSpringboardCore` 里的布局库与界面层；界面层要的窗口、图层类、壁纸、图标样式这些，经宿主接口 `SpringboardHost` 向各自的宿主要（见[术语表](../Glossary.md)「Host（宿主）」）。

注入版的包里带着一份压缩的独立版（`Contents/Resources/Launchpad.zip`）。SIP 没关时注入版不注入，控制面板一键把它装进「应用程序」并打开，见[控制面板的实现说明](ControlPanel.md)。

## 关键设计决策

**宿主照现有调用的形状抽出，注入版只是把静态调用换成经宿主调用。** 图层工厂沿用 `DockLayerFactory` 的形状：网格对调用方就是一个 `CALayer`，排版、填充与滚动都交回造它的工厂。曾考虑给页面网格与缩略图网格各定一个协议，那样每处调用都要多包一层，注入版这边的改动面也大得多。宿主在每个进程里只选定一次（`SpringboardHostSystem.bootstrap(host:)`），在 payload 里是装 hook 之前、在后台线程上选的，所以宿主本身是 `Sendable` 的，界面层在主线程以外要读的三样（图层工厂、偏好、布局库配置）是它的 `nonisolated` 属性：Core Animation 在自己的线程上复制图层，图层的初始化方法会建文字图层。没有选定宿主时（单元测试）用 `DetachedSpringboardHost`：不给窗口、壁纸、玻璃、托管文本框与卸载器，Dock 取默认大小，图层用下文的等价图层。

**等价图层逐条照 Dock 的二进制写，在 Dock 里逐像素对照过。** 独立版拿不到 Dock 的 `ECGridLayer`、`ECImageGridLayer`、`ECTextLayer` 与 `ECShadowTextLayer`，也没有 Dock 给 `CALayer` 加的 `setMaterialControl:appearance:`，于是在共用模块里用纯 Core Animation 重写（`SpringboardReplicaLayers.swift`）。每个取整方式、子图层的插入顺序、哪些属性设了哪些没设，都取自 27.2 的 Dock（`/Volumes/RE/Dock/27.2/Notes/ECLayerReuse.md` 1.1、1.3、1.4 与第 5 节）。几处不看二进制就会写错的地方：

- 网格新建的条目层一律插到最底下，所以第一项画在最上面。
- 缩略图网格建的条目层与 App 一样多，不封顶到 9 个，多出的行在滚动层里排到下方、被裁掉。滚到「下一个空位」时，最后一行是满的要再多滚一行；不满一屏的什么也不做。
- 缩略图网格的滚动层左移、上移半个间距，这半个间距截断成整点；摆放条目时用的半个间距却是精确的。
- 带阴影的文字把阴影画在字里，偏移与模糊以点存、画时乘内容缩放，大于 1 时再乘 0.6；交给 Core Animation 的 `shadowOffset` 结果不同。阴影色默认是 Generic Gray 的黑。
- 选中高亮的灰是 sRGB 的 232/255，配 `plusD` 合成滤镜，两个参数之外什么都不读。

这些图层不碰 `CATransaction`：动不动画由调用方当前的事务决定，与 Dock 的类一样。开发构建的离屏自检在 Dock 里把同一页网格、同一组缩略图、选中材质和同一行标题用两套各做一遍，逐项比对并写进日志（`SpringboardReplicaComparison`）；注入版仍然只用 Dock 自己的类。

**窗口盖住一切，事件交给与注入版相同的控制器。** 无边框 `NSWindow`，层级 27（15 的 Launchpad 窗口所在，高于菜单栏的 24 与 Dock 的 20），在所有空间与全屏 App 之上都能出现（`.canJoinAllSpaces`、`.fullScreenAuxiliary`）。内容视图是层托管视图，根图层整个交给界面，与 Dock 的 `WALayerKitWindow` 一样。窗口覆写 `sendEvent(_:)`，把每个事件的 `cgEvent` 转成 `SpringboardInputEvent` 交给 `SpringboardController.handle(_:)`，没被拿走的才照常派发；所以按键、点击、滚动、翻页的规则与注入版一字不差。Dock 被盖住，宿主的 `isOnDock` 恒为否。宿主也不改 Dock 的显隐：注入版照 15 在文件夹开着时让 Dock 滑走，这里的窗口本来就把 Dock 那块地方让给了面板。

**焦点：打开时激活自己，退场一开始就把自己藏起来交还。** `orderIn` 先 `NSApp.activate()` 再 `makeKeyAndOrderFront`；从别的 App 按快捷键打开时，这一刻 App 还没激活、窗口不是 key，等激活完成 AppKit 会让它成为 key、内容视图仍是第一响应者，不用另外处理。`releaseKeyFocus` 调 `NSApp.hide(nil)`：与 Command-H 一样，系统随即激活之前那个 App，这正是 15「退场一开始就交还输入」的效果；窗口设了 `canHide = false`，不随 App 藏起来，留到退场动画结束才撤下。起初用的是 `NSApp.deactivate()`，在 27 上它不交出激活——退场时这扇窗口还在最前面，App 照样是前台，菜单栏还是它的；下次显示前先 `unhideWithoutActivation()`。两种收起不交还：从界面里打开了 App（那个 App 自己拿焦点，再交给之前的 App 会抢它的），以及打开设置（焦点留给设置窗口），宿主接口为此给 `releaseKeyFocus` 加了 `returningToPreviousApplication`，注入版不看它。代价是设置窗口开着时收起界面，设置窗口会随 App 一起藏起来，下次打开 App 时再出现。App 失去激活（Cmd-Tab、点到别处）就收起；点 Dock 图标走 `applicationShouldHandleReopen` 打开；登录时由「打开时登录」启动的那一次不打开，等第一次点图标（看打开事件的 `keyAELaunchedAsLogInItem`）。

**Dock 在哪块屏，问窗口服务器。** 两版都照 15 开在 Dock 所在的那块屏（见[注入版实现说明](LaunchpadReplica.md)「开在 Dock 所在的那块屏」）。独立版读不到 Dock 的 `DockBar`，改问窗口服务器给 Dock 记的矩形——`SLSGetDockRectWithOrientation`，AppKit 正是用它从屏幕的可用区域里扣掉 Dock——取矩形中心所在的屏；Dock 藏到边外、中心不在任何屏上时，取离中心最近、且不超过 Dock 自身长度的那块屏；都没有就用主显示器。矩形是左上角原点的全局坐标：单块屏上光看「落在哪块屏」分不出两种原点，所以有一条测试在开发机上把它换成 AppKit 坐标，核对它正好接在 Dock 那块屏可用区域的下沿。刘海高度取那块屏的 `safeAreaInsets.top`。显示期间拦不住 Dock 换屏，但窗口本来就盖着 Dock，换了也只是界面留在原屏，下次打开才跟过去；显示器一变就收起这一条是两版共用的。

**壁纸绝不申请权限。** 截壁纸窗口要「录屏」权限，所以只在 `CGPreflightScreenCaptureAccess()` 为真时才截——这个函数只查询、不弹窗；截的是 Dock 自己的壁纸窗口时要传 Dock 的进程号，不再是本进程。否则读 `NSWorkspace.desktopImageURL(for:)` 的文件：动态 HEIC 按 XMP 里 `apple_desktop:` 的日程取当前那一张——`apr` 与 `solar` 的 `ap` 按浅色、深色取，`h24` 按一天中的时刻取「已过去的最后一个时刻」，天亮前取前一天最后一张。读不出图（视频壁纸之类）就是 15 的径向渐变。

**图标样式照 Dock 的表自己建。** `+[SLSIconAppearanceConfiguration fetchCurrentIconAppearanceConfiguration]` 读主题、明暗、着色色名与自定义色，按 27.2 Dock 的表设 `ISImageDescriptor` 的 `appearance`、`appearanceVariant`、`background`；着色的两种样式另设 `tintColor`：色名 2…9 用 `-[IFColor initWithSystemColor:appearance:contrast:vibrancy:]`（与 Dock 拿到同一个颜色），10 用自定义色，0 跟随 `AppleAccentColor`。这些类由 SkyLight、IconServices、IconFoundation 导出，在 `LaunchpadAwakenerPrivateInterfaces` 的头文件里声明后直接调用，运行时不再核对；声明在 26.6.2 与 27.2 上核对过，`StandaloneIconStyleTests` 会在开发机上把它们实际调用一遍。

**15 的资源从系统的 Dock.app 读。** 搜索框的底、放大镜与清除按钮、抖动模式的叉是 Dock 包里的 PNG（`ectl_search_*`、`ecsb_closebox`，26 与 27 的 Dock.app 都还带着）；「搜索」「无结果」用哪种语言、新建文件夹的「未命名」也取自 Dock 的包。共用模块原先从 `Bundle.main` 读它们——在 Dock 里那就是 Dock.app，在独立版里却是 Launchpad.app，于是独立版的搜索框只剩一行英文「Search」。宿主为此多了 `resourceBundle`：注入版给 `Bundle.main`，独立版给 `/System/Library/CoreServices/Dock.app`（只读其中的文件，不加载它）。语言不能直接问那个包：主包以外的包跟着主包的语言走，Launchpad.app 只有英文，问出来就是英文；所以拿 Dock 包自己的语言列表对照用户的语言偏好来算（`Bundle.preferredLocalizations(from:forPreferences:)`），「未命名」再按算出的语言取（`localizedString(forKey:value:table:localizations:)`，macOS 15.4 起有）。在 Dock 里两种算法结果相同。

**布局库各用各的，首次从注入版的库导入。** 库在 `~/Library/Application Support/LaunchpadAwakener/Standalone/Launchpad.db`；第一次启动时注入版的库存在就从它导入，否则从 15 的旧库。注入版的库沿用 15 的表，所以用的是同一个导入器，页、文件夹、顺序与新装标记都带过来（单元测试 `injectedLibraryImports`）。15 的 `springboard-*` 偏好照样从 `com.apple.dock` 读。独立版自己在 `/Applications` 里，按启动器的规矩从两边的布局里拿掉（见注入版实现说明「App 只在确实卸载时才从布局里删除」）。

**输入法经窗口的内容视图接，字照共用的画法画。** 注入版的输入法靠辅助进程里的真 `NSTextField`；独立版是普通 App，窗口本身就拿得到键盘，于是内容视图遵循 `NSTextInputClient`、做第一响应者，AppKit 自动给它一个 `NSTextInputContext`。没有照搬辅助进程的做法（把真文本框放进同进程的另一扇窗口、经 `CALayerHost` 贴进界面）：一个进程同时只有一扇 key 窗口，那扇窗口还得用 AppKit 私有的 `_contextForLayerHosting` 才贴得进来。宿主多了一项 `inputMethod`，界面层在原来转交托管文本框的几个地方，把按键先交给它：改名时与组字时是每个键，搜索框里只是会打字的键（方向键、删除、回车这些照旧走界面层自己的 15 规则）；Shift 这类修饰键也给它，输入法靠它切换中英文。输入法回调界面层（`SpringboardInputMethodClient`）：打出的字照打字插入，组字中的文字记在编辑模型里（`SpringboardTextEditing.markedText`），显示时代替选区、加下划线，不算进文字，所以搜索不会搜半个拼音，撤销也跳过它。按下鼠标、改名结束、界面收起时，组字中的文字照文本框的规矩当作打出的字收下。候选窗的位置取光标图层在容器里的位置：容器从它所在那块屏的左下角起排，加上那块屏在 Cocoa 屏幕坐标里的原点，就是候选窗要的位置。内容视图还要实现 `windowLevel()`、报出窗口的层级 27，候选窗才出现在界面上方：不报时输入法把候选窗放在浮动窗口之上一层，被界面盖住（`NSTextView` 自己会报，所以注入版的辅助进程不用管）。

**看门狗经窗口服务器撤窗口。** 一扇在一切之上、不再响应的全屏窗口会让整台机器没法用。后台线程每秒向主线程打一次招呼，超过 3 秒没回应就调 SkyLight 的 `SLSOrderWindow` 把窗口移出屏幕——这一步不经 AppKit，主线程卡住时也做得到——每次显示最多做一次，并记一条 fault 日志。开发构建 20 秒无输入自动收起、Esc、退回开关这些保险与注入版共用。

**快捷键默认不设，设置从 Dock 图标的菜单进。** 全局快捷键用 [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts)：设置里的录制控件，底下是 Carbon 的 `RegisterEventHotKey`，不需要任何权限；按下时切换显示与收起。15 的「显示 Launchpad」快捷键默认是空的，这里也一样。界面打开时盖住菜单栏，所以除了 App 菜单里的「设置…」，Dock 图标的菜单也放一个「设置…」，先收起界面再打开设置窗口（`StandaloneSettings.show()`）。设置窗口是 AppKit 的窗口控制器，直接打开；SwiftUI 时期只能去执行 App 菜单里那个「设置…」菜单项，因为 SwiftUI 的设置场景不理会顺着响应链发出的 `showSettingsWindow:`。录制快捷键用 KeyboardShortcuts 的 AppKit 控件 `RecorderCocoa`。设置窗口另有「登录时打开」，经 `SMAppService.mainApp` 增删。

**`--self-check` 让测试机上不看屏幕也能核对。** 开发构建带这个参数启动时不显示界面、不注册登录项，只把宿主找到的 Dock 几何、壁纸来源、图标样式、布局库与窗口写进日志，加上共用的离屏自检，15 秒后退出。

## 模块结构

```
LaunchpadAwakenerPackage/Sources/LaunchpadAwakenerSpringboardCore/
├── Hosting/SpringboardHost.swift          # 宿主接口、SpringboardHostSystem、没有宿主时的 DetachedSpringboardHost
└── Interface/
    ├── SpringboardReplicaLayers.swift     # Dock 的 EC* 图层类与选中材质的等价实现，及造它们的工厂
    └── SpringboardReplicaComparison.swift # 开发构建：在 Dock 里把等价图层与 Dock 的类对照

LaunchpadAwakenerPackage/Sources/LaunchpadAwakenerStandaloneCore/
├── StandaloneLaunchpad.swift              # 启动、显示与收起、登录时打开、--self-check；App 的 delegate
├── StandaloneSpringboardHost.swift        # 独立版的宿主
├── StandaloneSpringboardWindow.swift      # 盖住全屏的窗口，事件交给控制器
├── StandaloneEnvironment.swift            # Dock 所在的屏、Dock 的偏好与几何、布局库的位置与首次导入
├── StandaloneWallpaper.swift              # 壁纸：已允许录屏才截，否则读文件；动态壁纸取当前那一张
├── StandaloneIconStyle.swift              # 由 SkyLight 的图标外观配置建 ISImageDescriptor
├── StandaloneInputMethod.swift            # 系统输入法：遵循 NSTextInputClient 的内容视图
├── StandaloneWatchdog.swift               # 主线程卡住时经窗口服务器撤窗口
└── StandaloneSettings.swift               # 设置窗口：快捷键录制、登录时打开

LaunchpadAwakenerStandalone/main.swift     # App 外壳：建 delegate 并运行
```

## 与提案的差异

- 宿主接口的形状与提案「详细设计」里的草图不同：网格不各自成为协议，而是 `CALayer` 加工厂里的排版、失效与滚动方法；偏好与布局库配置也放进了宿主。原因见上文第一条决策。
- 宿主多了一项 `offersGlassBackground`：独立版没有 Dock 的玻璃，`springboard-background` 设成 `glass` 时照样显示 15 的模糊壁纸，而不是退到会把 App 窗口一起模糊进来的替代模糊。
- 独立版被加进两边的排除名单，且「启动器」即使装着也从布局里拿掉；提案没写这一条，是部署到测试机后发现注入版把它当新 App 加了进去。

## 验证

- 单元测试 `Tests/LaunchpadAwakenerSpringboardCoreTests/SpringboardReplicaLayerTests.swift`：页面网格在 1739×1080 屏上的排法与 27.2 Dock 的自检日志一致（第一格 `{{0, 686}, {193, 171}}`、第 27 格 `{{965, 173}, {193, 171}}`），第一项在最上面，裁剪只在唯一的子图层上；缩略图的位置与 15.5 的公式一致、数量不封顶、滚到空位的行数（8、9、11、12 个 App）、失效后重新取数量；阴影的缩放、标题的阴影设置、选中材质。
- 2026-11-08 在 MacBook（27.2）上部署注入版的开发构建，离屏自检报告页面网格（27 项）、缩略图（12 项，滚到 `{0, -40}`）、选中材质（sRGB 0.9098、`plusD`）与标题像素（2 倍屏 14080 个像素）全部与 Dock 的类一致。
- 单元测试 `Tests/LaunchpadAwakenerStandaloneCoreTests/StandaloneHostTests.swift`：动态壁纸按明暗与按时刻取图、时刻换算、图标样式表（与 27.2 Dock 的表逐项对照）、着色色名与强调色的映射、默认 Dock 留 79 点、库的位置；`LaunchpadLibraryTests` 里启动器从布局里拿掉、名字带 Uninstall 的已放置 App 留下；`LegacyLaunchpadImporterTests` 里从注入版写的库导入；`StandaloneInputMethodTests` 里内容视图向输入法报出窗口层级 27。
- 单元测试 `Tests/LaunchpadAwakenerSpringboardCoreTests/SpringboardInputMethodTests.swift`：组字中的文字代替选区显示、不算进文字，上屏、打字代替组字、空组字结束组字，撤销跳过组字，中文与 emoji 的 UTF-16 换算（含切到 emoji 中间时补齐整字、光标位置保持为空），经界面层组字、上屏、按下鼠标收下组字，候选窗的光标位置落在搜索框里。
- 2026-11-08 在 MacBook（27.2）上用 `--self-check` 启动独立版：从注入版的库导入 4 页、6 个文件夹、149 个 App（与注入版一致），Dock 在下方、留 79 点，壁纸取自文件（5517×3327，没有录屏权限、也没有弹窗），图标样式 1（与 Dock 的相同），窗口铺满 1739×1080、层级 27、所有空间可见；共用的离屏自检里等价网格的格子与 Dock 版逐项相同，207 个图标零失败，15 秒后自行退出，什么也没上屏。
- 2026-11-08 经用户同意在 MacBook（27.2）上做了交互验证，测试前备份了独立版的布局库、测后还原：界面盖住菜单栏与 Dock；Esc 收起后前台立刻回到之前的 App（访达）；搜索框与改名框用拼音组字，组字带下划线、候选窗在框下方的界面之上，空格上屏后搜到「日历」、文件夹改名为「测试」；从界面里打开 Safari 后前台是 Safari；Dock 图标菜单的「Settings…」打开设置窗口，录下 F13，从访达按 F13 打开界面并能直接打字，再按一次收起、前台回到访达。测出并修好了三处：收起后焦点不交还、候选窗被界面盖住、设置窗口打不开。
- 2026-11-08 用户看出独立版的搜索框没复刻完：没有圆角底和放大镜，占位符是英文。改成从 Dock.app 读资源后，两版的离屏自检都报「resources from /System/Library/CoreServices/Dock.app, language zh_CN ("搜索"), 3 of 3 search field image(s)」，同一块屏上两版搜索框的截图一致；整屏对照没有别的差别。单元测试 `Tests/LaunchpadAwakenerSpringboardCoreTests/SpringboardResourceTests.swift`：Dock 包里四张图两种倍率都在、缺的图返回空、按用户的语言偏好挑 Dock 的语言（地区退到语言，都没有时英文）、「未命名」在中文偏好下取自 Dock 的字串；`StandaloneResourceTests`：独立版的宿主指向 `com.apple.dock`。
- 多显示器（2026-11-11，只在开发机上）：单元测试覆盖 Dock 矩形到显示器的换算（中心所在的屏；藏到底边外时归上面那块；离所有屏都远时不归任何一块）。另有两条在开发机（27.2）上实际问窗口服务器：Dock 的矩形落在一块活动显示器上，换成 AppKit 坐标后正好接在 Dock 那块屏可用区域的下沿。没有在接着第二块屏的真机上看过。
- 测试工具的两处坑（不是独立版的问题）：经 ssh 从别的进程切输入法，要在界面打开之前切，已激活的输入上下文不跟着变；用发 `CGEvent` 的小工具按 F13 这类功能键后，系统的 Fn 修饰键状态会卡住，之后的字母都成了 Fn+字母（Fn-A 把焦点移到 Dock），要补发一次 Fn 键（虚拟键码 63）。

## 已知降级

- 等价文字图层固定左对齐；Dock 的 `ECTextLayer` 在 Dock 处于从右到左的语言时右对齐。界面层给每个文字图层都显式设了对齐，不受影响。
- Dock 的格子因为放不下而被缩小时，独立版只读得到设定的图标大小，按没缩小留位置。
- 强调色设成「硬件」（彩色 iMac）时按系统蓝着色：硬件色存在系统外观主题文件里，键名没查。
- 26 虚拟机上还没验证；Cmd-Tab 切到它时不会打开界面这一点是推测，测试工具按不了修饰键，没在真机上看。
- 通知横幅在界面之下：「登录项已添加」的通知在界面打开时看不到，收起后才看到。音量提示与 Cmd-Tab 切换器没有试。
- 界面打开时按 Cmd-逗号，设置窗口开在界面下面，收起界面才看得到；从 Dock 图标菜单打开不受影响。
- 输入法只试了拼音。组字时下划线只有一种，不分输入法给的「当前段」；`characterIndex(for:)` 不回答点在哪个字上，点选候选以外的鼠标操作照文本框的规矩先收下组字。
- 独立版自己的文字（设置窗口、Dock 菜单的「Settings…」）只有英文。

## 延伸阅读

- 配套提案：[不注入 Dock 的独立版 Launchpad](../Evolutions/0002-standalone-launchpad.md)
- 注入版实现说明：[Launchpad 复刻：实现说明](LaunchpadReplica.md)
- Dock 图层类的逆向笔记：`/Volumes/RE/Dock/27.2/Notes/ECLayerReuse.md`
