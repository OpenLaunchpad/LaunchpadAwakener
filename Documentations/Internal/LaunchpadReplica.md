# Launchpad 复刻：实现说明

> 配套提案见 [在 macOS 27 的 Dock 中复刻 macOS 15 的 Launchpad](../Evolutions/draft-launchpad-replica.md)。
> 本文记录实际落地的实现、与提案的差异，以及当前覆盖范围与已知降级。面向维护者。

## 背景与目标

payload 注入 macOS 27.2 的 Dock，接管所有「打开 Apps」的入口，在 Dock 自己的窗口与图层类上画出 macOS 15 的 Launchpad。布局首次从 15 留下的数据库导入，之后存在 `~/Library/Application Support/LaunchpadAwakener/Launchpad.db`。完整动机见提案。

## 关键设计决策

**只认构建档案里的 Dock。** `DockBuildProfile` 以 Dock 可执行文件 arm64e 切片的 `LC_UUID` 为键，存着只对这一个构建成立的事实（目前是 `DockBar` 与 `DockGlobals` 两个全局变量的地址）。UUID 不在表里，payload 一个 hook 都不装，所有入口照旧打开系统的 Apps。这是有意的：地址在别的构建里毫无意义，读错地址会让 Dock 崩溃。

**`DockBar` 只能经全局变量拿到。** 27.2 里没有任何导出的路径通向它；`-[DockBar rect]` 和 `-[DockBar setRollTile:]` 在鼠标划过 Dock 时都不会被调用，所以「hook 这两个方法、在调用时记下接收者」的办法拿不到它（原型试过）。`DockGlobals` 同样只能经全局变量拿到。读全局变量后还会核对对象的类：按类对象比较，不比类名，因为运行时给 Swift 类的名字是 `DockCore.DockGlobals`，不是查找它用的改编名 `_TtC8DockCore11DockGlobals`。

**事件入口：hook 事件总入口加抢键盘焦点，不全局抢占事件。** 打开时 `CPSStealKeyFocusOnConnection(cid, 1152)`，关闭时归还，事件经 `-[DockAppEventHandler handleDockBarEvent:type:]` 接管——这正是 15 的做法。没有走 27 的 Cmd-Tab 切换器那种自建连接加 `CGSSetEventCapture`：一旦失控，整台机器的输入都会被锁住，26 上那次只能重启就是这种情形。也没有改用 `ECModalEventController`：它自建连接时只按 Dock 栏窗口的坐标做命中测试，处理者栈又与堆栈展开、Cmd-Tab 共用，打开 Launchpad 时会互相挤掉。

**判断「点在 Dock 上」只能用 `DockBar` 的 `rect`。** 27.2 的 Dock 窗口几乎铺满屏幕，用窗口范围判断会把所有点击都当成点在 Dock 上。

**payload 里不用 AppKit，也不用 `Bundle.module`。** 27.2 的 Dock 不链接 AppKit，字体一律用 Core Text 建，显示器信息用 CoreGraphics 和 Dock 自己的 `DisplayDescriptor`。SwiftPM 生成的 `Bundle.module` 找不到资源时直接 `fatalError`，在注入的框架里就是让 Dock 崩溃，所以 15.5 的 `LaunchPadLayout.plist` 只放在测试资源里，排除名单与默认首页以 Swift 常量随 payload 发布，由测试逐项核对。界面贴图（`ecsb_*`、`ectl_*`）在运行时从 27 的 Dock.app 里读。

**调 Dock 内部方法一律先校验签名。** `DockHostInterface.requiredMethods` 汇总了界面层要调的所有 Dock 方法，任何一个的类型编码与 27.2 元数据不符，就整批不装 hook。经对象拿到的 Swift 类（`IconAppearance` 等）在调用前按对象的实际类校验，失败就降级。两个容易错的地方：`EC*` 类的 `scaleFactor` 都是 `float`（编码 `f`），按 `CGFloat` 传会错位；头文件里的 ivar 偏移是编译期的值，运行时会滑动，要用 `ivar_getOffset`。

**每页一个 Dock 的 `ECGridLayer`，内容变了就换一个新的。** `ECGridLayer` 只在初始化时问一次条目数，之后没有入口能改；15.5 的 `ECSBGridLayer` 是直接改父类 ivar 来增删图标的。这里选择页内条目一变就重建整页网格，代价可以忽略（一页最多几十个图层）。另外三点：`-[ECGridLayer layout]` 不是 `layoutSublayers`，Core Animation 不会自动调，要宿主调用；数据源被弱引用，由 `SpringboardPageGrid` 持有；`makeLayerForLayer:` 在协议上是可选的，实际必须实现。

**图层类不碰主线程隔离的单例。** Swift 写的 `CALayer` 子类必须实现 `init(layer:)`，Core Animation 做动画时会用它复制出呈现层；这些子类保持不隔离，图标由主线程上的 `SpringboardInterface` 查好再交给图层，图层自己不调用 `@MainActor` 的单例。首次布局一律关掉隐式动画，否则图层会从零尺寸「长」出来。

**自己的库沿用 15 的表与触发器，编辑时改为整组重排。** 导入与追加靠 15 的触发器维护 `ordering`；拖动类的编辑则先关掉触发器（`dbinfo` 的 `ignore_items_update_triggers` 置 1），把涉及的父项的子项按新顺序整组写回、编号从 1 开始，再打开触发器。被移动的项在同一个事务里先挂到父项 -1 上，否则之后再读兄弟列表时它还会出现在原处。编辑后照 15 收拾：一页超过容量就把末尾几项挤到下一页开头，空的文件夹页、文件夹和页面删除。

**App 只在确实卸载时才从布局里删除。** 搜索目录里没找到、书签解析不到、LaunchServices 也不认识，三者都成立才删，免得装在别处的 App 被误删。

**图标与 Dock 栏同一套样式。** 描述符复制自 `DockBar.environment.iconAppearanceMonitor.appearance.iconDescription`，再经 IconServices 的 `-[ISIcon initWithURL:]` 取图；Dock 自己走的 `_LSBindingCreateWithURL` 是 C 函数，签名无法校验，所以没用。图标在后台队列渲染，布局一加载就全部预取（MacBook 上 149 个约 2 秒，之后命中 IconServices 的缓存只要几十毫秒）。

**Dock 的厚度取 27 的 Dock 栏矩形。** 15 的公式用「图标大小 + 上下留白」（约 59 点），27 的 Dock 外面多了一圈玻璃（MacBook 上栏高 82 点）。沿用 15 的算法会让网格压到 Dock 上；代价是小屏幕上图标比 15 小一档。

**文件夹照 15 用图层画，缩略图交给 Dock 的 `ECImageGridLayer`。** 15.5 根本不引用 Dock.app 里的 `ecsb_group`、`ecsb_arrow_*` 等贴图（10.7–10.9 时代的遗留），文件夹图标是半透明浅色方圆加 3×3 缩略图。`ECImageGridLayer` 与 `ECGridLayer` 不同，`layerSourceInvalidated:` 之后会重新问条目数，所以换内容不必重建；它不保证子图层顺序，取缩略图时按位置排序。

**拖动时自己摆放图标，不经 `ECGridLayer` 布局。** `ECGridLayer` 的布局在内部关掉隐式动画，借它没法做出 15 那种 0.4 秒的让位动画；拖动期间按「排列」（当前页的条目按新顺序排好、被拖的那个占一格）逐个设图标的 frame。被拖的图层离开网格挂到容器最上层跟手。松手时一次性写库，库发布的新布局再重建页面；拖动或文件夹开合期间到达的新布局先存着，动作结束后才换上（`replaceLayout` / `applyPendingLayoutIfIdle`）。

**建文件夹先在界面上做出来，库稍后跟上。** 15 的三条路径都照逐帧时序复刻（RE 笔记 4.11）：快速松在 App 上，目标的格子当场换成文件夹图标，两张图片先后缩进缩略图，0.75 秒后自动弹开；停住 1 秒，弹开一个只有目标的文件夹，被拖的图标在面板里继续摆放；快速松在文件夹上，图片缩进缩略图、文件夹不打开。界面上的文件夹在库写好之前没有真实的标识符，用一个负数标识符的「未存的文件夹」代替；库发布的新布局到达时，再按第一个 App 找到真正的文件夹接上（`storedFolder(for:in:)`）。停住 1 秒弹开的那个文件夹在松手前根本不写库：在面板里松手时写一次建文件夹（顺序按面板），拖回面板外就在界面上解散，库里什么也没发生过。

**主页的空位跟着文件夹走。** 拖进文件夹（弹开的或快速松手后自动弹开的）时，被拖图标在主页上留下的空位不立刻合拢，而是保留到文件夹关上后 250 毫秒，这期间主页不按新布局重建（`mainPagePlaceholder`）。从文件夹里拖出时同样等面板关上 250 毫秒，主页才让位，只剩一个 App 的文件夹此时解散成那个 App。

**打开的文件夹是另一个翻页器。** 15 的 `ECSBGroupLayer` 本身就是 `ECPagerLayer`，所以主界面与文件夹共用 `SpringboardPagedGrids`（滚动层、页码、跟手、回弹、滚轮停顿）。面板是 `CABackdropLayer` 加私有的 `CAFilter`；开合动画里动的是面板的形状，承载内容的容器始终铺满，靠遮罩裁出面板。打开时图标留在各自的格子里、随面板展开淡入，关闭时才缩回缩略图。15 打开时图标是从缩略图飞出来的，这里按用户的要求改成不动；淡入是为了第一帧文件夹方圆里不露出正好压在那里的半个图标。面板的毛玻璃不用实时的 `CABackdropLayer`：面板身后只有那张静态的壁纸背景，于是把同一张壁纸图先过背景的三个滤镜、再过面板的模糊与饱和度，铺在遮罩里、上面盖白色半透明，一次算好（`SpringboardFolderPanel.Frost.wallpaper`）。macOS 27 上实时 backdrop 遇到局部重绘会画错：按下文件夹里的图标时，那一格和屏幕另一块区域的毛玻璃会突然变暗。只有玻璃背景（由窗口服务器合成）才用窗口服务器采样的 backdrop，放在遮罩外面，因为遮罩会把内容放到屏幕外绘制，那里采样不到窗口身后。

**界面按屏幕尺寸铺，不按窗口根图层。** `WALayerKitWindow` 的根图层在建界面时 bounds 还是 0×0。图标的位置都由屏幕尺寸算出，不受影响，但按根图层定大小的容器与背景就成了 0×0：最初的壁纸背景因此看起来是透明的，换成玻璃后也只在屏幕左下角露出一小块。

**图标缩放时只设 bounds 与 position。** 解散中的文件夹图标缩到一成、被拖的图标放大到 1.1 倍时，页面可能正好在让位；给带 transform 的图层设 `frame`，Core Animation 会按缩放后的尺寸反推 bounds，图标恢复原大后就大了十倍、跑出原格。让位一律用 `setUntransformedFrame(_:)`。关闭文件夹的动画也只处理还在面板里的图标：网格的列表里仍有被拖出去的那个，碰了它就会在手上消失。

**新建的图层先提交上屏，再做动画。** Core Animation 不给从未提交过的图层做隐式动画。打开文件夹时面板、图标都是新建的，所以先在关掉动画的事务里摆好起点（面板缩在文件夹图标的方圆上、图标全透明），`CATransaction.flush()` 提交，再开始动画；图标缩进缩略图、文件夹解散也是这样。漏掉这一步的症状就是「打开没有动画、关闭有」。

**背景默认是 15 的模糊壁纸，Dock 自己的液态玻璃是选项。** 每次打开都截一张 WindowManager 的壁纸窗口（27 的壁纸窗口归它，每个空间一扇叫 `Wallpaper` 的窗口），用 15 同样的 `SLSHWCaptureWindowList(…, 0x11944)`；截好的图放进栅格化的容器，套 15 的三个滤镜（模糊 30、饱和度 1.8、颜色矩阵压暗），只算一次，App 的窗口被它挡住，与 15 一样。截不到时是 15 自带的径向渐变。中途一度改成玻璃（用户想要更贴合新系统的效果），看过后又改回来，因为模糊效果不如原版；玻璃留作 `springboard-background` 设为 `glass` 时的选项。

玻璃来自 Dock 画 Dock 栏与 Cmd-Tab 切换器的那套控制器：Swift 写的，但经四个 Objective-C 类就能驱动（`DockGlassMaterialLayerController`、`DockGlassMaterialLayoutConfiguration`、`DockSDFElement`、`DockGlassMaterialEnvironment`），每个方法调用前都校验签名，校验不过就退回一层带 15 三个滤镜、由窗口服务器采样的模糊。三个容易踩的地方：

- 取环境的 `+currentDockMaterialEnvironmentWithColorScheme:` 在 `DockBar` 或 `DockGlobals` 还不存在时会让 Dock 直接崩溃，所以调用前两个全局变量都要读到；开发构建的离屏自检也因此等 Dock 起来 5 秒后才建玻璃，并且每个 payload 构建只试一次（在 `/tmp` 里留标记），万一崩了，Dock 重启后不会再试。
- 玻璃固定深色、不随背后亮度变化：图标标题沿用 15 的白字加阴影，浅色玻璃上看不清。玻璃向屏幕四边外扩 64 点，让它的边缘高光落在屏幕外。
- 玻璃由窗口服务器采样，所以界面整体淡入淡出时不能当作一组离屏绘制（`allowsGroupOpacity` 关掉，Cmd-Tab 也这样做），否则淡入期间玻璃后面什么也没有。代价是淡入时图标与玻璃各自半透明叠在一起。

选玻璃时 App 的窗口会被模糊进背景，与 15（只有壁纸）不同。`springboard-glass-variant` 偏好可以换成 Dock 的另外两种玻璃（2 去掉前景效果，4 是 Cmd-Tab 的），下次打开生效。

**捏合读原始 DockSwipe 事件，且默认不接管。** 27 的「拇指加三指捏合」由 Spotlight 进程识别，Dock 的手势系统里已经没有它，`sendLaunchAppsBrowsing` 也不在这条路上；但 WindowServer 仍把 DockSwipe 事件送到 Dock 的连接上。payload 在已有的事件 hook 里照 15 的状态机读这些事件，跟手设可见度，松手后跑 15 的 60 Hz 弹簧。Spotlight 也会响应同一组事件，所以只有 `com.apple.spotlight` 的 `trackpadAppBrowseEnabled` 为 NO 时才接管；不要用系统设置里的「更多手势」开关代替，它很可能让 HID 层不再产生捏合事件。

**收起时先交还输入，再放退场动画。** 与 15 一样：退场一开始就归还键盘焦点、事件不再拦截，正在退场的窗口另存一份，动画结束后才移出屏幕；此时再打开会先立刻结束旧的那份。点图标启动的放大淡出放在窗口根图层上，不随界面一起淡出。

**自动注入的两道保护。** 同一个 Dock 进程的注入与 payload 的暂存都只进行一次（App 启动时的注入与进程监视的注入会同时开始）；注入后 Dock 连续 3 次在 15 秒内退出，就自动关掉自动注入并说明原因，免得一个加载即崩溃的 payload 让 Dock 循环崩溃。

## 模块结构

```
LaunchpadAwakenerPackage/Sources/LaunchpadAwakenerPayloadCore/
├── PayloadEntry.swift                  # 注入后的入口；装 hook，再启动布局库
├── Host/                               # 调 Dock 内部与私有接口的唯一地方
│   ├── DockBuildProfile.swift          # 构建档案：UUID → 只对该构建成立的事实
│   ├── DockHostInterface.swift         # 签名清单与校验；WALayerKitWindow、DockBar rect
│   ├── DockBarReference.swift          # 经全局变量拿 DockBar 与 DockGlobals
│   ├── DockGlassMaterial.swift         # Dock 自己的液态玻璃（Cmd-Tab 切换器那套控制器）
│   ├── WallpaperSnapshot.swift         # 截 WindowManager 的壁纸窗口
│   ├── DockEnvironment.swift           # Dock 的方向、厚度、刘海、图标样式
│   ├── DockLayerFactory.swift          # ECGridLayer、ECTextLayer、ECShadowTextLayer、材质；CA 私有滤镜
│   ├── IconServicesBridge.swift        # IconServices 取图
│   └── SkyLightBridge.swift            # 连接、窗口层级、键盘焦点
├── Data/                               # 布局库，可脱离 Dock 测试
│   ├── LaunchpadStore*.swift           # 自己的库：读、追加、编辑、整理
│   ├── LegacyLaunchpadImporter.swift   # 只读导入 15 的库
│   ├── ApplicationDiscovery.swift      # 扫描应用目录与排除名单
│   ├── ApplicationDirectoryMonitor.swift # FSEvents
│   ├── LayoutReconciliation.swift      # 与已安装的 App 对账
│   └── LaunchpadLibrary.swift          # 把以上串起来的 actor；发布布局、接受编辑
├── Interface/                          # 界面层，按 15.5 的 ECSB* 划分
│   ├── SpringboardController.swift     # 显示、隐藏与进出场、事件分派、启动动画、捏合、保险机制
│   ├── SpringboardWindow.swift         # 全屏窗口、27/29 层、键盘焦点
│   ├── SpringboardInterface.swift      # 页面、搜索、选中、点击、文件夹开合与改名、背景（ECSBSpringboard + ECSBLayer）
│   ├── SpringboardInterface+Dragging.swift # 拖动整理（ECSBDragCapture 与各 DragState）
│   ├── SpringboardInterface+FolderMaking.swift # 拖到图标上建文件夹、放进文件夹、未存的文件夹与解散
│   ├── SpringboardIconFlight.swift     # 图片缩进文件夹缩略图的动画
│   ├── SpringboardBackground.swift     # 背景：15 的模糊壁纸，或 Dock 的液态玻璃
│   ├── SpringboardPagedGrids.swift     # 主界面与文件夹共用的翻页器（ECPagerLayer）
│   ├── SpringboardFolderPanel.swift    # 打开的文件夹（ECSBGroupLayer）与改名编辑框
│   ├── SpringboardPageGrid.swift       # 每页一个 ECGridLayer 及其数据源
│   ├── SpringboardItemLayer.swift      # 图标、文件夹图标与标题（ECSBItemLayer、ECSBGroupItemLayer、ECSBLabelLayer）
│   ├── SpringboardControlLayers.swift  # 页码、搜索框、无结果
│   ├── SpringboardMetrics.swift        # 15.5 的主界面几何（纯计算）
│   ├── SpringboardFolderMetrics.swift  # 15.5 的文件夹几何（纯计算）
│   ├── SpringboardSearch.swift         # 15.5 的搜索规则（纯计算）
│   ├── SpringboardPaging.swift         # 15.5 的翻页、方向键与拖动命中规则（纯计算）
│   ├── SpringboardPinch.swift          # 15.5 的捏合映射与弹簧（纯计算）
│   └── SpringboardSelfCheck.swift      # 开发构建的离屏自检
└── Integration/                        # hook 声明与入口、事件的接管
```

## 核心数据流

- **显示**：入口 hook（`-[Spotlight sendLaunchAppsBrowsing]`）→ `SpringboardController.toggle` → 读 Dock 的几何算出 `SpringboardMetrics` → 建窗口与 `SpringboardInterface` → 窗口抬到 27 层、Dock 的窗口抬到 29 层、抢键盘焦点。
- **事件**：事件 hook 把 `CGEvent` 抄成 `SpringboardInputEvent` → 控制器换算成容器坐标（左下为原点、y 向上）→ 交给界面 → 界面返回「无 / 关闭 / 启动」三种动作之一。落在 Dock 栏上的点击交还 Dock。
- **布局**：`LaunchpadLibrary` 启动时打开库，首次导入，与已安装的 App 对账，发布布局；之后应用目录一有变化就再对账。每次发布都会触发图标预取。

## 与提案的差异

- App 的变更只靠 FSEvents 监听应用目录，没有接 LaunchServices 的私有通知（签名未逆向确认）。
- 搜索框不接输入法：直接把 Dock 收到的按键当文字，所以打不出中文；标题匹配不上时仍按 App 文件名匹配。
- 触控板翻页用滚动事件自带的阶段判断开始与结束；三指轻扫翻页暂不支持。
- 15.5 的 `LaunchPadLayout.plist` 没有作为资源随 payload 发布，改为 Swift 常量（原因见上）。
- 文件夹改名同样不接输入法；Esc 取消改名、保留原名（15 的行为没能查清）。
- 拖到 Dock 上、拖动搜索结果、文件夹里的方向键导航都不支持；拖动时文件夹不额外加一行。
- 捏合没有接入 27 的 Dock 手势系统（那里已经没有它），而是读原始 DockSwipe 事件，并且要用户先关掉 Spotlight 的捏合。
- 背景默认照 15 截壁纸、加三个滤镜；另有 `springboard-background` 设为 `glass` 时的 Dock 液态玻璃，那时 App 的窗口会被模糊进来。
- 打开文件夹时图标留在格子里淡入，不像 15 那样从缩略图飞出（用户要求）；关闭时仍照 15 缩回缩略图。

## 验证

- 单元测试（`swift test`，只在开发机上跑，不碰 Dock）：库的建立、追加、编辑（移动、溢出、建文件夹及被拖的排在前面、放入、新的末页，以及任何编辑让文件夹只剩一个 App 时解散）与整理；界面在库跟上之前显示的文件夹与库的结果一致；旧库导入（含隐藏页、断了父项的页、下载中的 App、空页）；App 发现、排除名单与 15.5 原文件的逐项核对；对账；主界面与文件夹的几何（以 15.5 规格里 1470×956 屏的手算示例为准）；搜索规则；翻页、方向键与拖动命中规则；捏合映射与弹簧。
- MacBook 上的非交互验证：部署后与 Dock 重启后各注入一次、hook 装上、21 个 Dock 方法签名全部吻合；导入 3 页、2 个文件夹、149 个 App 与旧库一致；开发构建的离屏自检核对 Dock 的 `ECGridLayer` 建出的图标数量与位置、文件夹图标的方圆与 `ECImageGridLayer` 缩略图，以及 Dock 的玻璃建出的图层：一个由窗口服务器采样、带 `glassBackground` 滤镜、组名 `launchpad-background` 的 `CABackdropLayer`，加 `CASDFLayer` 与 `CAPortalLayer`，向屏幕四边外扩 64 点，Dock 未崩溃。
- 经用户同意的交互验证（2026-11-06，MacBook 上）：经 ssh 截图、录屏，用一个发 `CGEvent` 的小工具模拟点击与拖动，核对了玻璃背景、文件夹打开动画、快速松手建文件夹并自动弹开、从文件夹拖出后解散；录屏逐帧看过，测试用的文件夹已拆掉。
- 仍需用户亲自判断的部分：观感与手感、与 15 的逐帧比较、停住 1 秒弹开新文件夹、捏合。

## 已知降级

- 透明与着色图标样式下，Dock 在图标背后画的玻璃底没有复刻。
- 搜索与改名打不出中文（没有输入法）。
- 玻璃背景：打开期间切换深浅色或辅助功能里的透明度、对比度，要到下次打开才跟上（界面每次打开都重建，没有注册 Dock 的外观观察者）。
- 背景是打开那一刻的静态截图，动态壁纸不会动（与 15 相同）；截不到时是 15 的径向渐变。
- 文件夹打开的那 0.25 秒里，面板的毛玻璃不包含正在淡出的主网格图标（固定算好的毛玻璃只有壁纸）。
- 快速放进文件夹后，文件夹图标的缩略图在库发布新布局、页面重建时就滚回顶部；15 要等下次打开再关上这个文件夹才滚回。
- 捏合在用户关掉 Spotlight 的捏合之前不生效；Dock 能否收到捏合事件尚未在真机上确认。
- 只在主显示器上显示。

## 适配新的 Dock 构建

1. 新系统上 payload 会在日志里写出 `Unknown Dock build <UUID>`，什么也不装。
2. 用 `idax binary --arch arm64e` 为新 Dock 建 IDA 库，并用 swift-section 导出头文件（见 reverse-engineering skill）。
3. 找 `DockBar` 全局变量：在 `-[DockBarSystemDefinedEventHandler handleSystemDefinedEvent:type:]` 等方法里看它从哪个全局变量取 `DockBar`。找 `DockGlobals` 全局变量：`+[DockGlassMaterialLayerController currentDockMaterialEnvironmentWithColorScheme:]` 会读它和 `DockBar` 的全局变量，两个都空就 `brk`。
4. 在 `DockBuildProfile.knownProfiles` 加一条（UUID、版本、两个地址），部署到测试机，看日志里 `Checked N Dock method(s), M mismatch(es)`：有不符的，日志会写出新的类型编码，逐个核对后更新签名。

## 延伸阅读

- [术语表](../Glossary.md)
- 15.5 的界面规格：`/Volumes/RE/Dock/15.5/Notes/LaunchpadMainInterface.md`
- 15.5 的文件夹与拖动：`/Volumes/RE/Dock/15.5/Notes/LaunchpadFoldersAndDragging.md`（建文件夹与放进文件夹的逐帧时序在 4.11）
- 15.5 的背景与进出场、27.2 的壁纸来源：`/Volumes/RE/Dock/15.5/Notes/LaunchpadBackgroundAndAnimations.md`
- 27.2 的 `EC*` 图层与图标：`/Volumes/RE/Dock/27.2/Notes/ECLayerReuse.md`
- 27.2 的玻璃材质：`/Volumes/RE/Dock/27.2/Notes/GlassMaterial.md`
- 捏合手势：`/Volumes/RE/Dock/27.2/Notes/PinchGesture.md`
