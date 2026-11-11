# Launchpad 复刻：实现说明

> 配套提案见 [在 macOS 27 的 Dock 中复刻 macOS 15 的 Launchpad](../Evolutions/draft-launchpad-replica.md)。
> 本文记录实际落地的实现、与提案的差异，以及当前覆盖范围与已知降级。面向维护者。

## 背景与目标

payload 注入 macOS 26.0 到 27.2 的 Dock，接管所有「打开 Apps」的入口，在 Dock 自己的窗口与图层类上画出 macOS 15 的 Launchpad。布局首次从 15 留下的数据库导入，之后存在 `~/Library/Application Support/LaunchpadAwakener/Launchpad.db`。完整动机见提案。

## 关键设计决策

**两个全局变量在运行时按类认出来，不按构建记地址。** `DockGlobalScanner` 扫 Dock 可执行文件 `__DATA` 段里的 `__common`、`__bss`、`__data` 三节，把每个指针槽当候选试一遍：槽里的值过了三道筛子——非空且按指针对齐、`malloc_size` 认得它且块不小于目标类的实例、读出的类正好等于目标类——那个槽就是全局。这个判断本身就是「要找的是什么」的定义，所以不需要另一张表来给它背书。

这替掉了原先的 `DockBuildProfile`：一张以 Dock 可执行文件 UUID 为键、记着两个全局变量地址的表，有 17 条，每条都要人工下固件包、建 IDA 库、从反汇编里读出两个数字。那张表漏一条整个功能就不生效（26.7 上发生过），而且它以 arm64e 切片的 UUID 为键，27 的 Dock.app 却有 `arm64e` 与 `arm64e.x1` 两个切片两个 UUID。扫描不比对 UUID，所以 26 与 27 的任何构建都直接工作。完整取舍见提案[在运行时找出 Dock 的两个全局变量，取消构建白名单](../Evolutions/draft-runtime-dock-global-discovery.md)。

**扫描为什么不会碰坏 Dock。** 数据段里全是别处留下的值——小整数、没映射的地址、指向块内部的指针、函数地址——每一个都会走到这三道筛子，所以每道都不能解引用还没证明过的内存。`malloc_size` 对任意野指针安全：它逐个内存 zone 调 `zone->size(zone, 指针)`，各 zone 的实现只比地址范围、不属于自己就返回 0（libmalloc 的 `malloc.c`，`malloc_size` 与 `_find_registered_zone`）；返回非 0 还顺带证明这个指针是某个 malloc 块的起始，而不是块内部。读类只读那个堆块头部的 8 字节、按 isa 的格式掩码，拿到的类指针只做比较，绝不向候选发消息。拿类这一步走 `dlsym` 取到的 `object_getClass` C 入口，而不是 Swift 导入的那个版本：后者要先把候选变成 Swift 对象引用，而 `takeUnretainedValue()` 返回的是 ARC 管的值，编译器可以对它插 retain，retain 一个不是对象的东西就会去读一个垃圾 isa。槽里的指针没有指针认证签名——反汇编里取它用的是裸 `LDR X0, [X22]`，前后没有任何 `AUT*` 指令。

**扫描不当装 hook 的闸门。** 它在第一次真用到时才跑，找不到不缓存、下次重试。注入可能发生在 Dock 启动后 250 毫秒内（App 每 250 毫秒轮询一次新的 Dock 进程），那时 Dock 还没建好这两个单例，把扫描当闸门会把正常启动判成失败。而且五个用到 `DockBar` 的地方本来就都处理了拿不到的情况并各自降级（Dock 不滑走、玻璃背景不画、厚度取默认值、「点在 Dock 上」判否、刘海按 0 算），所以扫不到并不致命。控制面板显示的可达性由它每次刷新时现场问 payload，答案因此总是当下的。

**扫出多个槽位不算问题，扫出两个不同对象才算。** `DockBar` 与 `DockGlobals` 都是进程单例，Dock 从好几处读同一个全局，多个槽持有的必然是同一个对象，用哪个都一样。真扫出两个不同实例时一个也不用，并留一条日志——与 hook 要么整批装要么一个不装是同一个取向。

**`DockBar` 只能经全局变量拿到。** 27.2 里没有任何导出的路径通向它；`-[DockBar rect]` 和 `-[DockBar setRollTile:]` 在鼠标划过 Dock 时都不会被调用，所以「hook 这两个方法、在调用时记下接收者」的办法拿不到它（原型试过）。`DockGlobals` 同样只能经全局变量拿到。而全局变量本身在二进制里没有符号（Dock 被 strip 过，3116 个符号里只有 2 个数据符号），也没有任何属性链爬得过去——`DockBar` 没有单例访问器，五个事件处理器都不持有它，整个导出面里只有 `Tile` 有 `dock` 属性而 `Tile` 自己就难以随时拿到。所以认它只能靠它持有的对象是什么类。`DockGlobals` 的类名两个都试：26 上是 Objective-C 类 `DockGlobals`，27 改写成了 Swift，运行时名是改编过的 `_TtC8DockCore11DockGlobals`，哪个在这个系统上存在就用哪个。比较一律按类对象，不比类名，因为运行时给 Swift 类的名字是 `DockCore.DockGlobals`，不是查找它用的那个改编名。

**26 与 27 用同一套复刻。** 26 的 Dock 里旧 Launchpad 的类（`Springboard`、`LPSpringboard`、`ECSB*`、`ECPager*`）都还在，但 23 处入口经一个恒返回 1 的函数一律改道到 `-[Spotlight sendLaunchAppsBrowsing]`，和 27 一样，所以拦这一个方法就接管了 Launchpad 键、Dock 上的 Apps 图标、触发角与 Apps 本身。复刻调用的 23 个方法与两个 hook 在 26.0 到 27.2 的每个构建里签名都相同。几处差别：26 的 `-[DockAppEventHandler handleMachMessage:size:]` 在 Exposé 或旧 Springboard 捕获事件时不调 `handleDockBarEvent:type:`（后者在 26 上从不捕获，Mission Control 打开时复刻收不到事件，和 15 一样）；26 的玻璃控制器没有 `updateUsingLayoutConfiguration:environment:`，可选的玻璃背景退回模糊；26 与 27.0 的 Dock 自己接捏合（见已知降级）；26 的壁纸窗口（`Wallpaper-`）还是 Dock 自己画的，和 15 一样，到 27 才归 WindowManager（`Wallpaper`）。所以截壁纸时按属主进程认窗口：WindowManager 的优先，没有就用 Dock 自己的。不按属主名认，因为那是本地化的名字，中文系统上 26 的 Dock 叫「程序坞」。

**事件入口：hook 事件总入口加抢键盘焦点，不全局抢占事件。** 打开时 `CPSStealKeyFocusOnConnection(cid, 1152)`，关闭时归还，事件经 `-[DockAppEventHandler handleDockBarEvent:type:]` 接管——这正是 15 的做法。没有走 27 的 Cmd-Tab 切换器那种自建连接加 `CGSSetEventCapture`：一旦失控，整台机器的输入都会被锁住，26 上那次只能重启就是这种情形。也没有改用 `ECModalEventController`：它自建连接时只按 Dock 栏窗口的坐标做命中测试，处理者栈又与堆栈展开、Cmd-Tab 共用，打开 Launchpad 时会互相挤掉。

**判断「点在 Dock 上」只能用 `DockBar` 的 `rect`。** 27.2 的 Dock 窗口几乎铺满屏幕，用窗口范围判断会把所有点击都当成点在 Dock 上。

**payload 里不用 AppKit，也不用 `Bundle.module`。** 27.2 的 Dock 不链接 AppKit，字体一律用 Core Text 建，显示器信息用 CoreGraphics 和 Dock 自己的 `DisplayDescriptor`。SwiftPM 生成的 `Bundle.module` 找不到资源时直接 `fatalError`，在注入的框架里就是让 Dock 崩溃，所以 15.5 的 `LaunchPadLayout.plist` 只放在测试资源里，排除名单与默认首页以 Swift 常量随 payload 发布，由测试逐项核对。界面贴图（`ecsb_*`、`ectl_*`）在运行时从 Dock.app 里读，26 与 27 的 Dock.app 都带着这些文件。

**调 Dock 内部方法一律先校验签名。** 系统框架导出的私有类（IconServices、QuartzCore 等）在 `LaunchpadAwakenerPrivateInterfaces` 的头文件里声明后直接调用，不在运行时核对；Dock 不导出任何类，它的调用与 hook 都经 FrameworkToolbox 的 ObjCRuntimeToolbox，选择子与类型编码一律由 Swift 声明推出、参数类型经编译器检查，代码里没有手写的编码：两个 hook 是 `@RuntimeClassHook`；类名固定的类写成 `@RuntimeClassProxy` 协议，构造写成 `init?(…)`、类方法写成 `static func`、卸载的回调写成 `@escaping @convention(block)` 参数；经环境对象拿到的 Swift 类（`IconAppearance`、卸载器等）类名随版本变（环境对象在 26.6.2 叫 `Environment`，27.2 叫 `_TtC8DockCore11Environment`），写成 `@RuntimeObjectProxy` 协议，按对象自己的类核对。`DockHostInterface.requiredMethods` 汇总了界面层要调的 23 个 Dock 方法（各 proxy 的 `methodRequirements`，构造方法也在内），任何一个的类型编码与 Dock 不符，就整批不装 hook；`DockSignatureTests` 在开发机上把推出的编码与 27.2 元数据核对。经对象拿到的类在第一次遇到时校验，失败就降级。两个容易错的地方：`EC*` 类的 `scaleFactor` 都是 `float`（编码 `f`），proxy 里写成 `CGFloat` 编码就对不上；头文件里的 ivar 偏移是编译期的值，运行时会滑动，要用 `ivar_getOffset`。

**每页一个 Dock 的 `ECGridLayer`，内容变了就换一个新的。** `ECGridLayer` 只在初始化时问一次条目数，之后没有入口能改；15.5 的 `ECSBGridLayer` 是直接改父类 ivar 来增删图标的。这里选择页内条目一变就重建整页网格，代价可以忽略（一页最多几十个图层）。另外三点：`-[ECGridLayer layout]` 不是 `layoutSublayers`，Core Animation 不会自动调，要宿主调用；数据源被弱引用，由 `SpringboardPageGrid` 持有；`makeLayerForLayer:` 在协议上是可选的，实际必须实现。

**图层类不碰主线程隔离的单例。** Swift 写的 `CALayer` 子类必须实现 `init(layer:)`，Core Animation 做动画时会用它复制出呈现层；这些子类保持不隔离，图标由主线程上的 `SpringboardInterface` 查好再交给图层，图层自己不调用 `@MainActor` 的单例。首次布局一律关掉隐式动画，否则图层会从零尺寸「长」出来。

**自己的库沿用 15 的表与触发器，编辑时改为整组重排。** 导入与追加靠 15 的触发器维护 `ordering`；拖动类的编辑则先关掉触发器（`dbinfo` 的 `ignore_items_update_triggers` 置 1），把涉及的父项的子项按新顺序整组写回、编号从 1 开始，再打开触发器。被移动的项在同一个事务里先挂到父项 -1 上，否则之后再读兄弟列表时它还会出现在原处。编辑后照 15 收拾：一页超过容量就把末尾几项挤到下一页开头，空的文件夹页、文件夹和页面删除。任何把 App 移出文件夹的编辑——移到页上、移进别的文件夹或别的文件夹的页上、建新文件夹——都让只剩一个 App 的原文件夹解散。

**布局里的一个 App 条目只代表它书签指向的那一份 App。** 书签还能找到、那份 App 的 bundle ID 也没变，条目就留着，装在搜索目录以外的也一样。书签找不到，或那份 App 已被换成别的 bundle ID（Setapp 版、自编的分支原地顶替了直装版），条目就删掉；两个条目指向同一份 App 时，后一个也删掉。只有没存书签的条目才按 bundle ID 认：搜索目录或 LaunchServices 里任何一份还没被别的条目占着的副本都算它的。搜索目录里没有条目指着的副本一律当新 App 加进来，所以装了几个版本的 Xcode、IDA 各有各的图标、各开各的，与 15 一样。

原来的规则是「搜索目录里没找到、书签解析不到、LaunchServices 也不认识」三者都成立才删，结果出了两种重复：App 原地换了 bundle ID 后，旧条目的书签还指向同一个文件，一直被当成还装着，新 ID 又被当成新 App 加了一遍；删掉的旧版 Xcode 因为系统里还有同 ID 的别的 Xcode，也一直留着。另外，读 bundle ID 不能用 `Bundle(url:)`：它在进程里按路径缓存第一次读到的 Info.plist，Dock 一跑好几天，原地替换的 App 会一直读成旧 ID，所以发现与对账都改用 `CFBundleCopyInfoDictionaryForURL` 每次从磁盘读。

唯一的例外是「打开 Launchpad 或 Apps 的启动器」——27 的 `Apps.app` 与独立版 Launchpad（bundle ID 以 `com.MxIris.LaunchpadAwakener.Launchpad` 开头），它们装着也照样从布局里拿掉（`ApplicationExclusionList.isLaunchpadLauncher`）：独立版装进 `/Applications` 时曾被当作新 App 加进注入版的布局。排除名单的其余部分只挡新加入，不拿掉已在布局里的：15 的规则会把名字带 Uninstall 的 App 排除在外，可已经在布局里的（测试机上的 App Cleaner & Uninstaller）照样留着，与此前的行为一致。

**图标与 Dock 栏同一套样式。** 描述符复制自 `DockBar.environment.iconAppearanceMonitor.appearance.iconDescription`，再经 IconServices 的 `-[ISIcon initWithURL:]` 取图（IconServices 导出这些类，在 `LaunchpadAwakenerPrivateInterfaces` 里声明后直接调用）；Dock 自己走的 `_LSBindingCreateWithURL` 是没有任何声明可依的 C 函数，所以没用。图标在后台队列渲染，布局一加载就全部预取（MacBook 上 149 个约 2 秒，之后命中 IconServices 的缓存只要几十毫秒）。

**给 Dock 留的高度照 15 从格子大小算，不量 27 的 Dock 栏。** 15 留 `ceilf(tileSize + distanceTop + distanceBottom)`：格子是设定的图标大小加两侧各一个内边距，上下留白按格子大小查一张表（15.5 `0x1000DBB44`），默认大小下是 68 + 1 + 10 = 79 点，与 15.5 虚拟机里量出的网格吻合。27.2 算格子的方法没变（`0x10001149C`），只是玻璃 Dock 换了一张表（`0x100078598`）：格子上方留 5 到 6 点（15 是 0 到 2），整条栏默认 94 点高。最初按栏高留位置，又误以为 15 只留约 59 点（逆向笔记把格子当成了 48 点），结果在 1487×936、1512×982 这类屏幕上图标比 15 小一档。现在经 `-[DockBar desiredTileSize]` 与 `tileSize` 读格子大小，套 15.5 的表算（`SpringboardMetrics.dockThickness(desiredTileSize:tileSize:)`）；Dock 放不下、格子被缩小时，留白按缩小后的格子查表，与 15 相同。代价是界面比 15 更贴近 Dock：27 的栏比 15 高出的约 15 点不再另外留出。

**文件夹照 15 用图层画，缩略图交给 Dock 的 `ECImageGridLayer`。** 15.5 根本不引用 Dock.app 里的 `ecsb_group`、`ecsb_arrow_*` 等贴图（10.7–10.9 时代的遗留），文件夹图标是半透明浅色方圆加 3×3 缩略图。`ECImageGridLayer` 与 `ECGridLayer` 不同，`layerSourceInvalidated:` 之后会重新问条目数，所以换内容不必重建；它不保证子图层顺序，取缩略图时按位置排序。

**选中项跟着前面的那组页面走。** 方向键、Return、Command-方向键作用于前面的页面：开着文件夹时是文件夹的，否则是主页的，规则照 15 的 `-[ECSBGroupPager navigate:withEvent:]` 与主页相同（`SpringboardKeyCommand`）。用键盘打开的文件夹（Return 或 Command-↓）在打开动画结束后选中第一项，点开的不选；文件夹关上后主页没有选中项，只有 Command-↑ 关上的会选中这个文件夹。选中的图层单独记着，翻页后旧页上的高亮会被清掉，此前翻回去还能看到残留的高亮。

**新装 App 的蓝点照 15 存在库里，标记与清除的时机按 27 能拿到的信号近似。** 15 的蓝点就是 `items.flags` 的 0x400 位：App Store 下载完成时置位，Dock 听到这个 App 启动时清除，跨重启保留，从 15 导入的库里也带着。27.2 的 Dock 只在 Swift 内部处理 App Store 下载完成，没有可替换的入口，所以复刻在对账时给带购买收据（`Contents/_MASReceipt/receipt`）的新 App 置位，首次建库不置位；从 Launchpad 启动时清除，每次打开前再看一眼带蓝点的 App：Spotlight 记的最近使用时间晚于这份拷贝放进来的时间，就算启动过，清掉（`RecentlyAddedApplications`）。没有 hook Dock 的 `handleApplicationLaunchNotification:time:data:asn:`：它的数据内容没逆向，而且每个 App 启动都会经过它。圆点照 15 的 `ECFlagLayer`（9 点圆、`GenericRGB(0, 122/255, 1)`）挂在标题图层上，随标题一起移动和淡入淡出；放不下时标题缩短、右移半个标记宽并左对齐，规则照 15。

**删除 App 用 Dock 自己的卸载器，确认由文本输入辅助进程弹真的 `NSPopover`。** 15 在抖动模式里给卸载器认可的 App（App Store 的、网页 App、快捷指令、带包装容器的）显示关闭按钮，按下后由 `com.apple.dock.ecap` 服务弹一个 `NSPopover` 确认，确认后经 `DockCore.SystemApplicationUninstaller` 交给 `uninstalld` 删除。卸载器判断能不能删，第一条只看 `Contents/_MASReceipt/receipt` 在不在，不读内容（15.5 `+[UNUninstallRequest uninstallablityOfFileAtURL:]`），所以对照用的 15.5 虚拟机里放一个带空收据的 App 就能看到原版的删除（见项目 `CLAUDE.md`）。27.2 的 Dock.app 里已经没有 ecap 服务，卸载器却还在（`DockBar.environment.applicationUninstaller`，Objective-C 可调，只是 Dock 自己不再调用）。复刻的关闭按钮照 15 用 Dock.app 的 `ecsb_closebox` 贴图，按下换 `ecsb_closebox_pressed`；能不能删在开始抖动时问卸载器（`uninstallabilityOfFileAtURL:` 为 1），每次打开问一遍。确认照 ecap 的做法，由下文的文本输入辅助进程弹出（逆向见 `/Volumes/RE/Dock/15.5/Notes/LaunchpadFoldersAndDragging.md` 第 6.3 节）：

- **上屏**：15 的气泡是 ecap 进程里一扇直接上屏的真窗口，不经 `CALayerHost`。辅助进程照做：把一扇 16×16 的透明锚点窗口挪到图标中心，以中心 20×20 的矩形、下边弹出 popover，再把 popover 窗口抬到层级 106，盖在 Launchpad（27）与 Dock（29）之上。锚点窗口不接点按，层级同样是 106，AppKit 把 popover 挂在它上面时也不会被压到 Launchpad 下面。锚点必须是 nonactivating panel：弹出时 popover 窗口照抄锚点窗口的这一项（26.6 `-[NSPopover showRelativeToRect:ofView:preferredEdge:]`），而在辅助进程这种不是活跃 App 的进程里，只有 nonactivating 窗口能成为 key；只有 key 窗口才把「删除」画成默认按钮。最初用普通的无边框窗口当锚点，「删除」就和「取消」一个样子。15 的锚点 mini view 窗口同样自称 nonactivating（逆向笔记见 `/Volumes/DyldSharedCaches/macOS/26.6/AppKit/Notes/DefaultButtonAndPopoverKey.md`）。
- **内容**照 ecap 的 nib：宽 400，图标 64 点在左上 (10, 10)，问句 13 点、最宽 304，右下是取消与删除，删除是默认按钮。高度随系统按钮而定，不低于 84。外观跟随系统，所以是 26/27 的玻璃样式，不是 15 的。图标由 payload 编成 PNG 发过去，与 15 相同；解不开时用 App 自己的图标。
- **按键与点按**：点按钮由窗口服务器直接送到辅助进程，它只回报按了哪个，自己不关。弹出后把 popover 窗口设成 key：AppKit 经辅助进程覆写的 `_stealKeyFocusWithOptions:` 认为拿到了焦点，系统键盘焦点仍在 Dock。普通按钮第一下点按就生效（`acceptsFirstMouse` 为 YES），不要给按钮设 `hasDestructiveAction`，那会吞掉第一下。键盘不转发：Return、Enter 删除，Esc 与 Command-句号取消，都由 Dock 判断。背景不变暗，点气泡以外被吞掉、没反应。
- **关闭**总由 Dock 发起：按钮、按键，或 Launchpad 开始收起（按取消处理，与 15 相同）。关闭后若辅助进程正托管着搜索框，把 key 窗口交还给那扇窗口，转发来的键才不落空。15 等服务关好才删；复刻关闭请求一发出就开始删除动画，气泡同时淡出。
- **辅助进程不在时**：连不上或弹不出，退回界面层自己画的气泡（`SpringboardDeletionPanel`，照 ecap 的尺寸画的平面近似）；气泡显示中辅助进程退出，按取消处理。一次只问一个 App，与 15 相同。

文案 27 的 Dock.app 里没有了，取自 15.5 Dock.app 的各语言 `Localizable.strings`（`SpringboardDeletionStrings`），两种气泡共用。确认后照 15 先用 0.5 秒把图标缩到一成并淡出，再调卸载器；成功后本页在 0.25 秒内补上空位（后面的页不前移），库删掉这个 App；失败时图标在原处恢复（15 是放到下一个空位）。卸载是永久删除，不进废纸篓，连同偏好设置与容器一起删，正在运行的会先被要求退出、再被强制结束，与 15 相同。

**拖动时自己摆放图标，不经 `ECGridLayer` 布局。** `ECGridLayer` 的布局在内部关掉隐式动画，借它没法做出 15 那种 0.4 秒的让位动画；拖动期间按「排列」（当前页的条目按新顺序排好、被拖的那个占一格）逐个设图标的 frame。被拖的图层离开网格挂到容器最上层跟手。松手时一次性写库，库发布的新布局再重建页面；拖动或文件夹开合期间到达的新布局先存着，动作结束后才换上（`replaceLayout` / `applyPendingLayoutIfIdle`）。

**拖搜索结果，就是从它真正所在的地方拖。** 15 在搜索结果上一开始拖就退出搜索（`-[ECSBDragCapture _cancelFiltering]` 及其两个完成回调）：结果层 0.25 秒淡出，搜索框清空、回到搜索前的那页，被拖的 App 挪到这页末尾，页面再淡入；期间图标照常跟手，别的都不响应，松手与 Esc 等页面进来后才处理；页面回来后 15 不立刻让位，等下一次移动，复刻同普通拖动一样等指针慢下来才让位。复刻照这个顺序做。拖动的来源记的是 App 在布局里的真实位置（`SpringboardDragging.location(of:in:)`）：在某页上就当作从那页拖起，在文件夹里就当作从那个文件夹拖出，所以松手时写的是「移到这里」或「移出文件夹」，Esc 时滑回那页或滑进那个文件夹的图标。这个 App 自己在各页上的图标先拿掉，由被拖的图标代表它，接到页末时页满了就占最后一格（那格原来的图标松手时挤到下一页，与拖出文件夹、拖到边缘翻页相同）。它所在的文件夹在松手前照旧显示它；悬停弹开这个文件夹时，面板里它自己的图标同样拿掉。Esc 时若来源文件夹正开着，面板按库里的文件夹重建、图标滑回原格；开着的是别的文件夹，就先关掉它，再滑进来源文件夹的图标。

**建文件夹先在界面上做出来，库稍后跟上。** 15 的三条路径都照逐帧时序复刻（RE 笔记 4.11）：快速松在 App 上，目标的格子当场换成文件夹图标，两张图片先后缩进缩略图，0.75 秒后自动弹开；停住 1 秒，弹开一个只有目标的文件夹，被拖的图标在面板里继续摆放；快速松在文件夹上，图片缩进缩略图、文件夹不打开。界面上的文件夹在库写好之前没有真实的标识符，用一个负数标识符的「未存的文件夹」代替；库发布的新布局到达时，再按第一个 App 找到真正的文件夹接上（`storedFolder(for:in:)`）。停住 1 秒弹开的那个文件夹在松手前根本不写库：在面板里松手时写一次建文件夹（顺序按面板），拖回面板外就在界面上解散，库里什么也没发生过。

**主页的空位跟着文件夹走。** 拖进文件夹（弹开的或快速松手后自动弹开的）时，被拖图标在主页上留下的空位不立刻合拢，而是保留到文件夹关上后 250 毫秒，这期间主页不按新布局重建（`mainPagePlaceholder`）。从文件夹里拖出时同样等面板关上 250 毫秒，主页才让位，只剩一个 App 的文件夹此时解散成那个 App。

**打开的文件夹是另一个翻页器。** 15 的 `ECSBGroupLayer` 本身就是 `ECPagerLayer`，所以主界面与文件夹共用 `SpringboardPagedGrids`（滚动层、页码、跟手、回弹、滚轮停顿）。面板只是一层白色 97%、不透明度一半的圆角矩形，不模糊身后：15 虽然建了 `CABackdropLayer` 并给了模糊 30、饱和度 1.8，但设在 `backgroundFilters` 上，backdrop 并不执行。macOS 15.5 虚拟机里打开文件夹时，正在淡出的主网格透过面板清晰可见，只被白色冲淡；同一台虚拟机里程序坞的 backdrop 照常模糊，可见不是虚拟机做不了模糊。面板看起来像毛玻璃，靠的是身后本来就模糊的壁纸背景。开合动画里动的是面板的形状，承载内容的容器始终铺满，靠遮罩裁出面板。开合时照 15 只动格子里的图片与标题：打开前把第一页每张图片缩到文件夹图标对应的缩略图上、标题放到图片下方并隐藏，页面随一个缩到文件夹单元格上的容器平移；打开时这些都在同一个事务里用隐式动画回到原位，与面板保持同一节奏。关闭反过来，且始终收第一页。三处容易做错：不能缩放整个格子（标题会跟着缩小）；不能用显式的线性动画（与面板的默认缓动不同步）；Dock 的 `ECGridLayer` 默认裁剪格子，要照 15 的 `ECSBGridLayer` 关掉，否则缩略图上的图片会被页面边缘裁掉。动画期间格子的图片与标题暂停排版（`isPictureAndTitleLayoutSuspended`，相当于 15 的 `disableLayout`），否则动画开始前的一次排版会把它们放回原位。这些动作都在 macOS 15.5 虚拟机里和真机录屏逐帧对照过。

**Launchpad 开着时 Dock 一直露着，文件夹开着时 Dock 滑走。** 15 显示 Launchpad 时，给 Dock 的显隐控制器 `DockVisibility` 设一个显示覆盖（`setOverrideShowType:1`），开了自动隐藏的 Dock 也会露出来。文件夹面板一开始打开，它就调 `forceDockHiddenWithReason:`，Dock 借自己的自动隐藏滑走，默认大小下约 0.24 秒。面板一开始关闭、或 Launchpad 开始退场时撤销这个隐藏，显示覆盖则等退场动画结束才撤（`-[Springboard groupShownForItem:atIndex:]`、`groupHiddenForItem:`，15.5 `0x100093500`、`0x1000935A4`）。5 行的文件夹面板底边正好落在给 Dock 留的那条线上，靠的就是这一步。复刻起初漏了它：27 的玻璃 Dock 比 15 的高，面板于是压进了 Dock 底下。现在的分工是：界面层记录文件夹是否开着（`isFolderOpen`，从面板开始打开到开始关闭）；控制器把它与显示、退场合成 `SpringboardDockVisibility` 交给宿主；注入版的 `DockBarVisibility` 只在状态变了时调 Dock。
- 撤销一个 Dock 没登记过的原因，Dock 会抛异常、直接崩溃。所以只在拿过的那个对象上撤销，撤销前先读 `_dockForceHiddenReasons` 确认原因还在，原因也用自己的字符串 `LaunchpadAwakener-ShowGroup`。
- 重新显示时，先不撤上一次的显示覆盖、显示完再设（`finishHiding(updatingDockVisibility:)`）。否则开了自动隐藏的 Dock 会先开始滑走，再被叫回来。
- 这几个方法在 26.0、26.6.2、27.2 与 15.5 里签名相同；任何一个对不上，Dock 就保持原样，payload 启动时在日志里写明缺了什么。
- 独立版的窗口一直盖着 Dock，不需要这一步。
- 调用链与时长见逆向笔记 `/Volumes/RE/Dock/27.2/Notes/DockVisibilityAndFloor.md`。

**界面按屏幕尺寸铺，不按窗口根图层。** `WALayerKitWindow` 的根图层在建界面时 bounds 还是 0×0。图标的位置都由屏幕尺寸算出，不受影响，但按根图层定大小的容器与背景就成了 0×0：最初的壁纸背景因此看起来是透明的，换成玻璃后也只在屏幕左下角露出一小块。

**图标缩放时只设 bounds 与 position。** 解散中的文件夹图标缩到一成、被拖的图标放大到 1.1 倍时，页面可能正好在让位；给带 transform 的图层设 `frame`，Core Animation 会按缩放后的尺寸反推 bounds，图标恢复原大后就大了十倍、跑出原格。让位一律用 `setUntransformedFrame(_:)`。关闭文件夹的动画也只处理还在面板里的图标：网格的列表里仍有被拖出去的那个，碰了它就会在手上消失。

**新建的图层先提交上屏，再做动画。** Core Animation 不给从未提交过的图层做隐式动画。打开文件夹时面板、图标都是新建的，所以先在关掉动画的事务里摆好起点（面板缩在文件夹图标的方圆上、图片缩在缩略图上），`CATransaction.flush()` 提交，再开始动画；图标缩进缩略图、文件夹解散也是这样。漏掉这一步的症状就是「打开没有动画、关闭有」。

**改名只从标题文字上开始；会在眼前换的字一律直接换上。** 15 只认落在标题图层上的按下（这个图层只比文字宽 4 点），松手在哪都进入改名（`-[ECSBGroup leftMouseDown:in:]`、`leftMouseUp:in:`）。标题左右各宽 200 点的那一块是编辑框，平时隐藏，改名时框内的按下全被文本框收下，所以框内点击不结束改名（`isInTitleEditor`）。最初照逆向笔记把这一块当成了点击区，点标题那一行的空白处也会开始改名；现在那里照「面板外」处理，一按就关文件夹，用户在 15.5 上确认 15 也会关。另外，Core Animation 默认给文字图层重画出的新内容做 0.25 秒的交叉淡化：标题居中，每打一个字整行左移半个字宽，新旧两行于是叠在一起闪一下。改名的编辑框、标题标签与搜索框的文字图层因此都关掉了 `contents` 的隐式动画（`disableTextCrossfade()`）。单元测试里要先把图层交给离屏的 `CARenderer` 提交一次，它才会像屏幕上的图层那样做隐式动画，否则修没修都看不出差别。

**改名框照 15 的文本框编辑，选区自己维护。**（独立版经系统输入法组字时，组字中的文字也记在这个编辑模型里，见独立版实现说明「输入法经窗口的内容视图接」。） 15 的改名框是 Dock 的 `com.apple.dock.ecti` 服务里一个真正的 `NSTextField`，经 `CALayerHost` 贴进 Dock 的图层。服务一建好它就调 `selectText:`，所以进入改名时整个名字是选中的，打字直接替换；方向键、Shift 扩选、点击放光标、拖选、双击选词都是它字段编辑器的标准行为；Return、Enter 与 Esc 都结束编辑并按当前文字提交，Esc 并不撤销。复刻里没有 AppKit，改由 `SpringboardTextEditing` 维护文字与选区：按用户看到的整字计数，中文、emoji、带附加符号的字母都不会被拆开；按词移动用 Foundation 的分词，中文也按词。`SpringboardTextEditingCommand` 照标准键位把按键读成命令，编辑框按 Core Text 量出的字间位置画选区和光标。文字居中，放不下时横向滚动，只滚到光标看得见为止，不再在开头显示省略号。选区色 `#3F638B` 与光标、选区的高度是在 15.5 虚拟机的截图上量的，是深色外观下系统默认的选中文字色，不随系统强调色变化。复制粘贴走 HIServices 的 Pasteboard Manager（Dock 本来就加载了它，payload 用不了 AppKit 的 `NSPasteboard`），撤销是自己的快照栈，一段连续输入算一步（`SpringboardFieldEditor`）。这套本地编辑在下文的文本输入辅助进程不可用时才用；有它时，两个框都由它托管。

**搜索框与改名框共用一套编辑，按键照 15 分流。** 搜索框也由 `SpringboardFieldEditor` 维护文字、选区与撤销，光标画在实际位置，选中的部分用改名框同样的颜色，放不下时横向滚动，点击放光标、拖选、双击选词。哪些键归搜索框照 15 的 `-[ECSBLayer keyDown:]`：Tab、Return、Enter、Esc、↑↓ 从不给它；← 只在它有焦点时给它，→ 还要有文字；Command-方向键翻结果页；其余键先激活搜索框再交给它，所以没点进去时直接打字、删除、粘贴也行。

**输入法靠一个托管文本框的辅助进程，照 15 的 ecti 服务做**（提案 [用常驻辅助进程给搜索框与改名框接上输入法](../Evolutions/0001-input-method-helper.md)）。Dock 不加载 AppKit，输入法只认真正的文本框和激活状态的进程，所以 App 里多带一个 LaunchAgent `LaunchpadAwakenerTextInput`：

- **启动**：它放在 `Contents/Library/LoginItems/`，App 启动时用 `SMAppService.agent` 注册，不用用户批准。launchd 在 payload 连它的 Mach 服务时才拉起它。它只接受 Dock 的连接（见下文「几处细节」）。
- **通道**：系统 XPC 框架的 Swift 接口（提案 [文本输入通道改用系统的 Swift XPC 接口](../Evolutions/0008-text-input-swift-xpc.md)）。payload 一侧是 `XPCSession`，辅助进程一侧是 `XPCListener`，都在主队列上收发；消息是 `LaunchpadAwakenerShared` 里的 `Codable` 类型：payload 发 `TextInputRequest`（`begin`、`setString`、`setFocus`、`end`，以及删除确认的 `presentDeletionConfirmation`、`dismissDeletionConfirmation`；`begin` 回 `TextInputHosting`，`end` 回 `TextInputEnding`，`presentDeletionConfirmation` 回 `DeletionConfirmationPresentation`），辅助进程发 `TextInputHelperMessage`（文本框的变化，或删除确认按了哪个按钮）。消息按发送的先后处理。辅助进程一退出 session 就作废，payload 丢掉它，下一次 `begin` 再建一个，launchd 随之重新拉起辅助进程。
- **托管**：它在 Dock 图块的 mini view 窗口里放一个 `NSTextField`，那扇窗口能成为 key 窗口。payload 用 `CALayerHost` 显示这扇窗口的图层托管上下文；窗口本身虽在屏上，却是完全透明的（见下文「与 15 不同的地方」）。
- **转发**：payload 把这些事件复制一份，标上辅助进程的窗口编号与窗口内位置，用 `CGEventPostToPid` 发过去：
  - 搜索框该收的键；正在组字时是所有键；
  - 改名时的所有键；
  - 框里的点按与拖动。
- **回报**：辅助进程回报不含组字部分的文字、是否在组字、改名时是否按了 Return、Enter 或 Esc。输入法不让文本框报告组字，所以它用一个改写了 `setMarkedText`、`unmarkText` 的字段编辑器来报。
- **删除确认**：它还照 15 的 ecap 服务弹删除确认的 popover（见上文「删除 App」）。15 的 ecti 与 ecap 是两个服务，复刻并进这一个进程，共用连接与只认 Dock 的规矩。

与 15 不同的地方：

- 27.2 的 Dock 不再告诉 AppKit「mini view 已显示」，辅助进程要自己调 `_setMiniViewShown:`，否则窗口成不了 key，按键进不去。
- 窗口层级要设成 27，候选窗才出现在 Launchpad 上方。
- mini view 窗口显示过一次，AppKit 就把它一直留在屏上：第 27 层，正好在框的位置，界面收起后也不撤。辅助进程把它设成完全透明（`alphaValue` 为 0），屏上只剩 payload 显示的那一份。不透明时有两处露馅：
  - 它比 Launchpad 的窗口晚上屏时（辅助进程刚被拉起后的第一次打开），压在界面上面。点进搜索框再点开文件夹，光标不随主界面淡出，停在文件夹上方。
  - 界面靠点空白处或启动 App 收起后，搜索框里的字留在别的 App 上方，到下次打开才清掉。
  - 15 的这扇窗口不上屏。15 打开文件夹也不改搜索框焦点，光标随主界面一起淡出，关上文件夹后照旧闪；复刻照此不动焦点。
- 辅助进程只托管一个框，搜索框与改名框轮流用：开始改名时搜索框交出去，改完再接回来。每次换框都先结束上一段编辑，字段编辑器才会按新框的对齐方式重建，否则改名框会沿用搜索框的靠左。
- 组字时本地的占位文字「搜索」让开，不与组字中的文字叠在一起。
- 连不上辅助进程、它中途退出时，退回上文的本地编辑；下次打开时 launchd 会重新拉起它。
- 几处细节：
  - 搜索框没有焦点时，托管的框不显示光标，与 15 相同。框一直是第一响应者，只把光标颜色设成透明，转发来的键才不会落空。
  - 改名时还在组字就点到别处，辅助进程收尾时把组字原样上屏，回给 payload 的最终文字随后补进名字。只认辅助进程真正托管过的框：它还没托管上改名就结束了，名字以本地编辑的为准，辅助进程那次也不回报文字。补写直接写进布局库，界面这时已经收起也不丢。
  - 托管框的位置按几何规格算，不从图层换算：打开的文件夹、捏合与进场动画会让界面暂时缩放，辅助进程却一直用给它的位置放候选窗、量点按。
  - 辅助进程只认 Dock：每个 session 激活前设好签名要求「系统自带的二进制、签名标识 `com.apple.dock`」（`XPCPeerRequirement.isPlatformCode`，macOS 26 才有，更早的系统上一律拒绝），libxpc 逐条消息核对，不符就取消这个 session。要求设在 session 上而不是监听器上：监听器上不符的请求会被悄悄丢掉，设在 session 上才能在日志里留下拒绝记录。新 session 要先发来一条合法请求才接替旧的。Dock 的签名一旦不再有效（比如换了注入方式），它的请求都会被拒、输入法随之停用，辅助进程的日志里会留下拒绝原因。连接管理在 `TextInputPeerListener` 里，不碰 AppKit，测试在测试进程里用匿名监听驱动它。
  - 部署换掉了辅助进程的可执行文件时，它在下一次 `begin` 时自行退出，那一次退回本地编辑，再下一次由 launchd 拉起的新版本托管。收到解不开的消息时（新的 payload 改了消息格式）它也检查一次，所以以后改消息格式不必手动结束旧进程。

**背景默认是 15 的模糊壁纸，Dock 自己的液态玻璃是选项。** 每次打开都截一张 WindowManager 的壁纸窗口（27 的壁纸窗口归它，每个空间一扇叫 `Wallpaper` 的窗口），用 15 同样的 `SLSHWCaptureWindowList(…, 0x11944)`；截好的图放进栅格化的容器，套 15 的三个滤镜（模糊 30、饱和度 1.8、颜色矩阵压暗），只算一次，App 的窗口被它挡住，与 15 一样。截不到时是 15 自带的径向渐变。中途一度改成玻璃（用户想要更贴合新系统的效果），看过后又改回来，因为模糊效果不如原版；玻璃留作 `springboard-background` 设为 `glass` 时的选项。

玻璃来自 Dock 画 Dock 栏与 Cmd-Tab 切换器的那套控制器：Swift 写的，但经四个 Objective-C 类就能驱动（`DockGlassMaterialLayerController`、`DockGlassMaterialLayoutConfiguration`、`DockSDFElement`、`DockGlassMaterialEnvironment`），每个方法调用前都校验签名，校验不过就退回一层带 15 三个滤镜、由窗口服务器采样的模糊。三个容易踩的地方：

- 取环境的 `+currentDockMaterialEnvironmentWithColorScheme:` 在 `DockBar` 或 `DockGlobals` 还不存在时会让 Dock 直接崩溃，所以调用前两个全局变量都要读到；开发构建的离屏自检也因此等 Dock 起来 5 秒后才建玻璃，并且每个 payload 构建只试一次（在 `/tmp` 里留标记），万一崩了，Dock 重启后不会再试。
- 玻璃固定深色、不随背后亮度变化：图标标题沿用 15 的白字加阴影，浅色玻璃上看不清。玻璃向屏幕四边外扩 64 点，让它的边缘高光落在屏幕外。
- 玻璃由窗口服务器采样，所以界面整体淡入淡出时不能当作一组离屏绘制（`allowsGroupOpacity` 关掉，Cmd-Tab 也这样做），否则淡入期间玻璃后面什么也没有。代价是淡入时图标与玻璃各自半透明叠在一起。

选玻璃时 App 的窗口会被模糊进背景，与 15（只有壁纸）不同。`springboard-glass-variant` 偏好可以换成 Dock 的另外两种玻璃（2 去掉前景效果，4 是 Cmd-Tab 的），下次打开生效。

**捏合读原始 DockSwipe 事件，且默认不接管。** 27 的「拇指加三指捏合」由 Spotlight 进程识别，Dock 的手势系统里已经没有它，`sendLaunchAppsBrowsing` 也不在这条路上；但 WindowServer 仍把 DockSwipe 事件送到 Dock 的连接上。payload 在已有的事件 hook 里照 15 的状态机读这些事件，跟手设可见度，松手后跑 15 的 60 Hz 弹簧。Spotlight 也会响应同一组事件，所以只有 `com.apple.spotlight` 的 `trackpadAppBrowseEnabled` 为 NO 时才接管；不要用系统设置里的「更多手势」开关代替，它很可能让 HID 层不再产生捏合事件。

**抖动模式抖的是图标里的一层，不是图标本身。** 15 的图标里有一层 `jitterLayer` 装着图片、标题、文件夹的方圆与缩略图，抖动只给它加两段永远循环、叠加（additive）的关键帧动画：绕中心转 ±0.0353 弧度（约 2°），以及在四个各坐标为 0 或 −1 点的位置之间游走，周期 0.25 秒，起始相位随机且是 0.05 秒的整数倍。复刻照搬这一层（`SpringboardItemLayer.jitterLayer`）：图标本身的 position 与 transform 留给排版、拖动、放大和文件夹动画用，要是把抖动加在图标上，这些隐式动画一跑就会盖掉它。两段动画都设了 Core Animation 的私有属性 `frameInterval = 0.05`，让抖动按每秒 20 下一跳一跳地走，这正是 15 那种生硬感的来源，27.2 的 QuartzCore 里它还在。抖动是「这几页」的状态（`SpringboardPagedGrids.isJiggling`），文件夹开着时归文件夹，与 15 的 `-[ECSBPager setDeleting:]` 一致；页面重建时新格子自动带上。被拖的、正被悬停的、长按中的图标用 `isHeldStill` 暂时不抖，与 15 相同。

**图标里的高亮穿过抖动层，和背后的壁纸混合。** 选中项的高亮是灰 232/255 配「变暗」混合（plus-darker，从背后减去 23/255），由 Dock 的 `-[CALayer setMaterialControl:3 appearance:1]` 设上，这个方法在 15.5 与 27.2 里逐字节相同；拖放目标背后的方圆上也有一层「取暗」混合的灰。它们都在抖动层里，效果全靠背后的壁纸。Core Animation 的图层默认成组混合（私有属性 `allowsGroupBlending`），直接子图层的混合只在这一层里面进行，所以 15 把抖动层设成不成组（`-[ECSBItemLayer initWithScaleFactor:layoutRTL:]`，15.5 `0x100060514`）。复刻起初漏了这一项：高亮背后什么也没有，灰色原样画了出来，搜索结果与方向键选中的图标顶着一块不透明的浅灰，白色标题几乎看不见；拖放目标的方圆也成了浅灰。图标图片另放在一个成组混合的容器里，这与 Dock 自己的图标格子一致（`-[DOCKTileLayer init]` 把图片放在单独的 content layer 里），透明与着色样式给图片的混合因此只作用在图片自己身上，不碰壁纸，和改动前一样。离屏的 `CARenderer` 对成组混合的处理与屏幕上相同，单元测试在那里画出图标比对像素。

**收起时先交还输入，再放退场动画。** 与 15 一样：退场一开始就归还键盘焦点、事件不再拦截，正在退场的窗口另存一份，动画结束后才移出屏幕；此时再打开会先立刻结束旧的那份。点图标启动的放大淡出放在窗口根图层上，不随界面一起淡出。

**再次打开回到上次的位置，靠收起时记下来，不是靠留着界面。** 15 的 Launchpad 在 Dock 的整个生命周期里只建一次，收起时只清掉搜索、选中与抖动模式，不动页码，也不关文件夹，所以再打开还在原处。复刻每次打开都重建窗口与界面，于是收起时记下 `SpringboardPosition`（主页的页号，开着的文件夹及其页号），下次打开时先不带动画地摆好，再放进场动画；文件夹开着时进场缩放的是文件夹面板，主页停在 0.95，与 15 相同。几条细则：搜索结果按进入搜索前的页记，因为 15 在退场后清空搜索、无动画回到那一页；正在关闭的文件夹和拖动中还没存进库的文件夹按已关闭记；期间布局变了，文件夹还在就在它现在所在的那页打开，页数少了就退到最后一页，文件夹没了就只回到那一页（`resolved(in:)`）。位置只在内存里，Dock 重启后回到第一页，与 15 相同。

**点 Apps 图标关掉 Launchpad，靠时间先后认出这次点击。** 15 的 Dock 点任何图标都先收起 Launchpad 再执行图标的动作，唯独 Launchpad 图标例外，它自己的动作就是切换。27.2 的 Dock 不告诉 payload 点的是哪个图标，所以点 Dock 一律先收起；而 Apps 图标的动作经 `-[WVExpose exitAndDoWork:]` 排到主队列的下一轮才调 `sendLaunchAppsBrowsing`，那时界面已经收起，于是又被打开，看起来就是「点 Apps 只会打开」。现在点 Dock 收起时记下时刻，此后 0.5 秒内到达的「打开 Apps」请求算作这次点击的，不再打开（`SpringboardEntry`）。没有照 15 按图标类型豁免：那要再依赖 Dock 的命中测试与图标类型两个接口，新构建上多两处可能对不上。代价见「已知降级」。

**自动注入的两道保护。** 同一个 Dock 进程的注入与 payload 的暂存都只进行一次（App 启动时的注入与进程监视的注入会同时开始）；注入后 Dock 连续 3 次在 15 秒内退出，就自动关掉自动注入并说明原因，免得一个加载即崩溃的 payload 让 Dock 循环崩溃。

## 模块结构

复刻分在两个模块里：`LaunchpadAwakenerSpringboardCore` 是 Launchpad 本身（布局库与界面层），不认识 Dock，也不链接 AppKit，经宿主接口 `SpringboardHost` 拿它需要的窗口、图层类、壁纸与图标样式；`LaunchpadAwakenerPayloadCore` 是它在 Dock 里的宿主，加上 hook 与入口。payload 启动时先用 `SpringboardHostSystem.bootstrap(host:)` 选定 Dock 宿主，再装 hook。独立版 App 是另一个宿主，见提案[不注入 Dock 的独立版 Launchpad](../Evolutions/0002-standalone-launchpad.md)。

```
LaunchpadAwakenerPackage/Sources/LaunchpadAwakenerSpringboardCore/
├── Hosting/
│   └── SpringboardHost.swift           # 宿主接口：窗口、图层工厂、Dock 几何、图标样式、壁纸、玻璃、托管文本框、托管的删除确认、卸载器；选定宿主的 SpringboardHostSystem
├── System/                             # 系统框架的私有接口，两个宿主都能用
│   ├── QuartzCorePrivate.swift         # CA 私有滤镜与 CABackdropLayer
│   ├── IconServicesBridge.swift        # IconServices 取图
│   ├── SkyLightBridge.swift            # 连接、窗口层级、键盘焦点
│   ├── WallpaperSnapshot.swift         # 截壁纸窗口（27 归 WindowManager，26 归 Dock）
│   ├── SystemPasteboard.swift          # HIServices 的 Pasteboard Manager
│   └── ApplicationLauncher.swift       # LaunchServices 启动 App
├── Data/                               # 布局库
│   ├── LaunchpadStore*.swift           # 自己的库：读、追加、编辑、整理
│   ├── LegacyLaunchpadImporter.swift   # 只读导入 15 的库
│   ├── ApplicationDiscovery.swift      # 扫描应用目录与排除名单
│   ├── ApplicationDirectoryMonitor.swift # FSEvents
│   ├── LayoutReconciliation.swift      # 与已安装的 App 对账
│   └── LaunchpadLibrary.swift          # 把以上串起来的 actor；发布布局、接受编辑
└── Interface/                          # 界面层，按 15.5 的 ECSB* 划分
    ├── LaunchpadServices.swift         # 布局库的单例，配置取自宿主
    ├── SpringboardController.swift     # 显示、隐藏与进出场、事件分派、启动动画、捏合、保险机制
    ├── SpringboardInputEvent*.swift    # 事件的跨线程表示，及从 CGEvent 的换算
    ├── SpringboardInterface.swift      # 页面、搜索、选中、点击、文件夹开合与改名、背景（ECSBSpringboard + ECSBLayer）
    ├── SpringboardInterface+Dragging.swift # 拖动整理（ECSBDragCapture 与各 DragState）
    ├── SpringboardInterface+FolderMaking.swift # 拖到图标上建文件夹、放进文件夹、未存的文件夹与解散
    ├── SpringboardInterface+Deleting.swift # 抖动模式的关闭按钮、删除确认（问谁、怎么答、何时撤）与删除
    ├── SpringboardDeletionPanel.swift  # 辅助进程弹不出 popover 时自己画的删除确认；按键的读法
    ├── SpringboardIconFlight.swift     # 图片缩进文件夹缩略图的动画
    ├── SpringboardJiggle.swift         # 抖动模式：15 的两段抖动动画、长按时长、Option 规则
    ├── SpringboardBackground.swift     # 背景：15 的模糊壁纸，或宿主给的玻璃
    ├── SpringboardPagedGrids.swift     # 主界面与文件夹共用的翻页器（ECPagerLayer）
    ├── SpringboardFolderPanel.swift    # 打开的文件夹（ECSBGroupLayer）与改名编辑框
    ├── SpringboardTextEditing.swift    # 改名的文字与选区、按键的读法、字间位置（纯计算）
    ├── SpringboardPageGrid.swift       # 每页一个网格（Dock 里是 ECGridLayer）及其数据源
    ├── SpringboardItemLayer.swift      # 图标、文件夹图标与标题（ECSBItemLayer、ECSBGroupItemLayer、ECSBLabelLayer）
    ├── SpringboardControlLayers.swift  # 页码、搜索框、无结果
    ├── SpringboardMetrics.swift        # 15.5 的主界面几何（纯计算）
    ├── SpringboardFolderMetrics.swift  # 15.5 的文件夹几何（纯计算）
    ├── SpringboardSearch.swift         # 15.5 的搜索规则（纯计算）
    ├── SpringboardPaging.swift         # 15.5 的翻页、方向键与拖动命中规则（纯计算）
    ├── SpringboardPinch.swift          # 15.5 的捏合映射与弹簧（纯计算）
    ├── SpringboardPosition.swift       # 再次打开时回到的页与文件夹，及其在新布局里的换算（纯计算）
    ├── SpringboardEntry.swift          # 「打开 Apps」请求的应答：打开、关闭，或认出点 Apps 图标后不动（纯计算）
    ├── SpringboardReplicaLayers.swift  # Dock 的 EC* 图层类的等价实现（独立版用；见独立版实现说明）
    ├── SpringboardReplicaComparison.swift # 开发构建：在 Dock 里把等价图层与 Dock 的类对照
    └── SpringboardSelfCheck.swift      # 开发构建的离屏自检

LaunchpadAwakenerPackage/Sources/LaunchpadAwakenerPayloadCore/
├── PayloadEntry.swift                  # 注入后的入口；选定 Dock 宿主，装 hook，再启动布局库
├── Host/                               # 调 Dock 内部的唯一地方，也是 Dock 这一侧的宿主
│   ├── DockSpringboardHost.swift       # Dock 宿主：把宿主接口接到下面这些类型上
│   ├── DockSpringboardWindow.swift     # 全屏窗口、27/29 层、键盘焦点
│   ├── DockGlobalScanner.swift         # 扫宿主数据段，按持有的对象的类认出全局
│   ├── DockHostInterface.swift         # 签名清单与校验；WALayerKitWindow 的 proxy 与 init
│   ├── DockBarReference.swift          # 经全局变量拿 DockBar 与 DockGlobals
│   ├── DockGlassMaterial.swift         # Dock 自己的液态玻璃（Cmd-Tab 切换器那套控制器）
│   ├── DockEnvironment.swift           # Dock 的方向、厚度、刘海、图标样式；DockBar 与 DisplayDescriptor 的 proxy
│   ├── DockLayerFactory.swift          # ECGridLayer、ECImageGridLayer、ECTextLayer、ECShadowTextLayer、材质
│   ├── DockApplicationUninstaller.swift # Dock 的卸载器
│   ├── SpringboardRemoteTextField.swift # 辅助进程托管的搜索框与改名框：CALayerHost 与事件转发
│   ├── SpringboardRemoteDeletionConfirmation.swift # 辅助进程弹的删除确认：图标编成 PNG，转达按钮、失败与关闭
│   └── TextInputHelperClient.swift     # 经 XPCSession 连文本输入辅助进程；给它发键鼠事件，请它弹、关删除确认
└── Integration/                        # hook 声明（@RuntimeClassHook），以及事件接管时记下的当前事件
```

## 核心数据流

- **显示**：入口 hook（`-[Spotlight sendLaunchAppsBrowsing]`）→ `SpringboardController.toggle`（按 `SpringboardEntry` 决定打开、关闭或不动）→ 读 Dock 的几何算出 `SpringboardMetrics` → 建窗口与 `SpringboardInterface`，摆到上次收起时的 `SpringboardPosition` → 窗口抬到 27 层、Dock 的窗口抬到 29 层、抢键盘焦点。
- **事件**：事件 hook 把 `CGEvent` 抄成 `SpringboardInputEvent` → 控制器换算成容器坐标（左下为原点、y 向上）→ 交给界面 → 界面返回「无 / 关闭 / 启动」三种动作之一。落在 Dock 栏上的点击交还 Dock。
- **布局**：`LaunchpadLibrary` 启动时打开库，首次导入，与已安装的 App 对账，发布布局；之后应用目录一有变化就再对账。每次发布都会触发图标预取。

## 与提案的差异

- App 的变更只靠 FSEvents 监听应用目录，没有接 LaunchServices 的私有通知（签名未逆向确认）。
- 搜索框的输入法靠文本输入辅助进程（另一份提案）；辅助进程不可用时直接把 Dock 收到的按键当文字，那时打不出中文。标题匹配不上时仍按 App 文件名匹配。
- 触控板翻页用滚动事件自带的阶段判断开始与结束。三指轻扫照 15 读导航轻扫事件（手势事件，字段 110 为 16），每个方向有效的事件翻一页，不看阶段（`-[ECPagerLayer gesture:]`）；只有触控板设成「用三指轻扫」在页面间切换时系统才会发出这种事件，Dock 是否收得到还要用户在真机上确认（开发构建会把每个导航轻扫写进日志）。
- 15.5 的 `LaunchPadLayout.plist` 没有作为资源随 payload 发布，改为 Swift 常量（原因见上）。
- 文件夹改名同样经辅助进程接输入法；光标、选区、复制粘贴、撤销与 Esc 都照 15 的文本框（Esc 按当前文字提交）。
- 拖到 Dock 上不支持（第 6 批的后续项，见提案）；拖动时文件夹不额外加一行。
- 捏合没有接入 27 的 Dock 手势系统（那里已经没有它），而是读原始 DockSwipe 事件，并且要用户先关掉 Spotlight 的捏合。
- 背景默认照 15 截壁纸、加三个滤镜；另有 `springboard-background` 设为 `glass` 时的 Dock 液态玻璃，那时 App 的窗口会被模糊进来。
- 点 Apps 图标关闭 Launchpad，靠「点 Dock 收起后 0.5 秒内的请求」认出这次点击，不是 15 那样按图标类型豁免（原因见上）。

## 验证

- 单元测试（`swift test`，只在开发机上跑，不碰 Dock）：库的建立、追加、编辑（移动、溢出、建文件夹及被拖的排在前面、放入、新的末页，以及任何编辑让文件夹只剩一个 App 时解散）与整理；界面在库跟上之前显示的文件夹与库的结果一致；旧库导入（含隐藏页、断了父项的页、下载中的 App、空页）；App 发现、排除名单与 15.5 原文件的逐项核对；对账（原地换了 bundle ID 的 App 只留新的一份、删掉的副本不顶替同 ID 的别的副本、每份副本各有条目并各开各的、原地更新的 App 留在原处、原地替换后重新读 bundle ID）；主界面与文件夹的几何（以 15.5 规格里 1470×956 屏的手算示例为准）；给 Dock 留的高度（15.5 留白表的各档与格子被缩小的情况，默认大小下的网格与 15.5 虚拟机实测一致）；搜索规则；翻页、方向键与拖动命中规则；主页与文件夹里的按键规则（Command-方向键在首尾页当作普通方向键，Command-↑ 关闭文件夹并选中它）；捏合映射与弹簧；三指轻扫的方向换算与事件读取；新装 App 的蓝点（库里的标记位、对账时只给带收据的 App 置位、启动后清除、标题让位的规则与圆点位置）；删除 App（关闭按钮的位置、确认气泡的位置与按键、删除后库里的页面与文件夹）；复制、剪切、粘贴与撤销（一段输入算一步）；搜索框的按键分流；再次打开的位置在布局变化后的换算；「打开 Apps」请求的应答规则；文件夹标题的命中区与改名编辑框的范围；改名编辑框、标题与搜索框换字时不做交叉淡化（在离屏的 `CARenderer` 里提交后检查）；改名的编辑规则（进入时全选、按字按词移动、Shift 扩选、各种删除、双击选词、按键的读法、字间位置与滚动）；选中高亮压暗背后的壁纸、拖放目标的方圆透出壁纸、图标图片的混合不碰壁纸（在离屏的 `CARenderer` 里画出来比对像素）；Dock 的显隐（显示、退场与文件夹开着时要 Dock 怎样，文件夹从开始打开、开始关闭、无动画关闭、被撤下、从库里消失时各报一次；对 Dock 的显示覆盖与隐藏成对设、成对撤，撤销的顺序与拿的相反，Dock 已不持有的原因不去撤，拿不到控制器时什么也不调）。
- MacBook 上的非交互验证：部署后与 Dock 重启后各注入一次、hook 装上、23 个 Dock 方法签名全部吻合；导入 3 页、2 个文件夹、149 个 App 与旧库一致；开发构建的离屏自检核对 Dock 的 `ECGridLayer` 建出的图标数量与位置、文件夹图标的方圆与 `ECImageGridLayer` 缩略图，以及 Dock 的玻璃建出的图层：一个由窗口服务器采样、带 `glassBackground` 滤镜、组名 `launchpad-background` 的 `CABackdropLayer`，加 `CASDFLayer` 与 `CAPortalLayer`，向屏幕四边外扩 64 点，Dock 未崩溃。
- 经用户同意的交互验证（2026-11-06，MacBook 上）：经 ssh 截图、录屏，用一个发 `CGEvent` 的小工具模拟点击与拖动，核对了玻璃背景、文件夹打开动画、快速松手建文件夹并自动弹开、从文件夹拖出后解散；录屏逐帧看过，测试用的文件夹已拆掉。
- 经用户同意的交互验证（2026-11-08，MacBook 上）：拖动搜索结果。搜「cal」后拖起文件夹里的计算器，录屏逐帧核对：结果淡出、搜索清空、回到搜索前的第 1 页再淡入，页面回来时不立刻让位；按 Esc 计算器滑回所在的文件夹，页面与存储的一致；拖到页末松手，计算器落在页末，只剩一个 App 的文件夹解散。测试前备份了布局库，测完关掉 App、重启 Dock 后放回备份，截图核对已还原。
- 经用户同意的交互验证（2026-11-08，MacBook 上）：输入法。
  - App 注册 LaunchAgent 不需要批准。打开界面时 Dock 一连接，launchd 就拉起辅助进程，搜索框由它托管。
  - 搜索框：英文直接打字、删除照常。切到拼音后，组字与候选窗出现在搜索框下方；空格上屏「日历」后搜到日历。
  - 改名框：进入时整段选中、居中；拼音「测试」上屏后按 Return 提交。
  - 结束辅助进程后改由本地编辑；再次打开时又由它托管。
  - 测试改过的文件夹名用备份的布局库还原，输入法切回了 ABC。
- 与 macOS 15.5 对照（2026-11-06）：用户在 Ultra 上用 VirtualBuddy 开了一台 15.5（24F74）虚拟机，经 ssh 录下真正的文件夹开合，与 MacBook 上的复刻逐帧对照了图片飞出、标题、页面平移与面板的透明度。虚拟机录屏会掉帧（连着几帧完全相同），只能对照画面构成，量不了时间曲线。用法见项目 `CLAUDE.md`。
- 交互验证（2026-11-07，MacBook 上，同样的截图与模拟点击）：翻到第 2 页后 Esc 关闭，再打开仍在第 2 页；开着文件夹时用「打开 Apps」关闭，再打开时文件夹仍开着，与关闭前的截图一致；打开时点 Dock 上的 Apps 图标，界面关闭且不再弹回（日志先是 `Hidden (clicked the Dock)`，再是 `Stays hidden`），关闭时再点则打开。测试后已翻回第 1 页。
- 交互验证（2026-11-08，MacBook 上，同样的录屏与模拟点击、按键）：改前改后各录一段 60 帧录屏逐帧对照改名。改前每打一个字，旧名字在原处淡出、新名字左移半个字宽淡入，两行叠在一起，点标题右边约 100 点处也会进入改名；改后打字一帧之内换上，同一处点击关上文件夹，提交改名时标题直接换成新名字。测试用的文件夹已改回原名。
- 改名框的编辑（2026-11-08，先在 15.5 虚拟机里看原版，再在 MacBook 上截图、录屏核对）：原版进入改名时整个名字蓝底选中，→ 后光标到末尾，← 逐字左移，Esc 后名字不变；复刻的选区高度与原版一致，颜色读数的细微差别来自 MacBook 截图的 P3 色彩空间。MacBook 上核对了进入时全选、→ ← 后在中间插字、拖选、超出框宽时横向滚动且光标贴在右边缘、↑ 回到开头、Esc 按当前文字提交；录屏里选区、打字、删除都在一帧之内换上。双击选词与按住 Shift、Option 的操作模拟工具发不出来，只有单元测试。测试用的文件夹已改回原名。
- 图标大小与 15.5 对照（2026-11-08）：在 15.5 虚拟机的截图（1487×936 屏，Dock 默认大小）上逐像素量网格：列距 169、行距 145、图标 96 点、首行图标顶边距屏幕顶 72 点，与公式在留 79 点时的结果一致；图标图片占图标框的比例两边相同（约 81%），文件夹方块都是图标边长减 20 点。改后部署到 MacBook，自检日志为 Dock 79、单元格 193×171、图标 120（1739×1080 屏），正是 15 在这块屏幕上的结果。没有做交互验证。
- 第 6 批的非交互验证（2026-11-08，MacBook 上）：部署后 hook 装上、23 个 Dock 方法签名全部吻合；开发构建的自检显示 Dock 的卸载器可用，149 个 App 里有 39 个可删（都是 App Store 的，只问不删）；19 个 App 带「新」标记，都是从 15 的库里带过来的，下次打开时启动过的会清掉。三指轻扫、文件夹方向键、关闭按钮与删除、搜索框编辑与复制粘贴都没有做交互验证。
- 各构建的离线核对（2026-11-08）：26.0 到 27.2 的 24 个正式构建都从 Apple 的完整更新包里取出 Dock，去重后 16 个二进制，逐个核对了复刻用到的类与方法的声明，并在 IDA 里读出两个全局变量；读法先在 27.2 上验证过，得出的正是档案里原有的两个地址。核对档案自洽的那组单元测试随 2026-11-11 取消档案一起删了；这条记录留着，因为它核对过的「方法签名在 26.0 到 27.2 的每个构建里都一致」这个结论仍然是现在只需看签名日志的依据。
- macOS 26 虚拟机上的验证（2026-11-08，26.6.2 25G83，Ultra 上的 VirtualBuddy）：日志认出这个 Dock（`Dock build 2427.6 of macOS 26.6.2`）、23 个方法签名全部吻合、两个 hook 装上；用户打开过界面，能打开、关闭。第一次背景是灰的：自检报 `No wallpaper window on display 1`，原因是 26 的壁纸窗口归 Dock 自己，复刻只认 WindowManager 的；改为按属主进程挑窗口后，自检报 `wallpaper captured, 2982×1804 pixels`。挑窗口的规则用两台机器上实际读到的窗口列表写了回归测试。同一个构建随后部署到 27.2 的 MacBook：认出 27.2 的 Dock、23 个方法签名全部吻合、两个 hook 装上，自检报 `wallpaper captured, 3478×2160 pixels`，改过的 WindowManager 那条路径照常。两台都没有做交互验证。
- 选中高亮（2026-11-08，MacBook 上，同样的截图与模拟按键）：用户指出搜索结果的选中项是白底；此前搜「日历」的截图里也是一块不透明的浅灰 232。修好后搜「s」，App Store 的高亮是压暗壁纸的深色圆角块，白色标题清楚，与 15 的截图一致；主页上用方向键选中的文件夹也是这样，图标与文件夹方块的样子没有变。拖放目标的方圆与透明、着色图标样式只有单元测试，没有在真机上看。
- Dock 的显隐（2026-11-09，MacBook 上）：部署后 hook 装上，23 个 Dock 方法签名全部吻合，payload 启动时的日志确认 `DockVisibility` 的四个方法与 `_dockForceHiddenReasons` 都对得上，Dock 没有崩溃。文件夹开合时 Dock 滑走、滑回由用户在真机上亲眼看过。开了自动隐藏时 Dock 露出没有在真机上看过。
- 改用 ObjCRuntimeToolbox（2026-11-09，MacBook 27.2 与 26.6.2 虚拟机上，非交互）：两台都认出 Dock、23 个方法签名全部吻合、两个 hook 经 `RuntimeMethodHook` 装上、`DockVisibility` 对得上；离屏自检的网格、缩略图、卸载器（27.2 上 145 个里 39 个可删）、壁纸与 27.2 上的玻璃都与改前一致，图标 205 个（27.2）与 97 个（26）全部取到；独立版的自检解析出图标样式，207 个图标全部取到。第一次部署时所有图标都取不到：`ISIcon` 是类簇，`+alloc` 给的是 `ISIconFactory`，`initWithURL:` 在它上面，改成按类名 `ISIcon` 核对就找不到。随后系统框架导出的私有类改为按头文件直接调用（见上文「调 Dock 内部方法一律先校验签名」），声明前在两台测试机上逐个核对过方法与编码，`SystemPrivateInterfaceTests` 在开发机上渲染一个图标锁住它。没有做交互验证，文本输入辅助进程里调 `NSDockTile` 私有方法的那几处只在开发机上编译过。
- 去掉手写类型编码（2026-11-09，同样两台、非交互）：构造、类方法、卸载的 block 参数改由 `@RuntimeClassProxy` 推出，经环境对象拿到的对象改用 `@RuntimeObjectProxy`（FrameworkToolbox 0.18.0）。两台都是 23 个方法全部吻合、两个 hook 装上；26.6.2 的环境对象类名是 `Environment`，27.2 是 `_TtC8DockCore11Environment`，两边都核对通过、图标样式照常取到；卸载器在 27.2 上仍是 145 个里 39 个可删，在 26.6.2 上找得到、0 个可删（虚拟机里没有 App Store 应用）；网格、图标（205 个与 97 个）、壁纸与 27.2 上的玻璃都与改前一致，独立版自检照旧。真正删除应用要交互，没有验证；回调闭包改标 `@Sendable`，让它在 XPC 队列上被调用时不被当成主 actor 的闭包。
- 重复条目（2026-11-09，开发机上，只读）：拿用户真实布局库的一份拷贝，用新规则在开发机上对账一遍：删掉的正好是 9 个过期条目（5 个原地换了 bundle ID 的 App 的旧条目，4 个已删除、靠同 ID 的别的副本留着的旧版本），新加了另外两个 Xcode 与 IDA 9.2 到 9.5；对账后 233 个条目都指向 bundle ID 相符的 App，没有两个条目指向同一份。没有在 Dock 里跑过。
- 搜索框光标露在打开的文件夹上方（2026-11-10，MacBook 上，经用户同意截图与模拟点击）：
  - 窗口列表显示，辅助进程的 mini view 窗口一直在屏上：第 27 层、不透明，就在搜索框文字区。
  - 复现：结束辅助进程，再第一次打开界面，点进搜索框、点开文件夹，连拍 6 张里 5 张看得到光标，与用户在 Ultra 上的截图一致。之后的打开里，Launchpad 的窗口压在它上面，看不出来。
  - 搜「q」后点空白处收起，「q」留在桌面上方。
  - 修复（窗口设成完全透明）只有单元测试，没有在实机上看过：MacBook 被拿去装 macOS 15 了。
- 删除确认改用辅助进程弹的 `NSPopover`（2026-11-10）：单元测试覆盖消息经真实 XPC 往返、Dock 一侧客户端（弹出的回答、按钮回报、关闭请求、辅助进程退出）、界面层的状态（问辅助进程要的内容与图标中心、按钮与按键都关掉它、一次只问一个、弹不出时退回自己画的、辅助进程退出时按取消、收起时撤下、答过之后迟到的按钮不算）、辅助进程里锚点的位置与 popover 的内容排版（与 nib 的框一致：问句 (82, 40, 308×34)，删除按钮右边缘 388）。之前先在 15.5 虚拟机里放了带空收据的「可删测试」，用户截到了原版的气泡。部署到 26.6.2 虚拟机（非交互）：认出 Dock 2427.6、23 个方法签名全部吻合、两个 hook 装上；同样放了「可删测试」后，对账把它加进第 2 页，自检报卸载器 69 个 App 里 1 个可删，正是它。用户在 26 虚拟机里看到 popover 照预期上屏、位置与内容都对，但「删除」没有画成默认按钮；锚点改成 nonactivating panel 后重新部署，单元测试锁住锚点的这几项（改前先失败）。改后用户看过，删除是蓝色的默认按钮，日志记的是 popover 窗口 `key true, application active true`。开发构建 20 秒没有输入就收起 Launchpad，点 popover 不算输入，所以那里的气泡最多停 20 秒。用户随后点「删除」：第一下就生效，半秒后卸载器删掉了 `/Applications/可删测试.app`，布局随即从 69 个 App 变成 68 个。27 上的样子没有试（MacBook 改装了 15）。
- 仍需用户亲自判断的部分：观感与手感、停住 1 秒弹开新文件夹、捏合；第 6 批的三指轻扫（Dock 是否收得到）、删除确认在 27 上的样子。

- 全局扫描（2026-11-11，只在开发机上，不碰 Dock）：单元测试覆盖找到持有目标类实例的那个槽、类不匹配时不误报、堆块小于实例大小时被筛掉、不是堆块的值（小整数、没映射的地址、未对齐的地址）一个都不解引用、多个槽持有同一对象时都报出来且用那个对象、持有不同对象时一个也不用、先扫的段有命中就不看后面的段、区域起点不按指针对齐时仍能找到里面对齐位置上的对象。另有一条遍历本进程全部已加载镜像的真实 `__DATA` 段、拿一个没有全局持有的类去扫：那些段装满了别处留下的值，跑完不崩就是「三道筛子没有解引用不该碰的内存」的证据。`swift test` 合计 488 个测试通过，`RunScript.sh` 的完整构建与三个架构切片校验通过。
- **在真实的 Dock 里验证过了**（2026-11-11，用户亲自在一台 27.2（26B123）上运行）：`DockBar` 与 `DockGlobals` 都在 `__DATA,__common` 里，各只有一个槽持有它们——日志是 `Found DockBar in __DATA,__common, 1 slot(s)` 与 `Found DockCore.DockGlobals in __DATA,__common, 1 slot(s)`。控制面板开着时每三秒现场扫一次，近百次里每次都只找到那一个槽（那时每扫一次都写一行日志，这之后改成只有答案变化时才写）。
- **macOS 26 上也验证过了**（2026-11-11，在 26.6.2 的虚拟机里非交互跑的）：注入后两个全局同样各在 `__DATA,__common` 的一个槽里被找到，26 上 `DockGlobals` 是 Objective-C 类，日志写的就是 `Found DockGlobals in __DATA,__common, 1 slot(s)`；同一次注入 23 个方法签名全部吻合、两个 hook 都装上，离屏自检的网格、缩略图、选中材质、壁纸与 97 个图标都与改前一致。玻璃退回模糊是 26 上本来就有的降级（见「已知降级」），与这次改动无关。

## 已知降级

- 透明与着色图标样式下，Dock 在图标背后画的玻璃底没有复刻。
- 文本输入辅助进程不可用时（在「登录项」里关掉了它，或它反复退出），搜索与改名没有输入法，退回本地编辑。
- 文本输入辅助进程只在 27.2 上验证过，macOS 26 上没有试过。
- 改名的选区色固定为 15 深色外观下的蓝色，不随系统强调色变化。
- 删除确认是辅助进程弹的系统 `NSPopover`，样子随 26/27 的系统（玻璃材质、按钮形状），与 15 的不同。辅助进程不在时退回自己画的气泡，那是照 15 的尺寸画的平面近似：没有半透明材质，箭头与边框不连成一体，按钮按下时没有高亮。网页 App 与快捷指令在 15 里用「移除」的文案，复刻一律写「删除」。
- 玻璃背景：打开期间切换深浅色或辅助功能里的透明度、对比度，要到下次打开才跟上（界面每次打开都重建，没有注册 Dock 的外观观察者）。
- 背景是打开那一刻的静态截图，动态壁纸不会动（与 15 相同）；截不到时是 15 的径向渐变。
- 快速放进文件夹后，文件夹图标的缩略图在库发布新布局、页面重建时就滚回顶部；15 要等下次打开再关上这个文件夹才滚回。
- 捏合在用户关掉 Spotlight 的捏合之前不生效；Dock 能否收到捏合事件尚未在真机上确认。26 与 27.0 上捏合不归 Spotlight 进程，而由 Dock 自己的 `Spotlight` 对象跟手打开系统的 Apps（`-[Spotlight fluidGestureStart:]` 一族，27.2 删掉了），不经过 `sendLaunchAppsBrowsing`，复刻拦不到；同样要先在触控板设置里关掉系统的捏合。
- 点 Dock 上别的图标关闭界面后 0.5 秒内按 Launchpad 键或触发角，这一下会被当作 Apps 图标的请求吞掉。
- 再次打开的位置不跨 Dock 重启保存（与 15 相同）。
- Dock 在左右两侧时，满 5 行的文件夹常常不往下多伸那 30 点：15 的公式只在文件夹底边高于 30 点时才伸，侧放 Dock 时底边多半正好是 30。这时文件夹每页的格子比主页的矮 6 点，而界面层按主页的格子算拖动的落点与让位，会偏几点。这是按代码推断的，没有在真机上复现。
- 文件夹开着时让 Dock 滑走，只在指针不在 Dock 上、Dock 没有键盘焦点时立刻开始，15 与 27.2 的 Dock 都是这样；Dock 藏起来时指针推到屏幕边会不会把它叫回来，没有验证。
- 只在主显示器上显示。
- 新装 App 的蓝点：从 Launchpad 以外启动后，要到下次打开 Launchpad 才消失，并且依赖 Spotlight 记下的使用时间；关掉 Spotlight 索引时只有从 Launchpad 启动才会清掉。测试版 App 的黄点与屏幕使用时间的沙漏标记没有做。
- macOS 26 上没有玻璃背景：26 的 `DockGlassMaterialLayerController` 用的是 `configureUsingConfiguration:` 与 `rebuildLayersWithEnvironment:`，签名核对不过，`springboard-background` 设成 `glass` 也退回带 15 三个滤镜的模糊。
- macOS 26 上透明与着色图标的混合没有与 26 的 Dock 对照过：26 没有 `kCAFilterClearIconBlendMode`，复刻按 27 的映射在透明与浅色着色样式下不加滤镜、深色着色用 Screen，而 26 的 `-[DOCKTileLayer init]` 默认给格子图片的是 Screen。
- 新一代芯片的 Mac 上，27 的 Dock 可能加载另一个切片 `arm64e.x1`（macOS 27 新增的 `CPU_SUBTYPE_ARM64E_X1`）。这不再影响找全局变量——扫描不比对 UUID、也不用按切片记的地址，2026-11-11 起两个切片一视同仁；但手边没有这类 Mac，payload 能否注入这种进程仍未验证过。

## 新的 Dock 构建：什么都不用做

payload 不认 Dock 的构建号，也不带任何按构建登记的地址。它要的两个全局变量在第一次用到时现找（见上文「关键设计决策」），所以 macOS 26 与 27 的任何 Dock 构建——包括还没发布的——装上就能用，升级系统当天不需要做任何事。

这是日志里应该看到的两行，默认级别，不加 `--info` 也看得到：

```
Found DockBar in __DATA,__common, 1 slot(s)
Found DockCore.DockGlobals in __DATA,__common, 1 slot(s)
```

第二行的类名是 `class_getName` 给的：27 的 `DockGlobals` 是 Swift 类，新的 Objective-C 运行时把它反混淆成「模块.类名」（查找时用的仍是改编名 `_TtC8DockCore11DockGlobals`）。26 上它是 Objective-C 类，那一行写作 `Found DockGlobals in __DATA,__common, 1 slot(s)`。

每一行只在答案变化时写一次，不是每次扫描都写：控制面板开着时每隔几秒就问一次状态，而每次问都现场扫一遍。所以一次 Dock 的生命周期里通常就这两行。重复的那些落在 debug 级，而 debug 级默认根本不记录，`log show --debug` 也看不到；要看它们就在扫描发生时开着 `log stream --level debug`（2026-11-11 在 26.6.2 的虚拟机上这样看过，控制面板开着时每三秒一对）。

真正可能被新构建打破的只剩方法签名。安装 hook 之前，复刻会把它要调的全部 Dock 方法按类型编码整批核对，一处不符就一个 hook 都不装，并把实际读到的编码写进日志。所以升级系统后只需要看一眼：

```bash
ssh JH@192.168.50.13 '/usr/bin/log show --info --last 5m --predicate '"'"'subsystem == "com.MxIris.LaunchpadAwakener"'"'"''
```

`Checked N Dock method(s), 0 mismatch(es)` 加 `Installed 2 hook(s)` 就是好的。有 mismatch，或者两行 `Found …` 里缺了一行，才进入下一节。

这两行是 info 级，只留在内存缓冲里：隔一两个小时再查就已经没有了（2026-11-11 实测，注入过了两小时就查不到，而同一次注入的 `Found …` 与 `Channel to the app is open` 还在）。要看它们就在打开 Launchpad 之后尽快查，或者重启一次 Dock 再查。

**2026-11-08 曾经为 26.0 到 27.2 的 24 个正式构建各登记过一条构建档案**（去重后 16 个二进制），每条都要下完整更新包、取出 Dock、建 IDA 库、从反汇编里读出两个全局变量的地址。那套流程连同它维护的表一起取消了，取而代之的是运行时扫描；留在下面的是其中仍然用得上的部分——只在要核对一个构建的方法签名时才需要。

## 方法签名不符时：取那个构建来核对

1. 取那个构建的 Dock。`/Volumes/Firmwares/macOS/` 存着 26.0 到 27.2 的全部完整更新包（`<版本>_<build>_universal.zip`，只给特定机型的构建以机型命名）。更新的版本用 `ipsw download appledb --os macOS --type ota --release --json` 查出 `active_url` 与 `sha256`，`aria2c` 开 16 个连接下载，再用 `openssl dgst -sha256` 核对（`aria2c` 自带的校验是单线程的，17 GB 要十几分钟）。旧包所在的 CDN 节点慢，一个包十几 MiB/s，多个包要并行下。
2. 取出 Dock：`ipsw ota extract <包> --pattern 'System/Library/CoreServices/Dock\.app/Contents/(MacOS/Dock|Info\.plist|version\.plist)$' --confirm --output <目录>`，约一分钟。`TMPDIR` 与输出目录要在同一个卷上，否则最后一步改名报 `cross-device link`。先比 arm64e 切片的 UUID（`dwarfdump --uuid`）：和已经核对过的某个构建相同，就不必再往下走。
3. 把新 Dock 放进 `/Volumes/RE/Dock/<版本>/`，用 reverse-engineering skill 的脚本导出头文件，用 `idax binary --arch arm64e` 建 IDA 库（27 的 Dock 另有 `arm64e.x1` 切片，不加 `--arch` 会选错）。
4. 核对签名：用 `ipsw class-dump <Dock> --arch arm64e --re -V` 导出声明，把复刻用到的类（`WALayerKitWindow`、`WAWindow`、`DockBar`、`DisplayDescriptor`、`EC*` 图层、`Spotlight`、`DockAppEventHandler`、玻璃的四个类、`IconAppearance`、`Environment`、卸载器与 `CALayer` 的分类）和同一大版本里已核对过的构建逐个对照。26.0 到 27.2 里不同的只有复刻没用到的方法。
5. 部署到同一大版本的测试机，看日志里 `Checked N Dock method(s), M mismatch(es)`：日志会写出不符的那几个的新编码，逐个核对后改对应 proxy 协议或 hook 方法的 Swift 类型（编码由它推出；init 的签名直接改字符串），并更新 `DockSignatureTests` 里记的编码。

两行 `Found …` 里缺了一行时，要查的是另一回事：那个构建把单例放在了扫描没覆盖的地方，或者 Dock 还没建好它。先在测试机上多等一会儿再看一次日志；确实一直找不到，就在那个构建的 IDA 库里看 `-[DockBarSystemDefinedEventHandler handleSystemDefinedEvent:type:]` 处理 Launchpad 键（系统定义事件子类型 9、键码 104）的分支，顺着向一个全局发 `keyFocusController`（那是 `DockBar`）、向另一个发 `slowMotionAllowed`（那是 `DockGlobals`）的两处 `ADRL` 加 `LDR`，确认那两个地址落在哪一节——`DockGlobalScanner` 扫的是 `__DATA` 的 `__common`、`__bss`、`__data`。

## 延伸阅读

- [术语表](../Glossary.md)
- 15.5 的界面规格：`/Volumes/RE/Dock/15.5/Notes/LaunchpadMainInterface.md`
- 15.5 的文件夹与拖动：`/Volumes/RE/Dock/15.5/Notes/LaunchpadFoldersAndDragging.md`（建文件夹与放进文件夹的逐帧时序在 4.11）
- 15.5 的背景与进出场、27.2 的壁纸来源：`/Volumes/RE/Dock/15.5/Notes/LaunchpadBackgroundAndAnimations.md`
- Launchpad 怎样让 Dock 露出与滑走（15.5、26.x、27.2），27.2 玻璃 Dock 的上沿：`/Volumes/RE/Dock/27.2/Notes/DockVisibilityAndFloor.md`
- 27.2 的 `EC*` 图层与图标：`/Volumes/RE/Dock/27.2/Notes/ECLayerReuse.md`
- 27.2 的玻璃材质：`/Volumes/RE/Dock/27.2/Notes/GlassMaterial.md`
- 捏合手势：`/Volumes/RE/Dock/27.2/Notes/PinchGesture.md`
