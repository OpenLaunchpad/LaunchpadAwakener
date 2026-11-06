# LaunchpadAwakener

在 macOS 27 的 Dock 里复刻 macOS 15 的 Launchpad：一个注入 Dock 的 payload，加上负责注入的 App 与特权 daemon。工程由 [InjectionScaffold](https://github.com/Mx-Iris/InjectionScaffold) 生成，方案见提案 [在 macOS 27 的 Dock 中复刻 macOS 15 的 Launchpad](Documentations/Evolutions/draft-launchpad-replica.md)。

## 只在测试用的 MacBook 上运行

**开发机（两台 Mac Studio）上只编译、跑单元测试，绝不运行 App、注入 Dock 或重启 Dock。** 全屏窗口一旦失控，整台机器的输入都会被锁住，只能重启——这在 macOS 26 上真实发生过。运行与验证只在测试用的 MacBook 上做：`ssh JH@192.168.50.13`，macOS 27.2（26B123），SIP 已关，App 装在 `/Applications/LaunchpadAwakener.app`。

在开发机上编译后部署（`<agent>` 是 `claude` 或 `codex`，各用各的构建目录）：

```bash
queued-build ./RunScript.sh --no-launch --derived-data /Volumes/DerivedData/Agents.noindex/<agent>/DerivedData/LaunchpadAwakener
ssh JH@192.168.50.13 'osascript -e "tell application \"LaunchpadAwakener\" to quit"'
rsync -a --delete /Volumes/DerivedData/Agents.noindex/<agent>/DerivedData/LaunchpadAwakener/Build/Products/Debug/LaunchpadAwakener.app/ JH@192.168.50.13:/Applications/LaunchpadAwakener.app/
ssh JH@192.168.50.13 'killall Dock; sleep 2; open /Applications/LaunchpadAwakener.app'
```

日志的 subsystem 是 `com.MxIris.LaunchpadAwakener`，info 级要加 `--info`：`/usr/bin/log show --info --last 5m --predicate 'subsystem == "com.MxIris.LaunchpadAwakener"'`。经 ssh 跑时**必须写全路径**：MacBook 的登录 shell 是 zsh，zsh 有个同名的内建命令 `log`，裸写 `log show …` 只会报 `too many arguments`，配上 `2>/dev/null` 就成了「一条日志也没有」。

出了问题，先经 ssh 退回系统的 Apps 并换掉注入过的 Dock：`touch /tmp/LaunchpadAwakener.disabled; killall Dock`。

**用户要求看界面时**（截图、点击属于交互操作，用户没提就不做）：经 ssh 跑 `open -a Apps` 打开、`screencapture -x` 截图（能截到窗口内容）、`screencapture -v -V <秒>` 录屏后拷回本机用 ffmpeg 抽帧（录屏启动要零点几秒到一两秒，先开录、等一秒再操作）；点击与拖动用在 MacBook 上编译的一个发 `CGEvent` 的小工具，经 ssh 发的事件实测有效。开发构建 20 秒没有输入就自动收起，打开与操作要放在同一条命令里。拖动会改用户的布局，测完要还原。

## 结构

四个二进制，Xcode 项目里只放外壳，代码都在本地 Swift 包：

| 目录 | 是什么 |
|---|---|
| `LaunchpadAwakener/` | SwiftUI App 外壳 |
| `LaunchpadAwakenerDaemon/` | 特权 daemon 的 `main.swift`，两行 |
| `LaunchpadAwakenerPayload/` | payload 的 `main.m`，提供两条注入入口 |
| `LaunchpadAwakenerPackage/Sources/LaunchpadAwakenerShared` | 服务名、版本、路径。**不依赖任何东西** |
| `LaunchpadAwakenerPackage/Sources/LaunchpadAwakenerHookKit` | 带签名校验的 Objective-C 方法替换 |
| `LaunchpadAwakenerPackage/Sources/LaunchpadAwakenerAppCore` | daemon 生命周期、进程监视、注入编排 |
| `LaunchpadAwakenerPackage/Sources/LaunchpadAwakenerDaemonCore` | 组装特权 XPC 服务端 |
| `LaunchpadAwakenerPackage/Sources/LaunchpadAwakenerPayloadCore` | 跑在目标进程里的代码，hook 声明在这里 |

模块按「谁链接它」划分。App 不能链接 daemon 的特权依赖，payload 要尽量小 —— 它会被映射进一个并没有请求它的进程。

`LaunchpadAwakenerPayloadCore` 再按层分目录：

| 目录 | 放什么 |
|---|---|
| `Host/` | 调用 Dock 内部方法与私有接口的地方：构建档案、签名校验、`WALayerKitWindow`、SkyLight |
| `Data/` | 布局库、旧库导入、App 的发现 |
| `Interface/` | 界面层，按 15.5 的 `ECSB*` / `ECPager*` 划分 |
| `Integration/` | hook 声明，以及入口与事件的接管 |

调 Dock 内部方法一律经过 `Host/`：先按类型编码校验，再调用。

## 构建

**用 `./RunScript.sh`，不要自己拼 xcodebuild 命令。**

```bash
./RunScript.sh              # 构建并启动
./RunScript.sh --no-launch  # 只构建
./RunScript.sh --dry-run    # 只打印命令
```

daemon 必须带 arm64e 切片才能注入 Dock 这类 arm64e 系统进程 —— 签目标线程 PC 的那条 PAC 指令在 arm64 构建里是空操作。这需要五处配置同时成立，外加一个 `-destination 'generic/platform=macOS'`。

**在 Xcode GUI 里构建要把运行目标切成「Any Mac」**：My Mac 对应 `platform=macOS`（为本机构建），会静默丢掉 arm64e 切片，daemon 随即链接失败；Any Mac 对应 `generic/platform=macOS`，能正常构建。这就是「Xcode 编不过」的全部原因。

细节全部记在脚手架的
[BuildingForArm64eTargets.md](https://github.com/Mx-Iris/InjectionScaffold) 里。**动架构相关设置之前先读它** —— 每一处"显而易见"的改法都试过，也都记了失败原因。特别是：`ENABLE_POINTER_AUTHENTICATION` 绝不能提到项目级，否则本地包的 arm64e 切片会替换掉 arm64，macro plugin 随即链接失败。

脚本构建完会自动校验切片：

```
[RunScript] Verifying architectures:
[RunScript]   daemon : x86_64 arm64 arm64e
[RunScript]   payload: x86_64 arm64 arm64e
```

**不要因为构建"通过了"就认为没问题** —— 一个悄悄产出 arm64-only daemon 的构建看起来和正确构建一模一样，直到注入时才暴露。

## 改完代码之后要做什么

改动的位置不同，需要的重启范围也不同，搞错了就会看到「代码改了行为没变」：

- **改 App** —— 重新运行即可。
- **改 daemon** —— 重新编译后运行 App，它会检测到版本不一致并自动注销重装。前提是**递增了 `InjectionServiceIdentity.daemonVersion`**；不递增这套机制不会触发，内存里还是旧 daemon。
- **改 payload** —— payload 是加载进目标进程的镜像，卸不掉。必须让目标进程重启（`killall <目标>`）才能换成新版本。

## 加 hook

全部声明在 `LaunchpadAwakenerPackage/Sources/LaunchpadAwakenerPayloadCore/Integration/PayloadHooks.swift` 的 `descriptors()` 里。

**类型编码必须从活着的宿主进程里读，不能照着反编译结果手写。** 用
`MethodHookInspector.typeEncoding(forClassNamed:selector:isInstanceMethod:)` 读出来再填进描述符。一个长度恰好对得上但内容错误的编码能通过安装校验，然后在调用时破坏寄存器、让宿主进程崩溃 —— 崩的是别人的进程，用户不会想到是这个工具。

安装是原子的：任何一个描述符校验失败，整批都不装，payload 保持加载但什么也不做，并留一条日志。**不要为了让 hook 装上而放宽校验** —— 装了一半的宿主进程混合运行着 hook 过和没 hook 过的行为，那是谁都没设计过的状态。

## 两条注入路径

默认 `dlopen`。目标的沙箱配置禁止 `file-map-executable` 时（部分 Apple 守护进程如此）改用
`.memoryRemap`，在构造 `PayloadInjectionCoordinator` 时指定。

remap 路径不会跑 payload 的构造函数，所以 `main.m` 里有第二个入口
`LaunchpadAwakener_payload_remap_entry`。改动 `main.m` 时两个入口都要保持能调到同一个 Swift 初始化函数，且入口符号名要与 `InjectionServiceIdentity.payloadRemapEntrySymbol` 一致。

## 服务名有两处定义，必须一致

- 构建设置 `INJECTION_SERVICE_NAME` —— 决定 daemon 产物名和 launchd plist
- `InjectionServiceIdentity.machServiceName` —— 决定 Swift 侧连哪个服务

Debug 和 Release 用不同的服务名，这样开发中的构建和已安装的正式版不会互相抢 Mach 服务注册。

## 运行前提

- 注入其他进程通常需要关闭系统完整性保护（SIP）。目标启用了库校验时，无论用哪种注入方式都必须关。
- daemon 需要用户在「系统设置 › 通用 › 登录项」批准一次，这一步无法跳过。App 的状态文字会说明当前卡在哪一步。
