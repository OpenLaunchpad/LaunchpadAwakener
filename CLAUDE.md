# LaunchpadAwakener

在 macOS 26 与 27 的 Dock 里复刻 macOS 15 的 Launchpad：一个注入 Dock 的 payload，加上负责注入的 App 与特权 daemon。macOS 26 与 27 的任何 Dock 构建都直接工作：复刻要的两个全局变量在运行时按它们持有的对象的类认出来，不按构建记地址（见实现说明「关键设计决策」）。升级系统后只需确认日志里方法签名没有不符的。工程由 [InjectionScaffold](https://github.com/Mx-Iris/InjectionScaffold) 生成，方案见提案 [在 macOS 27 的 Dock 中复刻 macOS 15 的 Launchpad](Documentations/Evolutions/draft-launchpad-replica.md)。

另有一个不注入 Dock 的独立版 App「Launchpad」：自己开一扇盖住 Dock 所在那块屏幕（连 Dock 与菜单栏）的窗口，画同一套 Launchpad，不需要关 SIP。两版共用 Launchpad 本身的代码，方案见提案 [不注入 Dock 的独立版 Launchpad](Documentations/Evolutions/0002-standalone-launchpad.md)，实现见[独立版实现说明](Documentations/Internal/StandaloneLaunchpad.md)。

## 只在测试机上运行

**开发机（两台 Mac Studio）上只编译、跑单元测试，绝不运行 App、注入 Dock 或重启 Dock。** 全屏窗口一旦失控，整台机器的输入都会被锁住，只能重启——这在 macOS 26 上真实发生过。运行与验证只在测试机上做：27 用测试用的 MacBook，`ssh JH@192.168.50.13`，macOS 27.2（26B123），SIP 已关，App 装在 `/Applications/LaunchpadAwakener.app`；26 用下面说的虚拟机（虚拟机里失控只锁住虚拟机）。

在开发机上编译后部署（`<agent>` 是 `claude` 或 `codex`，各用各的构建目录）：

```bash
queued-build ./RunScript.sh --no-launch --derived-data /Volumes/DerivedData/Agents.noindex/<agent>/DerivedData/LaunchpadAwakener
ssh JH@192.168.50.13 'osascript -e "tell application \"LaunchpadAwakener\" to quit"'
rsync -a --delete /Volumes/DerivedData/Agents.noindex/<agent>/DerivedData/LaunchpadAwakener/Build/Products/Debug/LaunchpadAwakener.app/ JH@192.168.50.13:/Applications/LaunchpadAwakener.app/
ssh JH@192.168.50.13 'killall Dock; sleep 2; open /Applications/LaunchpadAwakener.app'
```

日志的 subsystem 是 `com.MxIris.LaunchpadAwakener`，info 级要加 `--info`：`/usr/bin/log show --info --last 5m --predicate 'subsystem == "com.MxIris.LaunchpadAwakener"'`。经 ssh 跑时**必须写全路径**：MacBook 的登录 shell 是 zsh，zsh 有个同名的内建命令 `log`，裸写 `log show …` 只会报 `too many arguments`，配上 `2>/dev/null` 就成了「一条日志也没有」。

出了问题，先经 ssh 退回系统的 Apps 并换掉注入过的 Dock：`touch /tmp/LaunchpadAwakener.disabled; killall Dock`。

**独立版**同样只在测试机上运行：一打开就盖住整块屏幕，开发机上绝不打开，`RunScript.sh` 也从不替它启动。部署与非交互验证：

```bash
queued-build ./RunScript.sh --scheme LaunchpadAwakenerStandalone --derived-data /Volumes/DerivedData/Agents.noindex/<agent>/DerivedData/LaunchpadAwakener
ssh JH@192.168.50.13 'osascript -e "tell application \"Launchpad\" to quit"'
rsync -a --delete /Volumes/DerivedData/Agents.noindex/<agent>/DerivedData/LaunchpadAwakener/Build/Products/Debug/Launchpad.app/ JH@192.168.50.13:/Applications/Launchpad.app/
ssh JH@192.168.50.13 'open -n /Applications/Launchpad.app --args --self-check'
```

带 `--self-check` 的开发构建只在离屏建一次界面、把宿主找到的东西（Dock 的位置与厚度、壁纸来源、图标样式、布局库、窗口）写进日志，15 秒后自己退出，不上屏。不带参数打开就是显示界面，属于交互操作，用户没提就不做。界面卡住时：`touch /tmp/LaunchpadAwakener.disabled` 后它不再显示，`pkill -x Launchpad` 直接结束它；主线程卡住超过 3 秒，它自己的看门狗也会经窗口服务器把窗口撤下。

**macOS 26 上的验证**用 Ultra 上 VirtualBuddy 的 macOS 26 虚拟机：26.6.2（25G83），机器名 `VMdexuniji`，账户 `vm`，`ssh vm@<地址>` 免密（地址由 Ultra 的 `/var/db/dhcpd_leases` 按机器名查，2026-11-08 是 `192.168.64.16`），SIP 已关，App 装在 `/Applications/LaunchpadAwakener.app`，daemon 已在登录项里批准。部署照上面的命令，把地址换成虚拟机的。它和 15 的虚拟机一样没装开发工具（`otool`、`strings`、`python3` 会弹安装提示），查东西用 `md5`、`osascript -l JavaScript` 这类系统自带的命令。

**用户要求看界面时**（截图、点击属于交互操作，用户没提就不做）：经 ssh 跑 `open -a Apps` 打开、`screencapture -x` 截图（能截到窗口内容）、`screencapture -v -V <秒>` 录屏后拷回本机用 ffmpeg 抽帧（录屏启动要零点几秒到一两秒，先开录、等一秒再操作）；点击与拖动用在 MacBook 上编译的一个发 `CGEvent` 的小工具，经 ssh 发的事件实测有效。开发构建 20 秒没有输入就自动收起，打开与操作要放在同一条命令里。拖动会改用户的布局，测完要还原。

**和真正的 macOS 15 对照**：用户在 Ultra 上用 VirtualBuddy 跑着一台 macOS 15.5（24F74）虚拟机，机器名 `JHs-macOS-15-VM`，账户 `vm`，`ssh vm@<地址>` 免密（地址由 Ultra 的 `/var/db/dhcpd_leases` 按机器名查，2026-11-06 是 `192.168.64.15`）。虚拟机没装开发工具：发 `CGEvent` 的小工具要在本机用 `xcrun swiftc -target arm64-apple-macos15.0` 编好再拷过去，虚拟机重启后 `/tmp` 会清空。经 ssh 录屏、发事件所需的权限已写进它的权限数据库（当时关着 SIP）。`open -a Launchpad` 打开启动台，用 `screencapture -v` 录屏。虚拟机录屏会掉帧，连着几帧完全相同，只能对照画面构成，不能拿来量时间曲线。它登录不了 Apple ID，装不了 App Store 的 App；对照抖动模式的关闭按钮与删除，靠一个带空收据的 App：15 判断能不能删只看 `Contents/_MASReceipt/receipt` 在不在，不读内容（网页 App 也能删，但确认气泡写「移除」）。虚拟机里放着一个，是国际象棋的副本「可删测试」（bundle ID `com.MxIris.LaunchpadAwakener.DeletionProbe`），去掉了分类，排在最后一页（带着「棋类游戏」分类时 15 会把它归进「游戏」文件夹）。删掉后双击它桌面上的 `放一个可删除的App.command` 再放一个，每次一个新的，依次叫「可删测试 2」「可删测试 3」。脚本用 `cp -R` 复制系统 App，不用 `ditto`：`ditto` 会因系统 App 的 `restricted` 标志报 `Operation not permitted`。26 的虚拟机里也放了一个，复刻的卸载器同样判它可删。

## 结构

六个二进制，Xcode 项目里只放外壳，代码都在本地 Swift 包：

| 目录 | 是什么 |
|---|---|
| `LaunchpadAwakener/` | App 外壳：`main.swift` 建 `ApplicationDelegate` 并运行。菜单栏 App，窗口是控制面板（见[控制面板实现说明](Documentations/Internal/ControlPanel.md)） |
| `LaunchpadAwakenerDaemon/` | 特权 daemon 的 `main.swift`，两行 |
| `LaunchpadAwakenerPayload/` | payload 的 `main.m`，提供两条注入入口 |
| `LaunchpadAwakenerTextInput/` | 文本输入辅助进程的 `main.swift`：嵌在 App 里的 LaunchAgent，替 Launchpad 托管搜索框与改名框，好让输入法能用；也替它弹删除 App 的确认 popover |
| `LaunchpadAwakenerStandalone/` | 独立版 App「Launchpad」的外壳：只有 `main.swift` 与图标 |
| `LaunchpadAwakenerPackage/Sources/LaunchpadAwakenerShared` | 服务名、版本、路径，以及 payload 与文本输入辅助进程之间的 `Codable` 消息。**不依赖任何东西** |
| `LaunchpadAwakenerPackage/Sources/LaunchpadAwakenerPrivateInterfaces` | 只有头文件：IconServices、IconFoundation、SkyLight、QuartzCore 导出的私有类的声明，供直接调用。不引入 AppKit |
| `LaunchpadAwakenerPackage/Sources/LaunchpadAwakenerAppKitPrivateInterfaces` | 只有头文件：AppKit 私有方法的声明，只给文本输入辅助进程用 |
| `LaunchpadAwakenerPackage/Sources/LaunchpadAwakenerAppCore` | daemon 生命周期与自愈、进程监视、注入编排、payload 通道的 App 一侧、控制面板要显示的状态与文案、整理 Launchpad 窗口的逻辑与视图模型 |
| `LaunchpadAwakenerPackage/Sources/LaunchpadAwakenerAppUI` | 注入版 App 的 AppKit 界面：delegate、控制面板、菜单栏、整理窗口。App target 只链接这一个产物 |
| `LaunchpadAwakenerPackage/Sources/LaunchpadAwakenerSharedUI` | 两个 App 共用的 AppKit 部件：分组表单、按内容定高的窗口、主菜单、登录时启动的判断 |
| `LaunchpadAwakenerPackage/Sources/LaunchpadAwakenerPayloadInterface` | payload 通道的请求与回报类型。App 与 payload 都链接它，只放请求类型 |
| `LaunchpadAwakenerPackage/Sources/LaunchpadAwakenerDaemonCore` | 组装特权 XPC 服务端 |
| `LaunchpadAwakenerPackage/Sources/LaunchpadAwakenerSpringboardCore` | Launchpad 本身：布局库与界面层。经宿主接口 `SpringboardHost` 拿窗口、图层类、壁纸这些，不认识 Dock，不链接 AppKit |
| `LaunchpadAwakenerPackage/Sources/LaunchpadAwakenerPayloadCore` | 跑在 Dock 里、围着 Launchpad 的代码：Dock 宿主、hook 声明、入口 |
| `LaunchpadAwakenerPackage/Sources/LaunchpadAwakenerTextInputCore` | 文本输入辅助进程：经系统 Swift XPC 接口（`XPCListener`）的服务、托管的 `NSTextField`、删除确认的 `NSPopover`。只有它链接 AppKit 的私有部分 |
| `LaunchpadAwakenerPackage/Sources/LaunchpadAwakenerStandaloneCore` | 独立版的宿主：盖住全屏的窗口与事件、壁纸、图标样式、看门狗、设置窗口。链接 AppKit |

模块按「谁链接它」划分。App 不能链接 daemon 的特权依赖，payload 要尽量小 —— 它会被映射进一个并没有请求它的进程。

hook 与 Dock 自己的类（Dock 不导出任何类）用 FrameworkToolbox 的 ObjCRuntimeToolbox，而且**只用 `ObjCRuntimeToolbox-Static` 这个产物**：payload 在 Dock 里没有 `@rpath` 可找，换成 `.dynamic` 的 `ObjCRuntimeToolbox` 它就加载不了。只有 payload 嵌它。

两个与 Launchpad 有关的模块再按层分目录：

| 目录 | 放什么 |
|---|---|
| `SpringboardCore/Hosting/` | 宿主接口，以及选定宿主的 `SpringboardHostSystem` |
| `SpringboardCore/System/` | 系统框架的私有接口（Core Animation 滤镜、IconServices、SkyLight），两个宿主都能用 |
| `SpringboardCore/Data/` | 布局库、旧库导入、App 的发现 |
| `SpringboardCore/Interface/` | 界面层，按 15.5 的 `ECSB*` / `ECPager*` 划分 |
| `PayloadCore/Host/` | 调用 Dock 内部方法的地方，也是 Dock 这一侧的宿主：全局扫描、签名校验、`WALayerKitWindow`、`EC*` 图层类 |
| `PayloadCore/Integration/` | hook 声明，以及事件接管 |

调 Dock 内部方法一律经过 `PayloadCore/Host/`：先按类型编码校验，再调用。界面层要 Dock 的东西，一律经宿主接口要，不直接调 `Host/` 里的类型。

私有方法的写法：

- **系统框架导出的类**（IconServices、IconFoundation、SkyLight、QuartzCore、AppKit）在两个 `PrivateInterfaces` 模块的头文件里声明，直接调用，**运行时不再核对**。所以新加的声明必须先在 26 与 27 上确认方法存在、签名一致（两台测试机上用 `osascript -l JavaScript` 调 `class_getInstanceMethod` 与 `method_getTypeEncoding`，它们没装开发工具也能跑），再在 `SystemPrivateInterfaceTests` 或 `StandaloneIconStyleTests` 里实际调用一次。私有框架经 `Package.swift` 的 `linkingPrivateFrameworks` 链接；类簇照样声明在对外的那个类上（`ISIcon` 的 `+alloc` 给的是 `ISIconFactory`）。
- **Dock 里类名固定的类**写成 `@RuntimeClassProxy("类名")` 协议：选择子与编码由 Swift 声明推出，第一次调用前整批核对。实例方法与属性照常写；构造写成 `init?(…)`（第一个标签决定选择子，`init(frame:)` 即 `initWithFrame:`）；类方法写成 `static func`；block 参数写成 `@escaping @convention(block) (…) -> …`。Dock 的要把协议的 `methodRequirements` 加进 `DockHostInterface.requiredMethods`（或玻璃、Dock 显隐各自的清单），编码记进 `DockSignatureTests`（类方法的键前加 `+`）。可选功能的方法单独成协议，一个不符整个协议就停用。
- **经别的对象拿到、类名随系统版本变的对象**（`DockBar.environment` 交出的那些，环境对象在 26 上叫 `Environment`、27 上叫 `_TtC8DockCore11Environment`）写成 `@RuntimeObjectProxy` 协议：写法相同，按对象自己的类核对，每个类核对一次。它没有类可调，不能写 `init?` 与 `static`。编码同样记进 `DockSignatureTests`。
- **代码里不写类型编码字面量**，也不用 `DynamicObject`：它按原样拷参数字节、不核对参数类型。宏表达不了的调用，先给 FrameworkToolbox 的 ObjCRuntimeToolbox 补上，再来用。

## 界面

两个 App 的界面都是 AppKit，用 UIFoundation（开 `AppKitPlus` trait）、AppKitPlus、swift-navigation 与 SnapKit，仓库里不写 SwiftUI。写界面之前先读 `uifoundation-widgets`、`appkit-app-modernization`、`swift-navigation-bindings` 三个 skill；界面层的约定和只在真机上才看得出的坑见 [AppKit 界面层实现说明](Documentations/Internal/AppKitInterface.md)。改了 UIFoundation 的 trait 之后，Xcode 不会重编已经编过的依赖，要删掉整个构建目录再编。

## 构建

**用 `./RunScript.sh`，不要自己拼 xcodebuild 命令。**

```bash
./RunScript.sh              # 构建并启动
./RunScript.sh --no-launch  # 只构建
./RunScript.sh --dry-run    # 只打印命令
./RunScript.sh --scheme LaunchpadAwakenerStandalone  # 构建独立版；从不启动它
./RunScript.sh --no-launch -- CODE_SIGN_IDENTITY=-   # -- 之后的参数原样交给 xcodebuild，CI 靠它做临时签名
```

独立版不注入，不需要 arm64e 切片，脚本也不替它核对切片。

注入版的 scheme 也会顺带编出独立版，由「Embed Standalone Launchpad」阶段压成 `Contents/Resources/Launchpad.zip` 放进注入版：SIP 没关时，控制面板从这里一键安装独立版。脚本构建完会核对包里有它。

daemon 必须带 arm64e 切片才能注入 Dock 这类 arm64e 系统进程 —— 签目标线程 PC 的那条 PAC 指令在 arm64 构建里是空操作。这需要五处配置同时成立，外加一个 `-destination 'generic/platform=macOS'`。

**在 Xcode GUI 里构建要把运行目标切成「Any Mac」**：My Mac 对应 `platform=macOS`（为本机构建），会静默丢掉 arm64e 切片，daemon 随即链接失败；Any Mac 对应 `generic/platform=macOS`，能正常构建。这是「Xcode 编不过」的第一个原因，第二个见下文讲 x86_64 的那一段。

细节全部记在脚手架的
[BuildingForArm64eTargets.md](https://github.com/Mx-Iris/InjectionScaffold) 里。**动架构相关设置之前先读它** —— 每一处"显而易见"的改法都试过，也都记了失败原因。特别是：`ENABLE_POINTER_AUTHENTICATION` 绝不能提到项目级，否则本地包的 arm64e 切片会替换掉 arm64，macro plugin 随即链接失败。

**x86_64 目前靠 `RunScript.sh` 传的 `-IDEEnableNewPackagePIFBuilder=NO` 保住**。Xcode 27 默认用新的 package 构建器，它把带 arm64e 的本地包写死成只编 `arm64 arm64e arm64e.x1`，凡是还编 x86_64 的 target 都会报 `Unable to resolve module dependency`。这个参数只对脚本生效，在 Xcode 里构建照样报这个错。要在 Xcode 里编，只能本机执行 `defaults write com.apple.dt.Xcode IDEEnableNewPackagePIFBuilder -bool NO`，所有项目都会受影响。x86_64 只是给还停在 macOS 26 的 Intel Mac 留的，macOS 27 已经不支持 Intel。哪天新版 Xcode 不认这个参数了，就当 x86_64 退役：删掉参数，在项目级设 `EXCLUDED_ARCHS = x86_64`。细节在 `RunScript.sh` 注释的第 5 条。

脚本构建完会自动校验切片：

```
[RunScript] Verifying architectures:
[RunScript]   daemon : x86_64 arm64 arm64e
[RunScript]   payload: x86_64 arm64 arm64e
```

**不要因为构建"通过了"就认为没问题** —— 一个悄悄产出 arm64-only daemon 的构建看起来和正确构建一模一样，直到注入时才暴露。

## 发布

用 [AppRelease](https://github.com/Mx-Iris/AppRelease) 发布，配置是根目录的 `Release.zsh`：`app-release all` 依次归档、导出 Developer ID、公证、装订公证票据、打 zip，加 `--publish` 才打 tag 并建 GitHub Release。版本号取注入版 target 的 `MARKETING_VERSION`。

- **归档时就签 Developer ID 并带时间戳**（`release_archive_arguments`）：独立版压在 `Contents/Resources/Launchpad.zip` 里，导出时签不到它，公证服务却会检查 zip 里面。
- **独立版 target 设了 `SKIP_INSTALL = YES`**：不设它会和注入版一起装进归档，归档就成了导出拒收的「通用归档」。归档时 `BUILT_PRODUCTS_DIR` 里的独立版只是一个符号链接，所以嵌入脚本先解析出真实路径。
- **嵌入脚本压缩前由内向外重签独立版的拷贝**：嵌入框架时 Xcode 只重签框架本身，框架 Resources 里带可执行文件的 bundle（AppKitPlus 的 `AppKitPlusSpriteKitAssets.bundle`）留着厂商的 Apple Development 签名、没有时间戳；外层 App 里的那份由导出重签，zip 里的那份没人管，公证因此被拒过一次。脚本用这次构建的签名身份，先签这类 bundle，再签框架，最后签 App；`OTHER_CODE_SIGN_FLAGS` 带 `--timestamp` 时才加时间戳，所以 Debug 构建不需要联网。
- **两个钩子补上引擎不查的东西**：daemon 与 payload 带 arm64e、两个 launchd plist 指向的程序在包里、zip 里有独立版；导出后，导出包和 zip 里的独立版中每一个 Mach-O 文件都要是这个团队的 Developer ID 签名、带时间戳，daemon、输入法辅助进程与独立版还要开着硬化运行时。
- agent 试跑时把产物和构建目录都放进自己的目录，只跑到导出：`APP_RELEASE_OUTPUT_ROOT=/Volumes/DerivedData/Agents.noindex/<agent>/AppRelease/LaunchpadAwakener app-release all --skip-notarization --derived-data-path /Volumes/DerivedData/Agents.noindex/<agent>/DerivedData/LaunchpadAwakener`。公证会把 App 传给 Apple，`--publish` 会推 tag、建 GitHub Release，用户没要求就不做。
- **CI**：`.github/workflows/CI.yml` 在推到 main 和开 PR 时跑单元测试，并用临时签名编一次 Release（CI 上没有开发证书），借 RunScript 的检查盯住切片、plist 与嵌入的独立版。`Release.yml` 在推送 `v<MARKETING_VERSION>` 形式的 tag（如 `v1.0`）时完整发布并建 GitHub Release；在 Actions 页面手动运行则跑到打 zip 为止，产物留作 artifact，不发布。两者都用 GitHub 的 `xcode-27` 预览镜像，`DEVELOPER_DIR` 指定 Xcode 27.2。
- **签名与公证的 secret 放在 OpenLaunchpad 组织级**（`DEVELOPER_ID_CERTIFICATE_*`、`NOTARY_*`），由 workflow 转成 AppRelease 认的 `APP_RELEASE_*` 环境变量。组织是免费套餐，组织级 secret 只给公开仓库用：仓库公开之前，`Release.yml` 会在第一步就报出拿不到证书。

- **发布说明**：`Release.zsh` 没设 `release_notes_path`，AppRelease 建的 Release 正文是空的；发布后用 `gh release edit <tag> --notes-file <文件>` 补上，标题设成 `LaunchpadAwakener <版本>`。

1.0 于 2026-11-12 在本机用 `app-release all --publish` 发布（tag `v1.0`），没有走 CI：当时仓库还是私有的，拿不到组织级 secret。从下一个版本起推 tag、由 CI 发布，发版前先把注入版 target 的 `MARKETING_VERSION` 改成新版本号。1.0 这个包还没在测试机上装过。

## 改完代码之后要做什么

改动的位置不同，需要的重启范围也不同，搞错了就会看到「代码改了行为没变」：

- **改 App** —— 重新运行即可。
- **改 daemon** —— 重新编译后运行 App，它会检测到版本不一致并自动注销重装。前提是**递增了 `InjectionServiceIdentity.daemonVersion`**；不递增这套机制不会触发，内存里还是旧 daemon。
- **改 payload** —— payload 是加载进目标进程的镜像，卸不掉。必须让目标进程重启（`killall <目标>`）才能换成新版本。App 的窗口会把 Dock 里的旧 payload 标成「older build」（按镜像 UUID 比对，不用手动递增版本号），窗口与菜单栏里的「Restart Dock」重启后会自动再注入。
- **改文本输入辅助进程** —— 它由 launchd 按需拉起后一直常驻。部署换掉它的可执行文件后，它在下一次打开 Launchpad 时自行退出（那一次没有输入法），再下一次 launchd 起的就是新版本；想立刻换就 `pkill -f LaunchpadAwakenerTextInput`，或在控制面板「Input method helper」一行按「Restart」。App 启动时发现它的可执行文件在进程启动后被换过（重新构建、覆盖安装），会自动结束它。payload 与辅助进程之间的消息在 `LaunchpadAwakenerShared/TextInputMessages.swift` 与 `DeletionConfirmationMessages.swift`，两边同批部署；改了消息格式时，可执行文件已被换掉的旧辅助进程收到解不开的消息也会自行退出。
- **改共用模块（`LaunchpadAwakenerSpringboardCore`）** —— 两版都受影响：注入版照「改 payload」重启 Dock，独立版照下一条重新打开。
- **改独立版** —— 它收起后常驻，部署前先让它退出（`tell application "Launchpad" to quit`），换掉后再打开才是新版本。

## 加 hook

全部声明在 `LaunchpadAwakenerPackage/Sources/LaunchpadAwakenerPayloadCore/Integration/PayloadHooks.swift`：每个类一个 `@RuntimeClassHook("类名")` 结构体，替换方法标 `@RuntimeMethodReplacement`，在方法里用 `host` 拿接收者、`callOriginal(…)` 转给 Dock 自己的实现，再把结构体的 `descriptors()` 加进 `PayloadHooks.descriptors()`。

**类型编码必须从活着的宿主进程里读，不能照着反编译结果猜。** 用
`RuntimeMethodInspector.typeEncoding(forClassNamed:selector:isInstanceMethod:)` 读出来，把替换方法的 Swift 参数与返回类型写成能推出它的类型（`I` 是 `UInt32`，`f` 是 `Float`，`B` 是 `Bool`），并把编码记进 `DockSignatureTests`。宏从这一个声明推出选择子、编码与 block，安装时再与宿主的实际编码比对：类型写错就整批不装，而不是在调用时破坏寄存器、让宿主进程崩溃 —— 崩的是别人的进程，用户不会想到是这个工具。返回对象的 alloc、copy、mutableCopy、new、init 族方法不能这样替换，宏会在编译期报错。

安装是原子的：任何一个描述符校验失败，整批都不装，payload 保持加载但什么也不做，并留一条日志。**不要为了让 hook 装上而放宽校验** —— 装了一半的宿主进程混合运行着 hook 过和没 hook 过的行为，那是谁都没设计过的状态。

Launchpad 离了也能用的功能（比如显示期间把 Dock 留在原屏），hook 放进 `PayloadHooks.optionalDescriptors()`：主批装好之后另成一批原子安装，对不上只失去那项功能、留一条日志，「没有它」是事先想好的状态。打开 Launchpad 与接管事件的 hook 只能放主批。

## 两条注入路径

默认 `dlopen`。目标的沙箱配置禁止 `file-map-executable` 时（部分 Apple 守护进程如此）改用
`.memoryRemap`，在构造 `PayloadInjectionCoordinator` 时指定。

remap 路径不会跑 payload 的构造函数，所以 `main.m` 里有第二个入口
`LaunchpadAwakener_payload_remap_entry`。改动 `main.m` 时两个入口都要保持能调到同一个 Swift 初始化函数，且入口符号名要与 `InjectionServiceIdentity.payloadRemapEntrySymbol` 一致。

## 服务名有两处定义，必须一致

- 构建设置 `INJECTION_SERVICE_NAME` —— 决定 daemon 的 bundle id 和 launchd plist（文件名、`Label`、Mach 服务）
- `InjectionServiceIdentity.machServiceName` —— 决定 Swift 侧连哪个服务

daemon 的可执行文件在两种配置下都叫 `LaunchpadAwakenerDaemon`，**不要再让它跟着服务名变**：Xcode 不按配置分别求值文件引用的路径，「Embed Daemon」在 Release 构建里也去找 Debug 的文件名，构建直接失败。这个名字同样有两处：daemon target 的名字（产品名取 `$(TARGET_NAME)`，plist 的 `BundleProgram` 也写着它），与 `InjectionServiceIdentity.daemonExecutableName`——payload 靠后者认出自己被 remap 注入路径加载进了 daemon，对不上时会在 daemon 里启动。改了可执行文件的路径要递增 `daemonVersion`，已装的旧 daemon 才会被重装。

文本输入辅助进程同理：构建设置 `TEXT_INPUT_SERVICE_NAME`（决定它的 bundle id、LaunchAgent plist 与 Mach 服务）要与 `TextInputServiceIdentity.machServiceName` 一致。

独立版的 bundle ID 也是两处：独立版 target 的 `PRODUCT_BUNDLE_IDENTIFIER`，与注入版认它用的 `StandaloneLaunchpadInstaller.bundleIdentifier`。对不上时，控制面板认不出装好的独立版。

Debug 和 Release 用不同的服务名，这样开发中的构建和已安装的正式版不会互相抢 Mach 服务注册。

## 运行前提

- 注入其他进程通常需要关闭系统完整性保护（SIP）。目标启用了库校验时，无论用哪种注入方式都必须关。
- App 启动时读一次 SIP 的实际配置（`SystemIntegrityProtectionConfiguration`）。只有 `csrutil disable` 那样整个关掉才走注入；没关（含只关了一部分）时不装 daemon、不注入，控制面板改为引导用户一键安装并打开独立版。两台测试机的 SIP 都关着，开发构建带启动参数 `--assume-system-integrity-protection-enabled` 走「没关」那条路：`open /Applications/LaunchpadAwakener.app --args --assume-system-integrity-protection-enabled`。那里的「Install Launchpad」会打开独立版、盖住整块屏幕，只在测试机上按。
- daemon 需要用户在「系统设置 › 通用 › 登录项」批准一次，这一步无法跳过。App 的状态文字会说明当前卡在哪一步。
