# Dock 的 Apps 图标：实现说明

> 配套提案见[注入成功后把 Dock 的 Apps 图标换成 Launchpad 的图标](../Evolutions/0013-dock-apps-icon.md)。

注入之后，Dock 里点 Apps 打开的是这个工具复刻的 Launchpad，图标却还是系统的 Apps 图标 —— 那是一张「点下去不会发生的事」的画。这份说明讲清它是怎么被换掉的，以及系统升级之后要核对什么。

## 图标有两份，来源只有一处

| 文件 | 长什么样 | 谁用 |
|---|---|---|
| `LaunchpadAwakenerStandalone/AppIcon.icon` | 干净的 Launchpad 图标 | 独立版 App「Launchpad」自己；也是下面两份的来源 |
| `LaunchpadAwakener/AppIcon.icon` | 同一张图，3×3 网格右下角那块灰方块换成齿轮 | 注入版 App，即配置 App |
| `LaunchpadAwakener.app/Contents/Resources/LaunchpadDockIcon/` | 干净那张的零件：`Assets.car` 与 `AppIcon.icns` | 拼成下面那个 bundle |
| `~/Library/Application Support/LaunchpadAwakener/LaunchpadDockIcon.app` | 干净的那张 | payload 从它渲染 Dock 的 Apps 格子 |

**干净的那张只有独立版一个来源。**「Embed Standalone Launchpad」构建阶段本来就在处理独立版产物，顺便把它 `Contents/Resources/` 里的 `Assets.car` 与 `AppIcon.icns` 拷进注入版的 `Contents/Resources/LaunchpadDockIcon/`。这两份是 Xcode 从 `AppIcon.icon` 编出来的，所以不引入 Icon Composer 的 `ictool` 这类构建期依赖，CI 上同样成立，而且独立版图标一改，Dock 上的也跟着改。`RunScript.sh` 构建完会核对包里有它们。

**所以不要给独立版的图标加齿轮。** 齿轮是「这是配置 App」的标记，只属于注入版；独立版就是启动台本身，Dock 上那一格也是。两边都加，就没有东西能把它们区分开了。

齿轮是 `LaunchpadAwakener/AppIcon.icon/Assets/tile9.svg`：8 个齿，齿尖半径 76、齿根 61、中心孔 26，画在原来那块灰方块的位置（中心 720,740，1024 的画布）。要改形状就改这个 SVG；外观、材质与颜色都由 `icon.json` 里 `tiles` 组的既有设置管，不必动。预览怎么渲染见[渲染 Icon Composer 预览](#渲染预览)。

## 为什么是一个 bundle，而不是一张图

**`.icns` 只有一套外观。** 把独立版编出来的 `AppIcon.icns` 拆开看，里面是四个表示 —— `ic04`、`ic07`、`ic11`、`ic13`，16 到 512 像素，全是同一套扁平位图。macOS 26 与 27 的 App 图标有三套外观（浅色、深色、着色），它们以分层的 `AppIcon.iconstack` 存在 `Assets.car` 里：

```bash
/usr/bin/assetutil --info Launchpad.app/Contents/Resources/Assets.car
#   "Appearances": { "NSAppearanceNameAqua": 8, "NSAppearanceNameDarkAqua": 1, "ISAppearanceTintable": 10, … }
#   AppIcon  NSAppearanceNameAqua       AppIcon.iconstack
#   AppIcon  NSAppearanceNameDarkAqua   AppIcon.iconstack
#   AppIcon  ISAppearanceTintable       AppIcon.iconstack
```

渲染这三套的只有 IconServices，而**它只从 bundle 渲染**（`-[ISIcon initWithURL:]` 收的是一个包的 URL）。所以要让 Apps 格子跟着系统的外观走，就必须有一个「图标是干净 Launchpad」的 bundle。

**这个 bundle 不能放进注入版的包里。** 包里的 `.app` 是嵌套代码：LaunchServices 会注册它，每一道签名与公证都要带上它——独立版当初被压成 `Launchpad.zip` 而不是直接放进去，就是这个理由。所以 App 包里只放零件，`DockAppsIconHost` 在第一次要用时把它们拼成 `~/Library/Application Support/LaunchpadAwakener/LaunchpadDockIcon.app`，那里没人注册它，也不进任何签名流程。重拼的判据是零件的大小与修改时间，所以换一个构建才会重拼，平时只花两次 `stat`。

**这个 bundle 有两条要求，错一条图标就不对，而且都不会报错：**

| 要求 | 不满足时渲染出什么 |
|---|---|
| 目录必须以 `.app` 结尾 | 同样内容的 `.bundle` 只画出一个文件夹图标，根本不读 asset catalog |
| `CFBundleExecutable` 指的文件必须**真能执行** | 图标上盖一个「打不开」的禁止符号 |

第二条只要一个 `#!/bin/sh` + `exit 0` 的脚本就满足（纯文本文件不行，空文件也不行），所以 `DockAppsIconHost` 就写这么一个，从不运行它。两条都是把各种形态逐个渲染出来比对发现的，现在由 `DockAppsIconHostTests` 盯着——其中一条测的就是「把执行权限去掉，渲染结果必须不一样」。

## 图标只从一条路进 Dock 的格子

Dock 里每个图标格子是它内部 `Tile` 类的实例，图像只能从三个方法进去（姊妹项目 DockIconOverride 在 26.5.2 与 27.2 上逆向验证过，见它的《Dock 图标的三条通路》）：

| 入口 | 图像来自哪 |
|---|---|
| `setImage:preferredGlassBackgroundStyle:…` | Dock 自己经 LaunchServices 读 App 包的图标 |
| `setReplacementAppImage:usesIconServices:…` | 运行中的 App 设置 `NSApplication.applicationIconImage` |
| `setReplacementExtraImage:usesIconServices:…` | App 的 Dock tile 插件，跑在独立的 XPC 进程里 |

App 图标走第一条，**所以这里只 hook 第一条**。另外两条是「替换」通路，挡掉它们是 DockIconOverride 为「保留用户在 Finder 里粘贴的图标」做的事，和「指定一张图」无关。系统的 Apps 真在运行时它自己推的图标走第二条、会盖住我们换的图 —— 那时显示系统图标是合理的，不去挡它。

## 两个拼写，顺序是整个功能

macOS 26 把玻璃滤镜放在 `Tile` 的 `glassImageCompositingFilter` 属性上；27 删掉属性，改成每次设图像时当尾参数传。于是第一条通路有两个拼写：

| | 选择子 | 类型编码 |
|---|---|---|
| macOS 26.6.2 | `setImage:preferredGlassBackgroundStyle:` | `v32@0:8@16q24` |
| macOS 27.2 | `setImage:preferredGlassBackgroundStyle:glassCompositingFilter:` | `v40@0:8@16q24@32` |

**27 上两个都在、都被调用，但 App 图标只走带滤镜的那个。** 把 27.2 Dock 二进制里两个选择子 stub 的交叉引用拉出来对比：旧拼写剩下的九个调用点全是 stack、trash、folder、URL 与窗口格子，而 `-[DOCKFileTile render]`、`-[DOCKProcessTile render]`、`-[DockBar _handleLaunchNotification:data:]` 这些 App 图标的路径全搬到了新拼写。所以在 27 上 hook 旧拼写的后果是：签名校验通过、hook 装上、日志报成功，然后永远收不到一个 App 图标 —— 比报错糟得多，因为看起来什么都没出错。

`DockTileIconHooks.candidates` 因此**把带滤镜的放在第一个**，取宿主匹配的第一个。这个顺序有测试盯着（`DockSignatureTests`）。滤镜参数原样转发，所以 27 的「通透」图标外观不受影响。

## 施加与撤销都靠 `-[Tile render]`

hook 是入口过滤器：它决定「下一次有人给这个格子塞图标时会发生什么」。可开关的功能还需要能动已经画在屏幕上的格子。

Dock 自带这个原语：`-[Tile render]` 正是 Dock 自己重画一个格子的入口，而它调的就是第一条通路。于是：

- **开关打开** → 找到 Apps 格子、调 `render` → Dock 重走自己的绘制路径 → hook 把图换掉。
- **开关关闭** → 同样调 `render` → hook 这次不换 → Dock 自己的图标回来。

**所以不需要记账「被我们挤掉的那张图」。** DockIconOverride 的 `forceIcon` 要存一张弱引用表，是因为它要撤销的是任意 App 的任意格子；这里只有一格，而且 Dock 自己能重新画出来。

Apps 格子是从 `-[DockBar tiles]` 里按身份筛出来的 —— `DockBarReference` 已经在宿主的数据段里认出了 `DockBar`。Dock 没有「Apps 格子」这个概念，Apps 就是一个普通的 App 格子，所以身份只能从它代表的包来判断：`-[Tile fileURL]` 解析出的标识符是 `com.apple.apps.launcher`，或者路径是 `/System/Applications/Apps.app`。两个版本的 Dock 二进制里都带着这个标识符。

**路径先比、标识符后读，而且「不是」的结果也要缓存。** 这个 setter 在 Dock 的渲染热路径上（图标尺寸变、外观变、App 启动退出都会触发），而读标识符意味着打开包的 `Info.plist`；绝大多数格子永远不是 Apps，恰恰是它们被问得最频繁。

## 外观跟着 Dock 走，渲染不在 Dock 的线程上

descriptor 直接复制 Dock 自己的（`DockEnvironment.iconAppearance.iconDescriptor`，取自 `DockBar.environment.iconAppearanceMonitor.appearance`），只改尺寸。于是浅色、深色、透明、着色以及用户挑的着色颜色全部跟随，这段代码不需要知道任何一项是什么意思——复刻的 Launchpad 里每个 App 图标也是这么画的（`SpringboardIconProvider`）。

**IconServices 渲染期间阻塞，而这个 setter 是 Dock 正在绘制时调的。** 所以 hook 里只读缓存：

1. 没命中 → 返回 nil，这一趟 Dock 画它自己的图标；同时在后台渲染。
2. 渲染完存进缓存，再调一次 `-[Tile render]`。
3. 第二趟命中缓存，Launchpad 的图标换上去。

**换外观走的也是这条路**：Dock 在外观变化时会重设每个格子的图标，那一趟缓存里没有新外观的那份，于是闪一下系统图标，下一趟就换上。

缓存键是「bundle 路径 + 像素宽 + 外观的那几个字段（`appearance`、`appearanceVariant`、`background`、着色颜色）」，不是 descriptor 对象本身——Dock 每次换外观都换一个新 descriptor 对象，对象身份说明不了任何事。一次登录会话里这个缓存通常只有一两条。

只有 **bundle 路径变了**才清缓存（换了一个构建）。开关关掉再打开时路径没变，清了等于白渲染一次、白闪一下。

## 开关在 App 这边，payload 只执行

payload 跑在 Dock 进程里。它不读 App 的偏好域，也不猜 App 装在哪：**开关状态与图标 bundle 的绝对路径都由 App 经 payload 通道下发**（`DockAppsIconRequest`）。拼那个 bundle 也是 App 的事，payload 只拿到一个路径。

- App 启动时 `DockAppsIconController.applyStoredSetting()` 发一次，在重连已有 payload 之前。
- 用户拨开关时立刻再发一次。
- 每个新连上的 payload（注入成功后握手完、或 App 重启后重连）都会被 `PayloadInjectionCoordinator.sendDockAppsIconSettings(to:)` 补发一次。

请求里**总是带着 bundle 路径**，哪怕这次是要关掉它：这样打开时不需要第二条消息，重连的 payload 从收到的第一条消息里就有路径。

Dock 重启到 App 把设置发过去之间的那一瞬，Apps 格子是系统图标。Dock 重启本来就会闪一下，这在里头看不出来。

**退回开关（`/tmp/LaunchpadAwakener.disabled`）打开时也让出图标**：那时点 Apps 开的是系统的 Apps，系统图标才是「点下去会发生什么」的诚实写照。这个检查在确认是 Apps 格子之后才做，所以只有那一格付一次 `fileExists` 的代价。图标不会在开关打开的瞬间变，而是在 Dock 下一次画这一格时跟上——用户打开系统的 Apps，正好就触发那一次。

## 装不上会怎样

这批 hook 是**自己一批**，和「Dock 显隐」那批分开，都在主批之后原子安装。任何一批对不上，只失去它那一项：

- 图标 hook 装不上 → Apps 格子保持系统图标，Launchpad 本身照常。
- `fileURL` / `render` / `tiles` 任何一个不符 → 同上，并且控制面板会显示 payload 回报的 `unsupported` 原因。
- 图标 bundle 拼不出来（包里没有零件、Application Support 写不进去）→ 同上，控制面板显示原因，开关变灰。
- Dock 的 `iconAppearanceMonitor` 够不着 → 不换图标，保持系统的。宁可不换，也不拿一个猜的外观去渲染。

这些方法**故意不在** `DockHostInterface.requiredMethods` 里 —— 放进去就会让一个只是改了图标 setter 的 Dock 把整个复刻关掉。`DockSignatureTests` 有一条断言盯着这件事。

## 系统升级后要核对两件事

```bash
/usr/bin/log show --info --last 5m --predicate 'subsystem == "com.MxIris.LaunchpadAwakener"'
```

1. **hook 装上了吗** —— 找这两条：

   ```
   [DockTileIconHooks] The Dock's icon setter on this host: setImage:preferredGlassBackgroundStyle:glassCompositingFilter:
   [Payload] Installed 1 hook(s) on the Dock's icon path: the Apps tile can show the Launchpad icon
   ```

   没有的话，日志里每个候选拼写后面跟着宿主的实际编码；确认参数含义没变之后，更新 `PayloadHooks.swift` 里的声明并把编码记进 `DockSignatureTests`。

2. **hook 真的在跑吗** —— 这一条是关键，它区分「装上了」和「Dock 真的来要过图标」：

   ```
   [DockAppsIconOverride] The Dock asked for the Apps tile's icon and was given Launchpad's
   ```

   **装上了却一直没有这一条，说明 Dock 把 App 图标换到了另一个拼写上**（这正是 27 发生过的事）。这时要去查选择子 stub 的交叉引用，看 `-[DOCKFileTile render]` 现在调的是哪个变体。

3. **外观对不对** —— 每种外观、每个格子尺寸各一条：

   ```
   [DockAppsIconImage] Rendered the Apps tile's icon: appearance 1 variant 0 at 256px
   ```

   `appearance` 0 是浅、1 是深；`variant` 3 是透明、2 是着色深；带 `tinted` 说明用了用户挑的着色颜色。**图标颜色不对就先看这一条**：它说的是 Dock 当时告诉我们的外观，对不上就是 `DockEnvironment.iconAppearance` 那条链出了问题，而不是渲染。一条都没有，说明 IconServices 没渲染出东西——多半是那个 bundle 的形态坏了，见上面「为什么是一个 bundle」里的两条要求。

另外 `The Apps tile was asked to show … (N tile(s))` 说明 App 下发了什么、找到了几个 Apps 格子。`0` 不是故障，是用户把 Apps 从 Dock 里移除了。它说的是**请求**而不是结果：退回开关开着时，这条照样出现，而上面那条「Dock 来要过图标」不会。

## 已知局限

- **换外观时闪一下系统图标。** Dock 重设每个格子的图标那一趟，缓存里还没有新外观的那份；下一趟才换上。
- **只管 Dock。** 系统设置、聚焦搜索、通知中心里的 Apps 图标不经过 Dock。
- **Application Support 里多一份 1.7 MB 的图标资源**，是 App 包里那份零件的副本。

## 验证记录

- **macOS 27.2（26B123），MacBook 测试机，2026-11-14**：拼写解析到带滤镜的那个，hook 装上，Dock 来要过图标并拿到了 Launchpad 的，找到 1 个 Apps 格子；关掉开关后 `The Apps tile was asked to show the Dock's own icon`，再打开又回来。
- **退回开关，同机同日**：开着时重启 Dock，hook 照常装上、设置照常下发，但「Dock 来要过图标」那条不出现——图标让给了系统；删掉开关文件再重启 Dock，那条就回来了。
- **macOS 27.2（26B123），MacBook 测试机，2026-11-14（改用 IconServices 之后）**：App 拼出了 `~/Library/Application Support/LaunchpadAwakener/LaunchpadDockIcon.app`，hook 装上，`Rendered the Apps tile's icon: appearance 1 variant 0 at 256px`（当时机器是深色模式，渲的就是深色那套），随即换上。开关关掉→`the Dock's own icon`、打开→图标回来；退回开关打开时不渲染也不替换，删掉开关文件后恢复。
- **换外观那一下未实机验证**：要让运行中的 Dock 收到外观变化通知，得去改测试机的系统设置。浅色与深色渲出的图不同由 `DockAppsIconHostTests` 的单元测试守着；实机日志证明的是「用 Dock 当时的外观渲染」。
- **macOS 26.6.2 虚拟机**：未实测，待开机验证旧拼写那条分支。

## 渲染预览

```bash
ICTOOL="/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"
"$ICTOOL" LaunchpadAwakener/AppIcon.icon --export-image --output-file preview.png \
    --platform macOS --rendition Default --width 512 --height 512 --scale 1
```

`--rendition` 可取 `Default`、`Dark`、`TintedDark`。`Xcode.app/Contents/Developer/usr/bin/ictool` 是另一个工具，不能用。
