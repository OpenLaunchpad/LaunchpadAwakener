# Launchpad 复刻：实现说明

> 配套提案见 [在 macOS 27 的 Dock 中复刻 macOS 15 的 Launchpad](../Evolutions/draft-launchpad-replica.md)。
> 本文记录实际落地的实现、与提案的差异，以及当前覆盖范围与已知降级。面向维护者。

## 背景与目标

payload 注入 macOS 26.0 到 27.2 的 Dock，接管所有「打开 Apps」的入口，在 Dock 自己的窗口与图层类上画出 macOS 15 的 Launchpad。布局首次从 15 留下的数据库导入，之后存在 `~/Library/Application Support/LaunchpadAwakener/Launchpad.db`。完整动机见提案。

## 关键设计决策

**只认构建档案里的 Dock。** `DockBuildProfile` 以 Dock 可执行文件 arm64e 切片的 `LC_UUID` 为键，存着只对这一个构建成立的事实：`DockBar` 与 `DockGlobals` 两个全局变量的地址、`DockGlobals` 的类名，以及这个 Dock 随哪些系统版本发布（只写进日志）。UUID 不在表里，payload 一个 hook 都不装，所有入口照旧打开系统的 Apps。这是有意的：地址在别的构建里毫无意义，读错地址会让 Dock 崩溃。表里登记了 26.0 到 27.2 全部 24 个正式构建（含只给特定机型的构建），它们一共只有 16 个不同的 Dock：点版本常常带着逐字节相同的 Dock，但也有像 26.7.2 这样版本号不变却重编了的。`DockBuildProfileTests.supportedReleases` 列着这 24 个版本，每个都要恰好对上一条档案。

**`DockBar` 只能经全局变量拿到。** 27.2 里没有任何导出的路径通向它；`-[DockBar rect]` 和 `-[DockBar setRollTile:]` 在鼠标划过 Dock 时都不会被调用，所以「hook 这两个方法、在调用时记下接收者」的办法拿不到它（原型试过）。`DockGlobals` 同样只能经全局变量拿到。读全局变量后还会核对对象的类：按类对象比较，不比类名，因为运行时给 Swift 类的名字是 `DockCore.DockGlobals`，不是查找它用的改编名 `_TtC8DockCore11DockGlobals`。26 的 `DockGlobals` 还是 Objective-C 类 `DockGlobals`，所以要查的类名也记在构建档案里。

**26 与 27 用同一套复刻。** 26 的 Dock 里旧 Launchpad 的类（`Springboard`、`LPSpringboard`、`ECSB*`、`ECPager*`）都还在，但 23 处入口经一个恒返回 1 的函数一律改道到 `-[Spotlight sendLaunchAppsBrowsing]`，和 27 一样，所以拦这一个方法就接管了 Launchpad 键、Dock 上的 Apps 图标、触发角与 Apps 本身。复刻调用的 23 个方法与两个 hook 在 26.0 到 27.2 的每个构建里签名都相同。几处差别：26 的 `-[DockAppEventHandler handleMachMessage:size:]` 在 Exposé 或旧 Springboard 捕获事件时不调 `handleDockBarEvent:type:`（后者在 26 上从不捕获，Mission Control 打开时复刻收不到事件，和 15 一样）；26 的玻璃控制器没有 `updateUsingLayoutConfiguration:environment:`，可选的玻璃背景退回模糊；26 与 27.0 的 Dock 自己接捏合（见已知降级）；26 的壁纸窗口（`Wallpaper-`）还是 Dock 自己画的，和 15 一样，到 27 才归 WindowManager（`Wallpaper`）。所以截壁纸时按属主进程认窗口：WindowManager 的优先，没有就用 Dock 自己的。不按属主名认，因为那是本地化的名字，中文系统上 26 的 Dock 叫「程序坞」。

**事件入口：hook 事件总入口加抢键盘焦点，不全局抢占事件。** 打开时 `CPSStealKeyFocusOnConnection(cid, 1152)`，关闭时归还，事件经 `-[DockAppEventHandler handleDockBarEvent:type:]` 接管——这正是 15 的做法。没有走 27 的 Cmd-Tab 切换器那种自建连接加 `CGSSetEventCapture`：一旦失控，整台机器的输入都会被锁住，26 上那次只能重启就是这种情形。也没有改用 `ECModalEventController`：它自建连接时只按 Dock 栏窗口的坐标做命中测试，处理者栈又与堆栈展开、Cmd-Tab 共用，打开 Launchpad 时会互相挤掉。

**判断「点在 Dock 上」只能用 `DockBar` 的 `rect`。** 27.2 的 Dock 窗口几乎铺满屏幕，用窗口范围判断会把所有点击都当成点在 Dock 上。

**payload 里不用 AppKit，也不用 `Bundle.module`。** 27.2 的 Dock 不链接 AppKit，字体一律用 Core Text 建，显示器信息用 CoreGraphics 和 Dock 自己的 `DisplayDescriptor`。SwiftPM 生成的 `Bundle.module` 找不到资源时直接 `fatalError`，在注入的框架里就是让 Dock 崩溃，所以 15.5 的 `LaunchPadLayout.plist` 只放在测试资源里，排除名单与默认首页以 Swift 常量随 payload 发布，由测试逐项核对。界面贴图（`ecsb_*`、`ectl_*`）在运行时从 Dock.app 里读，26 与 27 的 Dock.app 都带着这些文件。

**调 Dock 内部方法一律先校验签名。** `DockHostInterface.requiredMethods` 汇总了界面层要调的所有 Dock 方法，任何一个的类型编码与 27.2 元数据不符，就整批不装 hook。经对象拿到的 Swift 类（`IconAppearance` 等）在调用前按对象的实际类校验，失败就降级。两个容易错的地方：`EC*` 类的 `scaleFactor` 都是 `float`（编码 `f`），按 `CGFloat` 传会错位；头文件里的 ivar 偏移是编译期的值，运行时会滑动，要用 `ivar_getOffset`。

**每页一个 Dock 的 `ECGridLayer`，内容变了就换一个新的。** `ECGridLayer` 只在初始化时问一次条目数，之后没有入口能改；15.5 的 `ECSBGridLayer` 是直接改父类 ivar 来增删图标的。这里选择页内条目一变就重建整页网格，代价可以忽略（一页最多几十个图层）。另外三点：`-[ECGridLayer layout]` 不是 `layoutSublayers`，Core Animation 不会自动调，要宿主调用；数据源被弱引用，由 `SpringboardPageGrid` 持有；`makeLayerForLayer:` 在协议上是可选的，实际必须实现。

**图层类不碰主线程隔离的单例。** Swift 写的 `CALayer` 子类必须实现 `init(layer:)`，Core Animation 做动画时会用它复制出呈现层；这些子类保持不隔离，图标由主线程上的 `SpringboardInterface` 查好再交给图层，图层自己不调用 `@MainActor` 的单例。首次布局一律关掉隐式动画，否则图层会从零尺寸「长」出来。

**自己的库沿用 15 的表与触发器，编辑时改为整组重排。** 导入与追加靠 15 的触发器维护 `ordering`；拖动类的编辑则先关掉触发器（`dbinfo` 的 `ignore_items_update_triggers` 置 1），把涉及的父项的子项按新顺序整组写回、编号从 1 开始，再打开触发器。被移动的项在同一个事务里先挂到父项 -1 上，否则之后再读兄弟列表时它还会出现在原处。编辑后照 15 收拾：一页超过容量就把末尾几项挤到下一页开头，空的文件夹页、文件夹和页面删除。任何把 App 移出文件夹的编辑——移到页上、移进别的文件夹或别的文件夹的页上、建新文件夹——都让只剩一个 App 的原文件夹解散。

**App 只在确实卸载时才从布局里删除。** 搜索目录里没找到、书签解析不到、LaunchServices 也不认识，三者都成立才删，免得装在别处的 App 被误删。

**图标与 Dock 栏同一套样式。** 描述符复制自 `DockBar.environment.iconAppearanceMonitor.appearance.iconDescription`，再经 IconServices 的 `-[ISIcon initWithURL:]` 取图；Dock 自己走的 `_LSBindingCreateWithURL` 是 C 函数，签名无法校验，所以没用。图标在后台队列渲染，布局一加载就全部预取（MacBook 上 149 个约 2 秒，之后命中 IconServices 的缓存只要几十毫秒）。

**给 Dock 留的高度照 15 从格子大小算，不量 27 的 Dock 栏。** 15 留 `ceilf(tileSize + distanceTop + distanceBottom)`：格子是设定的图标大小加两侧各一个内边距，上下留白按格子大小查一张表（15.5 `0x1000DBB44`），默认大小下是 68 + 1 + 10 = 79 点，与 15.5 虚拟机里量出的网格吻合。27.2 算格子的方法没变（`0x10001149C`），只是玻璃 Dock 换了一张表（`0x100078598`）：格子上方留 5 到 6 点（15 是 0 到 2），整条栏默认 94 点高。最初按栏高留位置，又误以为 15 只留约 59 点（逆向笔记把格子当成了 48 点），结果在 1487×936、1512×982 这类屏幕上图标比 15 小一档。现在经 `-[DockBar desiredTileSize]` 与 `tileSize` 读格子大小，套 15.5 的表算（`SpringboardMetrics.dockThickness(desiredTileSize:tileSize:)`）；Dock 放不下、格子被缩小时，留白按缩小后的格子查表，与 15 相同。代价是界面比 15 更贴近 Dock：27 的栏比 15 高出的约 15 点不再另外留出。

**文件夹照 15 用图层画，缩略图交给 Dock 的 `ECImageGridLayer`。** 15.5 根本不引用 Dock.app 里的 `ecsb_group`、`ecsb_arrow_*` 等贴图（10.7–10.9 时代的遗留），文件夹图标是半透明浅色方圆加 3×3 缩略图。`ECImageGridLayer` 与 `ECGridLayer` 不同，`layerSourceInvalidated:` 之后会重新问条目数，所以换内容不必重建；它不保证子图层顺序，取缩略图时按位置排序。

**选中项跟着前面的那组页面走。** 方向键、Return、Command-方向键作用于前面的页面：开着文件夹时是文件夹的，否则是主页的，规则照 15 的 `-[ECSBGroupPager navigate:withEvent:]` 与主页相同（`SpringboardKeyCommand`）。用键盘打开的文件夹（Return 或 Command-↓）在打开动画结束后选中第一项，点开的不选；文件夹关上后主页没有选中项，只有 Command-↑ 关上的会选中这个文件夹。选中的图层单独记着，翻页后旧页上的高亮会被清掉，此前翻回去还能看到残留的高亮。

**新装 App 的蓝点照 15 存在库里，标记与清除的时机按 27 能拿到的信号近似。** 15 的蓝点就是 `items.flags` 的 0x400 位：App Store 下载完成时置位，Dock 听到这个 App 启动时清除，跨重启保留，从 15 导入的库里也带着。27.2 的 Dock 只在 Swift 内部处理 App Store 下载完成，没有可替换的入口，所以复刻在对账时给带购买收据（`Contents/_MASReceipt/receipt`）的新 App 置位，首次建库不置位；从 Launchpad 启动时清除，每次打开前再看一眼带蓝点的 App：Spotlight 记的最近使用时间晚于这份拷贝放进来的时间，就算启动过，清掉（`RecentlyAddedApplications`）。没有 hook Dock 的 `handleApplicationLaunchNotification:time:data:asn:`：它的数据内容没逆向，而且每个 App 启动都会经过它。圆点照 15 的 `ECFlagLayer`（9 点圆、`GenericRGB(0, 122/255, 1)`）挂在标题图层上，随标题一起移动和淡入淡出；放不下时标题缩短、右移半个标记宽并左对齐，规则照 15。

**删除 App 用 Dock 自己的卸载器，确认气泡自己画。** 15 在抖动模式里给卸载器认可的 App（App Store 的、网页 App、快捷指令、带包装容器的）显示关闭按钮，按下后由 `com.apple.dock.ecap` 服务弹一个 `NSPopover` 确认，确认后经 `DockCore.SystemApplicationUninstaller` 交给 `uninstalld` 删除。27.2 的 Dock.app 里已经没有 ecap 服务，卸载器却还在（`DockBar.environment.applicationUninstaller`，Objective-C 可调，只是 Dock 自己不再调用）。复刻的关闭按钮照 15 用 Dock.app 的 `ecsb_closebox` 贴图，按下换 `ecsb_closebox_pressed`；能不能删在开始抖动时问卸载器（`uninstallabilityOfFileAtURL:` 为 1），每次打开问一遍。确认气泡照 ecap 的视图自己画：400×84，箭头指向图标中心、在图标下方，图标 64 点、问句 13 点、取消与删除两个按钮，删除是默认按钮；回车删除，Esc 与 Command-句号取消，背景不变暗，点别处没反应。文案 27 的 Dock.app 里没有了，取自 15.5 Dock.app 的各语言 `Localizable.strings`（`SpringboardDeletionStrings`）。确认后照 15 先用 0.5 秒把图标缩到一成并淡出，再调卸载器；成功后本页在 0.25 秒内补上空位（后面的页不前移），库删掉这个 App；失败时图标在原处恢复（15 是放到下一个空位）。卸载是永久删除，不进废纸篓，连同偏好设置与容器一起删，正在运行的会先被要求退出、再被强制结束，与 15 相同。

**拖动时自己摆放图标，不经 `ECGridLayer` 布局。** `ECGridLayer` 的布局在内部关掉隐式动画，借它没法做出 15 那种 0.4 秒的让位动画；拖动期间按「排列」（当前页的条目按新顺序排好、被拖的那个占一格）逐个设图标的 frame。被拖的图层离开网格挂到容器最上层跟手。松手时一次性写库，库发布的新布局再重建页面；拖动或文件夹开合期间到达的新布局先存着，动作结束后才换上（`replaceLayout` / `applyPendingLayoutIfIdle`）。

**拖搜索结果，就是从它真正所在的地方拖。** 15 在搜索结果上一开始拖就退出搜索（`-[ECSBDragCapture _cancelFiltering]` 及其两个完成回调）：结果层 0.25 秒淡出，搜索框清空、回到搜索前的那页，被拖的 App 挪到这页末尾，页面再淡入；期间图标照常跟手，别的都不响应，松手与 Esc 等页面进来后才处理；页面回来后 15 不立刻让位，等下一次移动，复刻同普通拖动一样等指针慢下来才让位。复刻照这个顺序做。拖动的来源记的是 App 在布局里的真实位置（`SpringboardDragging.location(of:in:)`）：在某页上就当作从那页拖起，在文件夹里就当作从那个文件夹拖出，所以松手时写的是「移到这里」或「移出文件夹」，Esc 时滑回那页或滑进那个文件夹的图标。这个 App 自己在各页上的图标先拿掉，由被拖的图标代表它，接到页末时页满了就占最后一格（那格原来的图标松手时挤到下一页，与拖出文件夹、拖到边缘翻页相同）。它所在的文件夹在松手前照旧显示它；悬停弹开这个文件夹时，面板里它自己的图标同样拿掉。Esc 时若来源文件夹正开着，面板按库里的文件夹重建、图标滑回原格；开着的是别的文件夹，就先关掉它，再滑进来源文件夹的图标。

**建文件夹先在界面上做出来，库稍后跟上。** 15 的三条路径都照逐帧时序复刻（RE 笔记 4.11）：快速松在 App 上，目标的格子当场换成文件夹图标，两张图片先后缩进缩略图，0.75 秒后自动弹开；停住 1 秒，弹开一个只有目标的文件夹，被拖的图标在面板里继续摆放；快速松在文件夹上，图片缩进缩略图、文件夹不打开。界面上的文件夹在库写好之前没有真实的标识符，用一个负数标识符的「未存的文件夹」代替；库发布的新布局到达时，再按第一个 App 找到真正的文件夹接上（`storedFolder(for:in:)`）。停住 1 秒弹开的那个文件夹在松手前根本不写库：在面板里松手时写一次建文件夹（顺序按面板），拖回面板外就在界面上解散，库里什么也没发生过。

**主页的空位跟着文件夹走。** 拖进文件夹（弹开的或快速松手后自动弹开的）时，被拖图标在主页上留下的空位不立刻合拢，而是保留到文件夹关上后 250 毫秒，这期间主页不按新布局重建（`mainPagePlaceholder`）。从文件夹里拖出时同样等面板关上 250 毫秒，主页才让位，只剩一个 App 的文件夹此时解散成那个 App。

**打开的文件夹是另一个翻页器。** 15 的 `ECSBGroupLayer` 本身就是 `ECPagerLayer`，所以主界面与文件夹共用 `SpringboardPagedGrids`（滚动层、页码、跟手、回弹、滚轮停顿）。面板只是一层白色 97%、不透明度一半的圆角矩形，不模糊身后：15 虽然建了 `CABackdropLayer` 并给了模糊 30、饱和度 1.8，但设在 `backgroundFilters` 上，backdrop 并不执行。macOS 15.5 虚拟机里打开文件夹时，正在淡出的主网格透过面板清晰可见，只被白色冲淡；同一台虚拟机里程序坞的 backdrop 照常模糊，可见不是虚拟机做不了模糊。面板看起来像毛玻璃，靠的是身后本来就模糊的壁纸背景。开合动画里动的是面板的形状，承载内容的容器始终铺满，靠遮罩裁出面板。开合时照 15 只动格子里的图片与标题：打开前把第一页每张图片缩到文件夹图标对应的缩略图上、标题放到图片下方并隐藏，页面随一个缩到文件夹单元格上的容器平移；打开时这些都在同一个事务里用隐式动画回到原位，与面板保持同一节奏。关闭反过来，且始终收第一页。三处容易做错：不能缩放整个格子（标题会跟着缩小）；不能用显式的线性动画（与面板的默认缓动不同步）；Dock 的 `ECGridLayer` 默认裁剪格子，要照 15 的 `ECSBGridLayer` 关掉，否则缩略图上的图片会被页面边缘裁掉。动画期间格子的图片与标题暂停排版（`isPictureAndTitleLayoutSuspended`，相当于 15 的 `disableLayout`），否则动画开始前的一次排版会把它们放回原位。这些动作都在 macOS 15.5 虚拟机里和真机录屏逐帧对照过。

**界面按屏幕尺寸铺，不按窗口根图层。** `WALayerKitWindow` 的根图层在建界面时 bounds 还是 0×0。图标的位置都由屏幕尺寸算出，不受影响，但按根图层定大小的容器与背景就成了 0×0：最初的壁纸背景因此看起来是透明的，换成玻璃后也只在屏幕左下角露出一小块。

**图标缩放时只设 bounds 与 position。** 解散中的文件夹图标缩到一成、被拖的图标放大到 1.1 倍时，页面可能正好在让位；给带 transform 的图层设 `frame`，Core Animation 会按缩放后的尺寸反推 bounds，图标恢复原大后就大了十倍、跑出原格。让位一律用 `setUntransformedFrame(_:)`。关闭文件夹的动画也只处理还在面板里的图标：网格的列表里仍有被拖出去的那个，碰了它就会在手上消失。

**新建的图层先提交上屏，再做动画。** Core Animation 不给从未提交过的图层做隐式动画。打开文件夹时面板、图标都是新建的，所以先在关掉动画的事务里摆好起点（面板缩在文件夹图标的方圆上、图片缩在缩略图上），`CATransaction.flush()` 提交，再开始动画；图标缩进缩略图、文件夹解散也是这样。漏掉这一步的症状就是「打开没有动画、关闭有」。

**改名只从标题文字上开始；会在眼前换的字一律直接换上。** 15 只认落在标题图层上的按下（这个图层只比文字宽 4 点），松手在哪都进入改名（`-[ECSBGroup leftMouseDown:in:]`、`leftMouseUp:in:`）。标题左右各宽 200 点的那一块是编辑框，平时隐藏，改名时框内的按下全被文本框收下，所以框内点击不结束改名（`isInTitleEditor`）。最初照逆向笔记把这一块当成了点击区，点标题那一行的空白处也会开始改名；现在那里照「面板外」处理，一按就关文件夹，用户在 15.5 上确认 15 也会关。另外，Core Animation 默认给文字图层重画出的新内容做 0.25 秒的交叉淡化：标题居中，每打一个字整行左移半个字宽，新旧两行于是叠在一起闪一下。改名的编辑框、标题标签与搜索框的文字图层因此都关掉了 `contents` 的隐式动画（`disableTextCrossfade()`）。单元测试里要先把图层交给离屏的 `CARenderer` 提交一次，它才会像屏幕上的图层那样做隐式动画，否则修没修都看不出差别。

**改名框照 15 的文本框编辑，选区自己维护。** 15 的改名框是 Dock 的 `com.apple.dock.ecti` 服务里一个真正的 `NSTextField`，经 `CALayerHost` 贴进 Dock 的图层。服务一建好它就调 `selectText:`，所以进入改名时整个名字是选中的，打字直接替换；方向键、Shift 扩选、点击放光标、拖选、双击选词都是它字段编辑器的标准行为；Return、Enter 与 Esc 都结束编辑并按当前文字提交，Esc 并不撤销。复刻里没有 AppKit，改由 `SpringboardTextEditing` 维护文字与选区：按用户看到的整字计数，中文、emoji、带附加符号的字母都不会被拆开；按词移动用 Foundation 的分词，中文也按词。`SpringboardTextEditingCommand` 照标准键位把按键读成命令，编辑框按 Core Text 量出的字间位置画选区和光标。文字居中，放不下时横向滚动，只滚到光标看得见为止，不再在开头显示省略号。选区色 `#3F638B` 与光标、选区的高度是在 15.5 虚拟机的截图上量的，是深色外观下系统默认的选中文字色，不随系统强调色变化。复制粘贴走 HIServices 的 Pasteboard Manager（Dock 本来就加载了它，payload 用不了 AppKit 的 `NSPasteboard`），撤销是自己的快照栈，一段连续输入算一步（`SpringboardFieldEditor`）。这套本地编辑在下文的文本输入辅助进程不可用时才用；有它时，两个框都由它托管。

**搜索框与改名框共用一套编辑，按键照 15 分流。** 搜索框也由 `SpringboardFieldEditor` 维护文字、选区与撤销，光标画在实际位置，选中的部分用改名框同样的颜色，放不下时横向滚动，点击放光标、拖选、双击选词。哪些键归搜索框照 15 的 `-[ECSBLayer keyDown:]`：Tab、Return、Enter、Esc、↑↓ 从不给它；← 只在它有焦点时给它，→ 还要有文字；Command-方向键翻结果页；其余键先激活搜索框再交给它，所以没点进去时直接打字、删除、粘贴也行。

**输入法靠一个托管文本框的辅助进程，照 15 的 ecti 服务做**（提案 [用常驻辅助进程给搜索框与改名框接上输入法](../Evolutions/0001-input-method-helper.md)）。Dock 不加载 AppKit，输入法只认真正的文本框和激活状态的进程，所以 App 里多带一个 LaunchAgent `LaunchpadAwakenerTextInput`：

- **启动**：它放在 `Contents/Library/LoginItems/`，App 启动时用 `SMAppService.agent` 注册，不用用户批准。launchd 在 payload 连它的 Mach 服务时才拉起它。它只接受 Dock 的连接（按进程路径核对）。
- **托管**：它在 Dock 图块的 mini view 窗口里放一个 `NSTextField`，那扇窗口不上屏，却能成为 key 窗口。payload 用 `CALayerHost` 显示这扇窗口的图层托管上下文。
- **转发**：payload 把这些事件复制一份，标上辅助进程的窗口编号与窗口内位置，用 `CGEventPostToPid` 发过去：
  - 搜索框该收的键；正在组字时是所有键；
  - 改名时的所有键；
  - 框里的点按与拖动。
- **回报**：辅助进程回报不含组字部分的文字、是否在组字、改名时是否按了 Return、Enter 或 Esc。输入法不让文本框报告组字，所以它用一个改写了 `setMarkedText`、`unmarkText` 的字段编辑器来报。

与 15 不同的地方：

- 27.2 的 Dock 不再告诉 AppKit「mini view 已显示」，辅助进程要自己调 `_setMiniViewShown:`，否则窗口成不了 key，按键进不去。
- 窗口层级要设成 27，候选窗才出现在 Launchpad 上方。
- 辅助进程只托管一个框，搜索框与改名框轮流用：开始改名时搜索框交出去，改完再接回来。每次换框都先结束上一段编辑，字段编辑器才会按新框的对齐方式重建，否则改名框会沿用搜索框的靠左。
- 组字时本地的占位文字「搜索」让开，不与组字中的文字叠在一起。
- 连不上辅助进程、它中途退出时，退回上文的本地编辑；下次打开时 launchd 会重新拉起它。
- 几处细节：
  - 搜索框没有焦点时，托管的框不显示光标，与 15 相同。框一直是第一响应者，只把光标颜色设成透明，转发来的键才不会落空。
  - 改名时还在组字就点到别处，辅助进程收尾时把组字原样上屏，回给 payload 的最终文字随后补进名字。只认辅助进程真正托管过的框：它还没托管上改名就结束了，名字以本地编辑的为准，辅助进程那次也不回报文字。补写直接写进布局库，界面这时已经收起也不丢。
  - 托管框的位置按几何规格算，不从图层换算：打开的文件夹、捏合与进场动画会让界面暂时缩放，辅助进程却一直用给它的位置放候选窗、量点按。
  - 辅助进程只认 Apple 签名的 Dock（libxpc 逐条消息核对代码签名），新连接要先发来一条合法消息才接替旧连接。Dock 的签名一旦不再有效（比如换了注入方式），它的消息都会被拒、输入法随之停用，辅助进程的日志里会留下拒绝记录。
  - 部署换掉了辅助进程的可执行文件时，它在下一次打开时自行退出，那一次退回本地编辑，再下一次由 launchd 拉起的新版本托管。

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
│   ├── TextInputHelperClient.swift     # 连文本输入辅助进程；给它发键鼠事件
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
│   ├── SpringboardJiggle.swift         # 抖动模式：15 的两段抖动动画、长按时长、Option 规则
│   ├── SpringboardBackground.swift     # 背景：15 的模糊壁纸，或 Dock 的液态玻璃
│   ├── SpringboardPagedGrids.swift     # 主界面与文件夹共用的翻页器（ECPagerLayer）
│   ├── SpringboardFolderPanel.swift    # 打开的文件夹（ECSBGroupLayer）与改名编辑框
│   ├── SpringboardTextEditing.swift    # 改名的文字与选区、按键的读法、字间位置（纯计算）
│   ├── SpringboardPageGrid.swift       # 每页一个 ECGridLayer 及其数据源
│   ├── SpringboardItemLayer.swift      # 图标、文件夹图标与标题（ECSBItemLayer、ECSBGroupItemLayer、ECSBLabelLayer）
│   ├── SpringboardControlLayers.swift  # 页码、搜索框、无结果
│   ├── SpringboardRemoteTextField.swift # 辅助进程托管的搜索框与改名框：CALayerHost 与事件转发
│   ├── SpringboardMetrics.swift        # 15.5 的主界面几何（纯计算）
│   ├── SpringboardFolderMetrics.swift  # 15.5 的文件夹几何（纯计算）
│   ├── SpringboardSearch.swift         # 15.5 的搜索规则（纯计算）
│   ├── SpringboardPaging.swift         # 15.5 的翻页、方向键与拖动命中规则（纯计算）
│   ├── SpringboardPinch.swift          # 15.5 的捏合映射与弹簧（纯计算）
│   ├── SpringboardPosition.swift       # 再次打开时回到的页与文件夹，及其在新布局里的换算（纯计算）
│   ├── SpringboardEntry.swift          # 「打开 Apps」请求的应答：打开、关闭，或认出点 Apps 图标后不动（纯计算）
│   └── SpringboardSelfCheck.swift      # 开发构建的离屏自检
└── Integration/                        # hook 声明与入口、事件的接管
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

- 单元测试（`swift test`，只在开发机上跑，不碰 Dock）：库的建立、追加、编辑（移动、溢出、建文件夹及被拖的排在前面、放入、新的末页，以及任何编辑让文件夹只剩一个 App 时解散）与整理；界面在库跟上之前显示的文件夹与库的结果一致；旧库导入（含隐藏页、断了父项的页、下载中的 App、空页）；App 发现、排除名单与 15.5 原文件的逐项核对；对账；主界面与文件夹的几何（以 15.5 规格里 1470×956 屏的手算示例为准）；给 Dock 留的高度（15.5 留白表的各档与格子被缩小的情况，默认大小下的网格与 15.5 虚拟机实测一致）；搜索规则；翻页、方向键与拖动命中规则；主页与文件夹里的按键规则（Command-方向键在首尾页当作普通方向键，Command-↑ 关闭文件夹并选中它）；捏合映射与弹簧；三指轻扫的方向换算与事件读取；新装 App 的蓝点（库里的标记位、对账时只给带收据的 App 置位、启动后清除、标题让位的规则与圆点位置）；删除 App（关闭按钮的位置、确认气泡的位置与按键、删除后库里的页面与文件夹）；复制、剪切、粘贴与撤销（一段输入算一步）；搜索框的按键分流；再次打开的位置在布局变化后的换算；「打开 Apps」请求的应答规则；文件夹标题的命中区与改名编辑框的范围；改名编辑框、标题与搜索框换字时不做交叉淡化（在离屏的 `CARenderer` 里提交后检查）；改名的编辑规则（进入时全选、按字按词移动、Shift 扩选、各种删除、双击选词、按键的读法、字间位置与滚动）；选中高亮压暗背后的壁纸、拖放目标的方圆透出壁纸、图标图片的混合不碰壁纸（在离屏的 `CARenderer` 里画出来比对像素）。
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
- 各构建的离线核对（2026-11-08）：26.0 到 27.2 的 24 个正式构建都从 Apple 的完整更新包里取出 Dock，去重后 16 个二进制，逐个核对了复刻用到的类与方法的声明，并在 IDA 里读出两个全局变量；读法先在 27.2 上验证过，得出的正是档案里原有的两个地址。单元测试核对档案恰好覆盖这 24 个版本、地址落在可执行文件里且按指针对齐、`DockGlobals` 的类名与大版本相符。
- macOS 26 虚拟机上的验证（2026-11-08，26.6.2 25G83，Ultra 上的 VirtualBuddy）：日志认出这个 Dock（`Dock build 2427.6 of macOS 26.6.2`）、23 个方法签名全部吻合、两个 hook 装上；用户打开过界面，能打开、关闭。第一次背景是灰的：自检报 `No wallpaper window on display 1`，原因是 26 的壁纸窗口归 Dock 自己，复刻只认 WindowManager 的；改为按属主进程挑窗口后，自检报 `wallpaper captured, 2982×1804 pixels`。挑窗口的规则用两台机器上实际读到的窗口列表写了回归测试。同一个构建随后部署到 27.2 的 MacBook：认出 27.2 的 Dock、23 个方法签名全部吻合、两个 hook 装上，自检报 `wallpaper captured, 3478×2160 pixels`，改过的 WindowManager 那条路径照常。两台都没有做交互验证。
- 选中高亮（2026-11-08，MacBook 上，同样的截图与模拟按键）：用户指出搜索结果的选中项是白底；此前搜「日历」的截图里也是一块不透明的浅灰 232。修好后搜「s」，App Store 的高亮是压暗壁纸的深色圆角块，白色标题清楚，与 15 的截图一致；主页上用方向键选中的文件夹也是这样，图标与文件夹方块的样子没有变。拖放目标的方圆与透明、着色图标样式只有单元测试，没有在真机上看。
- 仍需用户亲自判断的部分：观感与手感、停住 1 秒弹开新文件夹、捏合；第 6 批的三指轻扫（Dock 是否收得到）、删除确认气泡的样子与真删一个 App。

## 已知降级

- 透明与着色图标样式下，Dock 在图标背后画的玻璃底没有复刻。
- 文本输入辅助进程不可用时（在「登录项」里关掉了它，或它反复退出），搜索与改名没有输入法，退回本地编辑。
- 文本输入辅助进程只在 27.2 上验证过，macOS 26 上没有试过。
- 改名的选区色固定为 15 深色外观下的蓝色，不随系统强调色变化。
- 删除确认的气泡是照 15 的尺寸与文案画的，深浅色外观没有与 15 对照过（15.5 虚拟机里没有 App Store 的 App），按钮按下时没有高亮。网页 App 与快捷指令在 15 里用「移除」的文案，复刻一律写「删除」。
- 玻璃背景：打开期间切换深浅色或辅助功能里的透明度、对比度，要到下次打开才跟上（界面每次打开都重建，没有注册 Dock 的外观观察者）。
- 背景是打开那一刻的静态截图，动态壁纸不会动（与 15 相同）；截不到时是 15 的径向渐变。
- 快速放进文件夹后，文件夹图标的缩略图在库发布新布局、页面重建时就滚回顶部；15 要等下次打开再关上这个文件夹才滚回。
- 捏合在用户关掉 Spotlight 的捏合之前不生效；Dock 能否收到捏合事件尚未在真机上确认。26 与 27.0 上捏合不归 Spotlight 进程，而由 Dock 自己的 `Spotlight` 对象跟手打开系统的 Apps（`-[Spotlight fluidGestureStart:]` 一族，27.2 删掉了），不经过 `sendLaunchAppsBrowsing`，复刻拦不到；同样要先在触控板设置里关掉系统的捏合。
- 点 Dock 上别的图标关闭界面后 0.5 秒内按 Launchpad 键或触发角，这一下会被当作 Apps 图标的请求吞掉。
- 再次打开的位置不跨 Dock 重启保存（与 15 相同）。
- 只在主显示器上显示。
- 新装 App 的蓝点：从 Launchpad 以外启动后，要到下次打开 Launchpad 才消失，并且依赖 Spotlight 记下的使用时间；关掉 Spotlight 索引时只有从 Launchpad 启动才会清掉。测试版 App 的黄点与屏幕使用时间的沙漏标记没有做。
- macOS 26 上没有玻璃背景：26 的 `DockGlassMaterialLayerController` 用的是 `configureUsingConfiguration:` 与 `rebuildLayersWithEnvironment:`，签名核对不过，`springboard-background` 设成 `glass` 也退回带 15 三个滤镜的模糊。
- macOS 26 上透明与着色图标的混合没有与 26 的 Dock 对照过：26 没有 `kCAFilterClearIconBlendMode`，复刻按 27 的映射在透明与浅色着色样式下不加滤镜、深色着色用 Screen，而 26 的 `-[DOCKTileLayer init]` 默认给格子图片的是 Screen。
- 新一代芯片的 Mac 上，27 的 Dock 可能加载另一个切片 `arm64e.x1`（macOS 27 新增的 `CPU_SUBTYPE_ARM64E_X1`）：它的 UUID 与地址都和 arm64e 切片不同，档案没有登记。手边没有这类 Mac，payload 能否注入这种进程也没验证过。

## 适配新的 Dock 构建

2026-11-08 用这套步骤补齐了 26.0 到 27.2 的全部构建。

1. 新系统上 payload 会在日志里写出 `Unknown Dock build <UUID>`，什么也不装。
2. 取那个构建的 Dock。`/Volumes/RE/Dock/` 下已有的目录先看 README 里列的版本；没有就从 Apple 的完整更新包里取。`/Volumes/Firmwares/macOS/` 存着 26.0 到 27.2 的全部包（`<版本>_<build>_universal.zip`，只给特定机型的构建以机型命名）。更新的版本用 `ipsw download appledb --os macOS --type ota --release --json` 查出 `active_url` 与 `sha256`，`aria2c` 开 16 个连接下载，再用 `openssl dgst -sha256` 核对（`aria2c` 自带的校验是单线程的，17 GB 要十几分钟）。旧包所在的 CDN 节点慢，一个包十几 MiB/s，多个包要并行下。
3. 取出 Dock：`ipsw ota extract <包> --pattern 'System/Library/CoreServices/Dock\.app/Contents/(MacOS/Dock|Info\.plist|version\.plist)$' --confirm --output <目录>`，约一分钟。`TMPDIR` 与输出目录要在同一个卷上，否则最后一步改名报 `cross-device link`。先比 arm64e 切片的 UUID：和已登记的相同就只在那条档案里加上这个版本。
4. 把新 Dock 放进 `/Volumes/RE/Dock/<版本>/`，用 reverse-engineering skill 的脚本导出头文件，用 `idax binary --arch arm64e` 建 IDA 库（27 的 Dock 另有 `arm64e.x1` 切片，不加 `--arch` 会选错）。
5. 核对签名：用 `ipsw class-dump <Dock> --arch arm64e --re -V` 导出声明，把复刻用到的类（`WALayerKitWindow`、`WAWindow`、`DockBar`、`DisplayDescriptor`、`EC*` 图层、`Spotlight`、`DockAppEventHandler`、玻璃的四个类、`IconAppearance`、`Environment`、卸载器与 `CALayer` 的分类）和同一大版本已登记的构建逐个对照。26.0 到 27.2 里不同的只有复刻没用到的方法。
6. 找两个全局变量：`-[DockBarSystemDefinedEventHandler handleSystemDefinedEvent:type:]` 处理 Launchpad 键（系统定义事件子类型 9、键码 104）的分支里，向一个全局变量发 `keyFocusController`——那是 `DockBar`；向另一个发 `slowMotionAllowed`——那是 `DockGlobals`。看汇编里 `ADRL` 加 `LDR` 取的地址，26.0 到 27.2 都是这样。这个方法的地址取自第 5 步导出里的注释。
7. 在 `DockBuildProfile.knownProfiles` 加一条（UUID、系统版本、版本号、两个地址；26 用 `macOS26Profile`，27 用 `macOS27Profile`，二者只差 `DockGlobals` 的类名），把版本加进 `DockBuildProfileTests.supportedReleases`，并在 RE 目录的 README 里记下来源与两个地址的出处。
8. 部署到同一大版本的测试机，看日志里 `Checked N Dock method(s), M mismatch(es)` 与 `Installed 2 hook(s)`：有不符的，日志会写出新的类型编码，逐个核对后更新签名。

## 延伸阅读

- [术语表](../Glossary.md)
- 15.5 的界面规格：`/Volumes/RE/Dock/15.5/Notes/LaunchpadMainInterface.md`
- 15.5 的文件夹与拖动：`/Volumes/RE/Dock/15.5/Notes/LaunchpadFoldersAndDragging.md`（建文件夹与放进文件夹的逐帧时序在 4.11）
- 15.5 的背景与进出场、27.2 的壁纸来源：`/Volumes/RE/Dock/15.5/Notes/LaunchpadBackgroundAndAnimations.md`
- 27.2 的 `EC*` 图层与图标：`/Volumes/RE/Dock/27.2/Notes/ECLayerReuse.md`
- 27.2 的玻璃材质：`/Volumes/RE/Dock/27.2/Notes/GlassMaterial.md`
- 捏合手势：`/Volumes/RE/Dock/27.2/Notes/PinchGesture.md`
