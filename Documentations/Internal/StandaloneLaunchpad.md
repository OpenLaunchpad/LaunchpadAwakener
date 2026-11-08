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

## 模块结构

```
LaunchpadAwakenerPackage/Sources/LaunchpadAwakenerSpringboardCore/
├── Hosting/SpringboardHost.swift          # 宿主接口、SpringboardHostSystem、没有宿主时的 DetachedSpringboardHost
└── Interface/
    ├── SpringboardReplicaLayers.swift     # Dock 的 EC* 图层类与选中材质的等价实现，及造它们的工厂
    └── SpringboardReplicaComparison.swift # 开发构建：在 Dock 里把等价图层与 Dock 的类对照
```

## 与提案的差异

- 宿主接口的形状与提案「详细设计」里的草图不同：网格不各自成为协议，而是 `CALayer` 加工厂里的排版、失效与滚动方法；偏好与布局库配置也放进了宿主。原因见上文第一条决策。

## 验证

- 单元测试 `Tests/LaunchpadAwakenerSpringboardCoreTests/SpringboardReplicaLayerTests.swift`：页面网格在 1739×1080 屏上的排法与 27.2 Dock 的自检日志一致（第一格 `{{0, 686}, {193, 171}}`、第 27 格 `{{965, 173}, {193, 171}}`），第一项在最上面，裁剪只在唯一的子图层上；缩略图的位置与 15.5 的公式一致、数量不封顶、滚到空位的行数（8、9、11、12 个 App）、失效后重新取数量；阴影的缩放、标题的阴影设置、选中材质。
- 2026-11-08 在 MacBook（27.2）上部署注入版的开发构建，离屏自检报告页面网格（27 项）、缩略图（12 项，滚到 `{0, -40}`）、选中材质（sRGB 0.9098、`plusD`）与标题像素（2 倍屏 14080 个像素）全部与 Dock 的类一致。

## 已知降级

- 等价文字图层固定左对齐；Dock 的 `ECTextLayer` 在 Dock 处于从右到左的语言时右对齐。界面层给每个文字图层都显式设了对齐，不受影响。

## 延伸阅读

- 配套提案：[不注入 Dock 的独立版 Launchpad](../Evolutions/draft-standalone-launchpad.md)
- 注入版实现说明：[Launchpad 复刻：实现说明](LaunchpadReplica.md)
- Dock 图层类的逆向笔记：`/Volumes/RE/Dock/27.2/Notes/ECLayerReuse.md`
