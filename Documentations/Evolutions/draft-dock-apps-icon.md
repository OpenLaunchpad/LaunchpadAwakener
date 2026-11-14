# Draft - 注入成功后把 Dock 的 Apps 图标换成 Launchpad 的图标

- **状态**: In Progress
- **创建日期**: 2026-11-14
- **最后更新**: 2026-11-14
- **配套文档**: [Dock 的 Apps 图标：实现说明](../Internal/DockAppsIcon.md)

## 摘要

注入成功之后，Dock 里点 Apps 打开的已经是这个工具复刻的 Launchpad，图标却还是系统的 Apps 图标。本提案让 payload 把那一格的图标换成 Launchpad 的图标，并配一个开关。

换过之后 Dock 的 Apps 格子和注入版 App 自己的图标就重名了——复刻的 Launchpad 里也会列出注入版 App。所以注入版（配置 App）的图标另加一个标志：3×3 网格右下角那块本来就是灰色的方块换成齿轮形状，整体形状、玻璃材质与配色不动。独立版 `Launchpad.app` 保持现在这套干净图标，它就是启动台本身。

## 方案

### 两个图标，一处干净的来源

- `LaunchpadAwakenerStandalone/AppIcon.icon` 不动，是干净图标的唯一来源。
- `LaunchpadAwakener/AppIcon.icon` 把 `tile9` 图层换成齿轮形状的 SVG，其余图层与填充不变。
- Dock 要用的那份图像：「Embed Standalone Launchpad」构建阶段已经在处理独立版产物，顺便把它的 `Contents/Resources/` 里的 `Assets.car` 与 `AppIcon.icns` 拷进注入版的 `Contents/Resources/LaunchpadDockIcon/`。Xcode 自己从 `.icon` 编出这两份，所以不引入 Icon Composer 的 `ictool` 这类构建期依赖，CI 上同样成立；图标改了它自动跟着变。
- **拷的是零件，不是一张图，也不是一个现成的 bundle。** 浅色、深色、着色三份外观在 `Assets.car` 里的 `AppIcon.iconstack`，只有 IconServices 渲染得出来，而它只从 bundle 渲染；但注入版包里直接放一个 `.app` 就成了嵌套代码——LaunchServices 会注册它，每一道签名与公证都要带上它。所以 App 在第一次要用时把零件拼成 `~/Library/Application Support/LaunchpadAwakener/LaunchpadDockIcon.app`，那里没人注册它。

### payload：一个 hook，三个调用

图标进入 Dock 的 `Tile` 只有三条路，其中第一条是 Dock 自己经 LaunchServices 取的图（姊妹项目 DockIconOverride 的
[Dock 图标的三条通路](https://github.com/Mx-Iris/DockIconOverride) 在 26.5.2 与 27.2 上逆向验证过）。App 图标走第一条，所以 hook 它一条就够：

- hook `-[Tile setImage:preferredGlassBackgroundStyle:]`（26.6.2，编码 `v32@0:8@16q24`）或
  `-[Tile setImage:preferredGlassBackgroundStyle:glassCompositingFilter:]`（27.2，`v40@0:8@16q24@32`）。两个拼写各写一个
  `@RuntimeClassHook("Tile")` 结构体，按宿主实际有哪个二选一，**先试带 `glassCompositingFilter:` 的那个**：macOS 27 上旧拼写依然存在、依然被调用，但调它的只剩 Stack、Trash、Folder、URL 与窗口格子，App 图标全部搬到了新拼写上。装上旧拼写在 27 上的后果是校验通过、日志报成功、永远收不到 App 图标。
- 命中条件：`-[Tile fileURL]`（`@16@0:8`）解析出的 bundle 标识符是 `com.apple.apps.launcher`，或路径是 `/System/Applications/Apps.app`。两个版本的 Dock 二进制里都有这个标识符。路径到标识符的解析要读 Info.plist，而这个 setter 在 Dock 的渲染路径上（图标尺寸变、外观变、App 启动退出都会触发），所以缓存，并且**连「不是」的结果一起缓存**——绝大多数格子永远不是 Apps，恰恰是它们被问得最频繁。
- 开关变化时要动已经画好的格子：从 `DockBar`（已有的 `DockBarReference` 经全局扫描拿到）取 `-[DockBar tiles]`（`@16@0:8`）找到 Apps 格子，调 `-[Tile render]`（`v16@0:8`）。`render` 正是 Dock 自己调第一条通路的地方，于是开关开着就被 hook 换掉、关着就画回系统图标。**不需要记账被挤掉的原图**，这是比 DockIconOverride 的 `forceIcon` 省掉的一整套逻辑。
- 图像经 IconServices 从那个 bundle 渲染，descriptor 复制 Dock 自己的（`DockEnvironment.iconAppearance.iconDescriptor`），于是浅色、深色、透明、着色以及用户选的着色颜色全部跟随，和 Dock 其他格子用的是同一套参数——复刻的 Launchpad 里每个图标也是这么画的。不碰 AppKit——payload 跑在 Dock 里，而 Dock 经 Core Animation 与 SkyLight 绘制。
- **hook 里只读缓存，绝不在 Dock 的线程上渲染**：IconServices 渲染期间阻塞，而这个 setter 是 Dock 正在绘制时调的。缓存没命中就让 Dock 画自己的图标，同时在后台渲染，渲染完再调一次 `render`，下一趟就命中。缓存键是「bundle 路径 + 像素宽 + 外观的那几个字段」。
- 这批 hook 单独一批原子安装，与「Dock 显隐」那批分开：任何一批对不上只失去它那一项，Launchpad 本身照常。

### 开关：App 是唯一的真相源

- 控制面板「Launchpad」分组加一行开关，菜单栏菜单加一项。
- 存在 App 的 UserDefaults（`DockAppsIconEnabled`），**默认开**：注入是用户主动装的，Dock 里点 Apps 打开的已经是复刻的 Launchpad，图标跟着变才一致。
- 经 payload 通道发 `DockAppsIconRequest(isEnabled:iconPath:)`：payload 不读偏好、不猜 App 装在哪，路径由 App 给。握手之后 App 发一次当前状态，开关一改立刻再发一次。Dock 重启后 App 重新注入，握手后再发一次；重启到发请求之间那一瞬显示系统图标，Dock 重启本来就会闪一下。

### 测试

- `DockSignatureTests` 记下新增的五个编码：第一通路两个拼写、`fileURL`、`render`、`tiles`，并断言这三个调用**不在** `DockHostInterface.requiredMethods` 里。
- 单元测试：Apps 格子的身份判断（命中、未命中、答案能否跨磁盘删除存活、路径标准化）、开关默认值与持久化、下发内容、不支持时的回报、没有图标的构建。
- 测试机实测：MacBook（27.2，26B123，SIP 关）与 macOS 26.6.2 虚拟机，各走一遍开、关、Dock 重启。

### 没有询问就采用的假设

- 独立版 `Launchpad.app` 的图标保持干净，不加标志：它就是启动台，不是配置 App。
- Dock 里没有 Apps 格子（用户把它移除了）时什么也不做，只记一条日志。
- 系统的 Apps.app 真在运行时，它自己推的图标走第二条通路、会盖住我们换的图。那时显示系统图标是合理的，不去挡它。

### 已知局限

- 外观切换的那一瞬，Apps 格子会闪一下系统图标：Dock 重设每个格子的图标时缓存还没有新外观的那一份，下一趟才换上。
- 只管 Dock。系统设置、聚焦搜索、通知中心里的 Apps 图标不经过 Dock，不受影响。

## 决策日志

| 日期 | 决定 | 理由 |
|------|------|------|
| 2026-11-14 | Created as Draft | 注入成功后 Dock 的 Apps 格子打开的是复刻的 Launchpad，图标应当跟着换；换了之后要让配置 App 的图标能区分出来 |
| 2026-11-14 | 只 hook 第一条通路，不碰两条替换通路 | App 图标走第一条。挡替换通路是 DockIconOverride 为「保留 Finder 自定义图标」做的事，与这里要的「指定一张图」无关 |
| 2026-11-14 | 撤销靠调 `-[Tile render]`，不自己存被挤掉的原图 | `render` 就是 Dock 调第一通路的入口，让 Dock 重走自己的绘制路径即可。DockIconOverride 当年没有这条路，是因为它要撤销的是任意 App 的任意格子，而这里只有一格 |
| 2026-11-14 | 两个拼写里先试带 `glassCompositingFilter:` 的 | macOS 27 上旧拼写还在、还被调用，但 App 图标已经全搬到新拼写；装错的后果是「一切看起来健康、功能永不生效」，比报错更难查 |
| 2026-11-14 | 开关与图标路径由 App 经通道下发，payload 不读偏好 | payload 在 Dock 进程里，让它读 App 的偏好域就多了一条隐式耦合；App 本来就知道自己装在哪 |
| 2026-11-14 | 配置 App 的标志用「右下角那格灰方块换成齿轮」 | 用户在两个候选（换格子、加角标）里选了这个：图标整体形状、玻璃材质与配色都不动，最内敛 |
| 2026-11-14 | 开关默认开 | 用户决定。注入本身是用户主动装的，图标跟着变才与「点 Apps 打开复刻的 Launchpad」一致 |
| 2026-11-14 | 干净图标由构建阶段从独立版产物拷 `.icns`，不预渲染 PNG | Xcode 自己从 `.icon` 编出 `.icns`，不引入 `ictool` 依赖，CI 成立，图标改了自动跟随；代价是只有一份外观，记作已知局限 |
| 2026-11-14 | 施加与撤销都用 `-[Tile render]`，候选拼写抽成 `DockTileIconHooks.candidates` | `render` 是 Dock 自己调第一通路的入口，整套「被挤掉的原图」记账因此不需要；候选列表抽出来，27 赖以工作的那个顺序才测得到 |
| 2026-11-14 | payload 首次真的换掉图标时记一条日志 | 「hook 装上了」和「Dock 真的来要过图标」是两件事，而后者单独坏掉时没有任何症状——27 上发生过 |
| 2026-11-14 | 开关改成 `async`，界面包一层 `Task` | `isEnabled` 在第一个挂起点之前就变，开关立刻响应；而测试能等到 payload 收到了什么 |
| 2026-11-14 | 在 27.2 上实测通过：拼写、安装、真的换过图、开关往返 | 见[实现说明](../Internal/DockAppsIcon.md)的验证记录。26.6.2 虚拟机未开机，旧拼写那条分支待测 |
| 2026-11-14 | 图像改由 IconServices 从 bundle 渲染，不再用 ImageIO 解 `.icns` | 用户指出深色模式没考虑。查证属实：`.icns` 里只有一套外观（四个表示，最大 512px），三套外观在 `Assets.car` 的 `AppIcon.iconstack` 里，只有 IconServices 渲染得出。这也顺带把原提案里「`.icns` 最大 256×256」这个写错的事实纠正了 |
| 2026-11-14 | 图标宿主 bundle 由 App 在运行时拼到 Application Support，不放进 App 包 | 包里放 `.app` 就是嵌套代码，LaunchServices 会注册它、签名与公证都要带上它——这正是独立版当初被压成 zip 的理由。放到 Application Support 两头都躲开了 |
| 2026-11-14 | 宿主 bundle 必须以 `.app` 结尾，且 `CFBundleExecutable` 必须真能执行 | 逐个形态渲染比对出来的：`.bundle` 的同样内容只画出文件夹图标；可执行文件缺失或没有执行权限时，渲染结果带一个「打不开」的禁止符号。脚本（`#!/bin/sh` + `exit 0`）就够，纯文本文件不行。两条都写成了回归测试 |
| 2026-11-14 | hook 里只读缓存，渲染放后台，渲完再 `render` 一次 | IconServices 渲染会阻塞，而 hook 是 Dock 正在绘制时调的。代价是切换外观时闪一下系统图标，换来的是绝不卡住别人的进程 |
| 2026-11-14 | 只有图标 bundle 的路径变了才丢缓存 | 开关关掉再打开时路径没变，丢了缓存等于平白多渲染一次、多闪一下系统图标 |
