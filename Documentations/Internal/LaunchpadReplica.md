# Launchpad 复刻：实现说明

> 配套提案见 [在 macOS 27 的 Dock 中复刻 macOS 15 的 Launchpad](../Evolutions/draft-launchpad-replica.md)。
> 本文记录实际落地的实现、与提案的差异，以及当前覆盖范围与已知降级。面向维护者。

## 背景与目标

payload 注入 macOS 27.2 的 Dock，接管所有「打开 Apps」的入口，在 Dock 自己的窗口与图层类上画出 macOS 15 的 Launchpad。布局首次从 15 留下的数据库导入，之后存在 `~/Library/Application Support/LaunchpadAwakener/Launchpad.db`。完整动机见提案。

## 关键设计决策

**只认构建档案里的 Dock。** `DockBuildProfile` 以 Dock 可执行文件 arm64e 切片的 `LC_UUID` 为键，存着只对这一个构建成立的事实（目前只有 `DockBar` 全局变量的地址）。UUID 不在表里，payload 一个 hook 都不装，所有入口照旧打开系统的 Apps。这是有意的：地址在别的构建里毫无意义，读错地址会让 Dock 崩溃。

**`DockBar` 只能经全局变量拿到。** 27.2 里没有任何导出的路径通向它；`-[DockBar rect]` 和 `-[DockBar setRollTile:]` 在鼠标划过 Dock 时都不会被调用，所以「hook 这两个方法、在调用时记下接收者」的办法拿不到它（原型试过）。读全局变量后还会核对对象的类名是不是 `DockBar`。

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

**自动注入的两道保护。** 同一个 Dock 进程的注入与 payload 的暂存都只进行一次（App 启动时的注入与进程监视的注入会同时开始）；注入后 Dock 连续 3 次在 15 秒内退出，就自动关掉自动注入并说明原因，免得一个加载即崩溃的 payload 让 Dock 循环崩溃。

## 模块结构

```
LaunchpadAwakenerPackage/Sources/LaunchpadAwakenerPayloadCore/
├── PayloadEntry.swift                  # 注入后的入口；装 hook，再启动布局库
├── Host/                               # 调 Dock 内部与私有接口的唯一地方
│   ├── DockBuildProfile.swift          # 构建档案：UUID → 只对该构建成立的事实
│   ├── DockHostInterface.swift         # 签名清单与校验；WALayerKitWindow、DockBar rect
│   ├── DockBarReference.swift          # 经全局变量拿 DockBar
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
│   ├── SpringboardController.swift     # 显示、隐藏、事件分派、启动动画、保险机制
│   ├── SpringboardWindow.swift         # 全屏窗口、27/29 层、键盘焦点
│   ├── SpringboardInterface.swift      # 页面、搜索、翻页、选中、点击（ECSBSpringboard + ECSBLayer）
│   ├── SpringboardPageGrid.swift       # 每页一个 ECGridLayer 及其数据源
│   ├── SpringboardItemLayer.swift      # 图标与标题（ECSBItemLayer、ECSBLabelLayer）
│   ├── SpringboardControlLayers.swift  # 页码、搜索框、无结果
│   ├── SpringboardMetrics.swift        # 15.5 的几何公式（纯计算）
│   ├── SpringboardSearch.swift         # 15.5 的搜索规则（纯计算）
│   └── SpringboardPaging.swift         # 15.5 的翻页与方向键规则（纯计算）
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

## 验证

- 单元测试（`swift test`，只在开发机上跑，不碰 Dock）：库的建立、追加、编辑与整理；旧库导入（含隐藏页、断了父项的页、下载中的 App、空页）；App 发现、排除名单与 15.5 原文件的逐项核对；对账；网格几何（以 15.5 规格里 1470×956 屏的手算示例为准）；搜索规则；翻页与方向键规则。
- MacBook 上的非交互验证：部署后与 Dock 重启后各注入一次、hook 装上；导入 3 页、2 个文件夹、149 个 App 与旧库一致；开发构建启动时离屏建一次界面，日志核对 Dock 的 `ECGridLayer` 建出的图标数量与位置。
- 需要用户亲自看、亲手操作的部分（打开后的观感、翻页与搜索的手感等）不在 agent 的验证范围内。

## 已知降级

- 透明与着色图标样式下，Dock 在图标背后画的玻璃底没有复刻。
- 文件夹图标暂用 `ecsb_group` 贴图加 3×3 缩略图；文件夹的打开、拖动整理随第 3 批落地。
- 只在主显示器上显示。

## 适配新的 Dock 构建

1. 新系统上 payload 会在日志里写出 `Unknown Dock build <UUID>`，什么也不装。
2. 用 `idax binary --arch arm64e` 为新 Dock 建 IDA 库，并用 swift-section 导出头文件（见 reverse-engineering skill）。
3. 找 `DockBar` 全局变量：在 `-[DockBarSystemDefinedEventHandler handleSystemDefinedEvent:type:]` 等方法里看它从哪个全局变量取 `DockBar`。
4. 在 `DockBuildProfile.knownProfiles` 加一条（UUID、版本、地址），部署到测试机，看日志里 `Checked N Dock method(s), M mismatch(es)`：有不符的，日志会写出新的类型编码，逐个核对后更新签名。

## 延伸阅读

- 15.5 的界面规格：`/Volumes/RE/Dock/15.5/Notes/LaunchpadMainInterface.md`
- 27.2 的 `EC*` 图层与图标：`/Volumes/RE/Dock/27.2/Notes/ECLayerReuse.md`
