# 独立版 Launchpad：实现说明

> 配套提案见 [不注入 Dock 的独立版 Launchpad](../Evolutions/draft-standalone-launchpad.md)。
> 本文记录实际落地的实现、与提案的差异，以及当前覆盖范围与已知降级。面向维护者。
> 注入版的实现说明见 [Launchpad 复刻：实现说明](LaunchpadReplica.md)，两版共用的界面层细节都在那里。

## 背景与目标

独立版是一个普通的 App，自己开一扇盖住整块主屏幕的窗口，画出与注入版相同的 macOS 15 Launchpad，不注入 Dock、不需要关 SIP。两版共用 `LaunchpadAwakenerSpringboardCore` 里的布局库与界面层；界面层要的窗口、图层类、壁纸、图标样式这些，经宿主接口 `SpringboardHost` 向各自的宿主要（见[术语表](../Glossary.md)「Host（宿主）」）。

## 关键设计决策

**宿主照现有调用的形状抽出，注入版只是把静态调用换成经宿主调用。** 图层工厂沿用 `DockLayerFactory` 的形状：网格对调用方就是一个 `CALayer`，排版、填充与滚动都交回造它的工厂。曾考虑给页面网格与缩略图网格各定一个协议，那样每处调用都要多包一层，注入版这边的改动面也大得多。宿主在每个进程里只选定一次（`SpringboardHostSystem.bootstrap(host:)`），在 payload 里是装 hook 之前、在后台线程上选的，所以宿主本身是 `Sendable` 的，界面层在主线程以外要读的三样（图层工厂、偏好、布局库配置）是它的 `nonisolated` 属性：Core Animation 在自己的线程上复制图层，图层的初始化方法会建文字图层。没有选定宿主时（单元测试）用 `DetachedSpringboardHost`：不给窗口、壁纸、玻璃、托管文本框与卸载器，Dock 取默认大小，图层用下文的等价图层。

**等价图层逐条照 Dock 的二进制写，在 Dock 里逐像素对照过。** 独立版拿不到 Dock 的 `ECGridLayer`、`ECImageGridLayer`、`ECTextLayer` 与 `ECShadowTextLayer`，也没有 Dock 给 `CALayer` 加的 `setMaterialControl:appearance:`，于是在共用模块里用纯 Core Animation 重写（`SpringboardReplicaLayers.swift`）。每个取整方式、子图层的插入顺序、哪些属性设了哪些没设，都取自 27.2 的 Dock（`/Volumes/RE/Dock/27.2/Notes/ECLayerReuse.md` 1.1、1.3、1.4 与第 5 节）。几处不看二进制就会写错的地方：

- 网格新建的条目层一律插到最底下，所以第一项画在最上面。
- 缩略图网格建的条目层与 App 一样多，不封顶到 9 个，多出的行在滚动层里排到下方、被裁掉。滚到「下一个空位」时，最后一行是满的要再多滚一行；不满一屏的什么也不做。
- 缩略图网格的滚动层左移、上移半个间距，这半个间距截断成整点；摆放条目时用的半个间距却是精确的。
- 带阴影的文字把阴影画在字里，偏移与模糊以点存、画时乘内容缩放，大于 1 时再乘 0.6；交给 Core Animation 的 `shadowOffset` 结果不同。阴影色默认是 Generic Gray 的黑。
- 选中高亮的灰是 sRGB 的 232/255，配 `plusD` 合成滤镜，两个参数之外什么都不读。

这些图层不碰 `CATransaction`：动不动画由调用方当前的事务决定，与 Dock 的类一样。开发构建的离屏自检在 Dock 里把同一页网格、同一组缩略图、选中材质和同一行标题用两套各做一遍，逐项比对并写进日志（`SpringboardReplicaComparison`）；注入版仍然只用 Dock 自己的类。

**窗口盖住一切，事件交给与注入版相同的控制器。** 无边框 `NSWindow`，层级 27（15 的 Launchpad 窗口所在，高于菜单栏的 24 与 Dock 的 20），在所有空间与全屏 App 之上都能出现（`.canJoinAllSpaces`、`.fullScreenAuxiliary`）。内容视图是层托管视图，根图层整个交给界面，与 Dock 的 `WALayerKitWindow` 一样。窗口覆写 `sendEvent(_:)`，把每个事件的 `cgEvent` 转成 `SpringboardInputEvent` 交给 `SpringboardController.handle(_:)`，没被拿走的才照常派发；所以按键、点击、滚动、翻页的规则与注入版一字不差。Dock 被盖住，宿主的 `isOnDock` 恒为否。

**焦点：打开时激活自己，退场一开始就交还。** `orderIn` 先 `NSApp.activate()` 再 `makeKeyAndOrderFront`；`releaseKeyFocus` 调 `NSApp.deactivate()`，焦点回到之前的 App，窗口留到退场动画结束才撤下，与 15「退场一开始就交还输入」一致。App 失去激活（Cmd-Tab、点到别处、启动了 App）就收起；点 Dock 图标走 `applicationShouldHandleReopen` 打开；登录时由「打开时登录」启动的那一次不打开，等第一次点图标（看打开事件的 `keyAELaunchedAsLogInItem`）。

**壁纸绝不申请权限。** 截壁纸窗口要「录屏」权限，所以只在 `CGPreflightScreenCaptureAccess()` 为真时才截——这个函数只查询、不弹窗；截的是 Dock 自己的壁纸窗口时要传 Dock 的进程号，不再是本进程。否则读 `NSWorkspace.desktopImageURL(for:)` 的文件：动态 HEIC 按 XMP 里 `apple_desktop:` 的日程取当前那一张——`apr` 与 `solar` 的 `ap` 按浅色、深色取，`h24` 按一天中的时刻取「已过去的最后一个时刻」，天亮前取前一天最后一张。读不出图（视频壁纸之类）就是 15 的径向渐变。

**图标样式照 Dock 的表自己建。** `+[SLSIconAppearanceConfiguration fetchCurrentIconAppearanceConfiguration]` 读主题、明暗、着色色名与自定义色，按 27.2 Dock 的表设 `ISImageDescriptor` 的 `appearance`、`appearanceVariant`、`background`；着色的两种样式另设 `tintColor`：色名 2…9 用 `-[IFColor initWithSystemColor:appearance:contrast:vibrancy:]`（与 Dock 拿到同一个颜色），10 用自定义色，0 跟随 `AppleAccentColor`。每个私有方法调用前按类型编码核对，对不上就退回默认样式。

**布局库各用各的，首次从注入版的库导入。** 库在 `~/Library/Application Support/LaunchpadAwakener/Standalone/Launchpad.db`；第一次启动时注入版的库存在就从它导入，否则从 15 的旧库。注入版的库沿用 15 的表，所以用的是同一个导入器，页、文件夹、顺序与新装标记都带过来（单元测试 `injectedLibraryImports`）。15 的 `springboard-*` 偏好照样从 `com.apple.dock` 读。独立版自己在 `/Applications` 里，按启动器的规矩从两边的布局里拿掉（见注入版实现说明「App 只在确实卸载时才从布局里删除」）。

**看门狗经窗口服务器撤窗口。** 一扇在一切之上、不再响应的全屏窗口会让整台机器没法用。后台线程每秒向主线程打一次招呼，超过 3 秒没回应就调 SkyLight 的 `SLSOrderWindow` 把窗口移出屏幕——这一步不经 AppKit，主线程卡住时也做得到——每次显示最多做一次，并记一条 fault 日志。开发构建 20 秒无输入自动收起、Esc、退回开关这些保险与注入版共用。

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
├── StandaloneEnvironment.swift            # Dock 的偏好与几何、布局库的位置与首次导入
├── StandaloneWallpaper.swift              # 壁纸：已允许录屏才截，否则读文件；动态壁纸取当前那一张
├── StandaloneIconStyle.swift              # 由 SkyLight 的图标外观配置建 ISImageDescriptor
├── StandaloneWatchdog.swift               # 主线程卡住时经窗口服务器撤窗口
└── StandaloneSettingsView.swift           # 设置窗口：登录时打开

LaunchpadAwakenerStandalone/LaunchpadApp.swift  # App 外壳：delegate 与设置场景
```

## 与提案的差异

- 宿主接口的形状与提案「详细设计」里的草图不同：网格不各自成为协议，而是 `CALayer` 加工厂里的排版、失效与滚动方法；偏好与布局库配置也放进了宿主。原因见上文第一条决策。
- 宿主多了一项 `offersGlassBackground`：独立版没有 Dock 的玻璃，`springboard-background` 设成 `glass` 时照样显示 15 的模糊壁纸，而不是退到会把 App 窗口一起模糊进来的替代模糊。
- 独立版被加进两边的排除名单，且「启动器」即使装着也从布局里拿掉；提案没写这一条，是部署到测试机后发现注入版把它当新 App 加了进去。

## 验证

- 单元测试 `Tests/LaunchpadAwakenerSpringboardCoreTests/SpringboardReplicaLayerTests.swift`：页面网格在 1739×1080 屏上的排法与 27.2 Dock 的自检日志一致（第一格 `{{0, 686}, {193, 171}}`、第 27 格 `{{965, 173}, {193, 171}}`），第一项在最上面，裁剪只在唯一的子图层上；缩略图的位置与 15.5 的公式一致、数量不封顶、滚到空位的行数（8、9、11、12 个 App）、失效后重新取数量；阴影的缩放、标题的阴影设置、选中材质。
- 2026-11-08 在 MacBook（27.2）上部署注入版的开发构建，离屏自检报告页面网格（27 项）、缩略图（12 项，滚到 `{0, -40}`）、选中材质（sRGB 0.9098、`plusD`）与标题像素（2 倍屏 14080 个像素）全部与 Dock 的类一致。
- 单元测试 `Tests/LaunchpadAwakenerStandaloneCoreTests/StandaloneHostTests.swift`：动态壁纸按明暗与按时刻取图、时刻换算、图标样式表（与 27.2 Dock 的表逐项对照）、着色色名与强调色的映射、默认 Dock 留 79 点、库的位置；`LaunchpadLibraryTests` 里启动器从布局里拿掉、名字带 Uninstall 的已放置 App 留下；`LegacyLaunchpadImporterTests` 里从注入版写的库导入。
- 2026-11-08 在 MacBook（27.2）上用 `--self-check` 启动独立版：从注入版的库导入 4 页、6 个文件夹、149 个 App（与注入版一致），Dock 在下方、留 79 点，壁纸取自文件（5517×3327，没有录屏权限、也没有弹窗），图标样式 1（与 Dock 的相同），窗口铺满 1739×1080、层级 27、所有空间可见；共用的离屏自检里等价网格的格子与 Dock 版逐项相同，207 个图标零失败，15 秒后自行退出，什么也没上屏。

## 已知降级

- 等价文字图层固定左对齐；Dock 的 `ECTextLayer` 在 Dock 处于从右到左的语言时右对齐。界面层给每个文字图层都显式设了对齐，不受影响。
- Dock 的格子因为放不下而被缩小时，独立版只读得到设定的图标大小，按没缩小留位置。
- 强调色设成「硬件」（彩色 iMac）时按系统蓝着色：硬件色存在系统外观主题文件里，键名没查。
- 26 虚拟机上还没验证；Cmd-Tab 切到它时不会打开界面这一点是推测，要在真机上看。

## 延伸阅读

- 配套提案：[不注入 Dock 的独立版 Launchpad](../Evolutions/draft-standalone-launchpad.md)
- 注入版实现说明：[Launchpad 复刻：实现说明](LaunchpadReplica.md)
- Dock 图层类的逆向笔记：`/Volumes/RE/Dock/27.2/Notes/ECLayerReuse.md`
