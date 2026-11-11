# Draft - 在运行时找出 Dock 的两个全局变量，取消构建白名单

- **状态**: Accepted
- **作者**: JH
- **创建日期**: 2026-11-11
- **最后更新**: 2026-11-11
- **所属愿景**: 无
- **关联提案**: [在 macOS 27 的 Dock 中复刻 macOS 15 的 Launchpad](draft-launchpad-replica.md)
- **实现分支 / PR**: `feature/runtime-dock-global-discovery`
- **配套文档**: 待定 —— 落地时登记实现说明的链接

## 摘要

Launchpad 复刻要用 Dock 里两个没有任何导出入口的全局变量（持有 `DockBar` 与 `DockGlobals`）。现在它们的地址是人工从 IDA 里读出来、按 Dock 构建一条条写进 `DockBuildProfile.knownProfiles` 的，表里不存在的构建一个 hook 都不装。本提案把这两个地址改成运行时自己找：扫一遍 Dock 可执行文件的可写数据段，把每个指针槽当候选试一次，持有的对象正好是目标类的实例就是它。随之删掉整个构建档案与白名单闸门，macOS 26 与 27 的任何 Dock 构建都能直接工作，真正的闸门仍然是 hook 安装前那套方法签名的整批核对。

## 动机

**维护成本按构建线性增长，而且是人工的。** `DockBuildProfile.knownProfiles` 现在有 17 条，覆盖 26.0 到 27.2。每补一条要走实现说明「适配新的 Dock 构建」的 8 步，其中第 2 到 4 步要下载约 17 GB 的完整更新包、取出 Dock、建 IDA 数据库，第 6 步要在反汇编里顺着 `-[DockBarSystemDefinedEventHandler handleSystemDefinedEvent:type:]` 找出两个 `ADRL` 加 `LDR` 取的地址。这几步与功能无关，纯粹是为了把两个数字抄进代码。

**漏一条就整个不生效，而且已经发生过。** macOS 26.7 发布时档案里没有那个构建，注入版完全不工作（见[不注入 Dock 的独立版 Launchpad](0002-standalone-launchpad.md)的决策日志，2026-11-08）。用户升级系统的那一刻功能就消失，要等人把新构建逆向完才回来。

**白名单以 UUID 为键，而一个 Dock.app 有两个 UUID。** macOS 27 的 Dock 可执行文件有 `arm64e` 与 `arm64e.x1` 两个切片，UUID 分别是 `C53975B1-2956-3ED4-B699-D4CE2E6A602C` 与 `8B5CAE64-5F54-3910-AF74-E7B9986600F4`（`dyld_info -uuid`），档案只登记前者。本机（27.2，26B123）实测加载的是 `arm64e` 切片，所以这个缺口目前没有触发；哪种机器会加载 `arm64e.x1` 未经实测，这一条是推测性的风险。按类扫描不比对 UUID，天然没有这个缺口。

**白名单其实没在守住什么。** `PayloadHooks.descriptors()` 里，profile 是否存在这道 `guard` 之后紧跟着 `DockHostInterface.isCompatible`——后者逐个核对复刻要调的全部 Dock 方法的类型编码，不符就整批不装。那才是拦住「Dock 变了」的闸门。profile 检查只在 hook 全空时被 `PayloadEntry.installHooks()` 用来区分失败原因（`PayloadCore/PayloadEntry.swift:81`）。换句话说，取消白名单不会松掉签名那道闸门，只会去掉一道以地址为内容、而地址本来就能自我验证的闸门。

## 前期调研

### 两个全局都在 `__DATA,__common`，而这一段极小

`otool -arch arm64e -l` 读两个构建的段表，与档案里记的地址对照：

| 构建 | `__common` 起点 | 长度 | `DockBar` 全局 | `DockGlobals` 全局 |
|---|---|---|---|---|
| 27.2 (26B123) | `0x100329B60` | `0x6D0`（1744 字节，218 槽） | `0x100329BA8`（+`0x48`） | `0x100329C20`（+`0xC0`） |
| 26.6.2 (25G83) | `0x100487F98` | `0x668`（1640 字节，205 槽） | `0x100487FE0`（+`0x48`） | `0x1004880A8`（+`0x110`） |

两个构建的两个全局都落在 `__common` 里。这一段放的是 C 里不带初值的文件作用域变量，正是 Dock 存放单例的写法。两百来个槽位意味着一趟扫描只有几十微秒。兜底要扫的另两段也不大：27.2 的 `__bss` 是 `0x133F0`、`__data` 是 `0xAE50`，三段合计约 15.5 k 个槽位。

### 运行时这几段确实映射成可读写

对运行中的 Dock（27.2，M1 Max）跑 `vmmap`：`__DATA` 占两段，`100edc000-100f14000` 与 `100f14000-100f28000`，都是 `rw-`，合计 `0x4C000`，与 `arm64e` 切片 `__DATA` 的 `vmsize 0x4c000` 一致。按 `__TEXT` 映射在 `0x100be8000` 算出 slide 为 `0xBE8000`，`__common` 的运行时地址 `0x100F11B60` 落在第一段里。同一次比对也确认了本机加载的是 `arm64e` 切片而非 `arm64e.x1`（后者 `__TEXT` 的 `vmsize` 是 `0x2BC000`，而 `vmmap` 显示的是 `0x2CC000`）。

### 三条更省事的路都走不通

- **按符号名找。** Dock 被 strip 过：`nm -arch arm64e` 列出的 3116 个符号里只有 2 个数据符号，`__common` 的符号名不在二进制里。
- **走导出的单例访问器。** `DockBar` 只有一个类方法 `+defaultBackdropGroupName`，没有任何单例入口（`swift-section objc interface DockBar`）。`DockGlobals` 在 27 上是 Swift 类 `DockCore.DockGlobals`，52 个存储属性里没有 `static shared`（`swift-section dump`）。
- **从别的可达对象沿属性链爬过去。** `DockAppEventHandler` 与它下属的五个事件处理器（`DockBarMouseEventHandler`、`DockBarGestureEventHandler`、`DockBarKeyboardEventHandler`、`DockBarScrollWheelEventHandler`、`DockBarNotificationEventHandler`）都不持有 `DockBar`——它们自己也是读全局的。整个 ObjC 导出面里只有 `Tile` 有 `@property (nonatomic, weak, readonly) DockBar *dock`，但要先拿到一个 `Tile`，而 `Tile` 只在特定交互状态下才从别处可达（`DockBarMouseEventHandler` 的 `_mouseDownTile` 只在按下时非空）。这正是 Dock 的架构：单例放全局，各处直接读，不做依赖注入。

### 反汇编锚点函数分不出哪个全局是哪个

在 27.2 的数据库（`/private/tmp/reverse-explorer/dock272/Dock.i64`，UUID 与本机 Dock 一致）里反汇编 `-[DockBarSystemDefinedEventHandler handleSystemDefinedEvent:type:]`（IMP `0x100085784`，地址取自 `swift-section objc interface` 的注释），前 90 条指令里就读了四个不同的全局：`0x100329BA8`、`0x100329BE0`、`0x100329BF0`、`0x100329C38`。要区分它们只能再认出紧随其后的 `objc_msgSend$<selector>` stub（`keyFocusController` 指向 `DockBar`，`isWindowsMode` 指向另一个对象），也就是还要从 stub 反推 selector 引用再到字符串。这条路要写 ARM64 指令解码加 stub 解析，复杂度比按类扫描高一个量级，且对 Dock 代码结构的变化更敏感。

### 探测一个候选指针是安全的

- `malloc_size` 对任意野指针安全：它只调 `_find_registered_zone`，后者逐个 zone 调 `zone->size(zone, ptr)`，各 zone 的实现只做地址范围比较，不属于自己就返回 0，从不解引用（`/Volumes/AppleOSS/distribution-macOS/libmalloc/src/malloc.c:3016` 与 `:1152`，工作树为 macOS 26.0）。返回非 0 还顺带证明了这个指针是某个 malloc 块的起始，而不是块内部的某处。
- `object_getClass` 只读对象头的 8 字节并按 isa 的格式掩码，拿到的类指针不被解引用；而那 8 字节已被上一步证明落在堆块里。整条路径只做指针比较，不向候选对象发任何消息。
- 槽位里的指针没有指针认证签名：反汇编里取它用的是裸 `LDR X0, [X22]`，前后没有任何 `AUT*` 指令。

### 扫不到 `DockBar` 并不致命

五个用到它的地方全都已经处理了拿不到的情况，各自降级：

| 位置 | 拿不到时 |
|---|---|
| `Host/DockBarVisibility.swift:151` | Dock 保持原样，不滑走 |
| `Host/DockGlassMaterial.swift:120` | 返回 `false`，玻璃背景不画 |
| `Host/DockEnvironment.swift:58` | 用 `SpringboardMetrics.defaultDockThickness` |
| `Host/DockEnvironment.swift:73` | 刘海高度按 0 算 |
| `Host/DockSpringboardHost.swift:80` | 「这一点在 Dock 上」一律判否 |

所以 Launchpad 照样能开，只少几个贴合 Dock 的细节。这决定了扫描不该当成装 hook 的闸门。

### 注入发生在 Dock 启动后极短的时间里

「Restart Dock」之后每 250 毫秒轮询一次新的 Dock 进程，一发现就注入（`AppCore/PayloadInjectionCoordinator.swift:625`）；自动发现路径每 2 秒扫一次进程表（`AppCore/TargetProcessMonitor.swift:69`）。而 `installHooks()` 是在 payload 的构造函数里同步跑的。所以若把扫描放进装 hook 的 `guard`，Dock 刚启动、`DockBar` 还没建好的正常情况会被判成失败。现在的实现不受影响，因为它在那一刻只比对 UUID，真正读全局要等到第一次用。

### 通道上不需要新增请求

`PayloadRequests.swift` 里只有一个请求 `PayloadStatusRequest`（`:10`），控制面板每次刷新本来就发它。payload 在组装回复时现场扫一次，状态就是实时的。`DockBuildProfileTests.supportedReleases` 那张「支持哪些系统版本」的清单只被它所在的测试文件自己用，没有外部依赖。

## 提议方案

1. **新增 `DockGlobalScanner`**（`PayloadCore/Host/`）：给定一个类和若干段内存，找出其中持有该类实例的指针槽。段范围由调用方传入，这样测试可以喂一块自己准备的内存，不必为了测一个纯计算过程去注入任何进程。扫描分两层：先扫 `__common`，没命中再扫 `__bss` 与 `__data`。
2. **`DockBarReference` 改用它**：`readGlobalObject(atUnslidAddress:expectedClassName:)` 换成按类名查找。`DockGlobals` 的两个类名（26 的 Objective-C 类 `DockGlobals`、27 的 Swift 类 `_TtC8DockCore11DockGlobals`）都试一次，哪个在这个系统上存在就用哪个——这替掉了原先按构建记在档案里的 `dockGlobalsClassName`。保持现在的延迟语义：`weak` 缓存，找不到不缓存、下次重试。
3. **删掉 `DockBuildProfile` 与 `DockBuildProfileTests`**，`MachOImageInspector`（读 `LC_UUID`）随之一起删——它只被档案用。`PayloadHooks.descriptors()` 的闸门只剩 `DockHostInterface.isCompatible`。
4. **通道类型调整**：`HookInstallation` 删掉 `unknownDockBuild` 这个状态；新增 `DockGlobalsReachability` 作为 `PayloadStatus` 上的独立字段——hook 装没装和全局找不找得到是两件互不决定的事，不该挤在一个枚举里。`DockBuildSummary` 的 `systemReleases: [String]`（人工维护的「随哪些 macOS 发布」）换成 `systemRelease: String`（当前系统的版本与 build），`bundleVersion` 改从 Dock 自己的 bundle 读。`dockBuild` 不再可空。
5. **控制面板**：「Dock build」那一行改为显示当前系统版本；hook 装上但全局找不到时，显示「在这个 Dock 里找不到 Launchpad 的入口」。
6. **文档**：实现说明「适配新的 Dock 构建」拆成两段——新构建什么都不用做；日志报签名不符时怎么取那个构建来核对。术语表删掉「DockBuildProfile（构建档案）」，换成新机制的条目。项目 `CLAUDE.md` 开头那句「别的构建在补上构建档案之前什么都不装」改写。

### 非目标

- **不把扫描器回写到 InjectionScaffold 脚手架。** 它对任何注入项目都通用，但先在本项目用稳。
- **不留手动写死地址的后门。** 扫不到时日志会写清扫了哪几段、各多少槽、找的是哪个类名，改代码重新部署即可。
- **不动方法签名那套闸门。** 它才是拦住「Dock 变了」的机制，本提案不碰。
- **不改已落地的提案。** 独立版那份与 ObjCRuntimeToolbox 那份里提到构建档案的地方保持原貌，它们是当时的决策快照。
- **不处理 `/Volumes/RE/Dock/` 在这台机器上不存在的问题。** 实现说明引用的界面规格 Notes 与各版本 IDA 库都指向它，应是在家里那台 Ultra 上；这与本提案无关，另行处理。

## 详细设计

### 扫描器

```swift
/// 一段能逐个指针槽读过去的内存。
///
/// 段范围由调用方传进来，而不是让扫描器自己去问 dyld：查找本身是个纯计算过程，
/// 测试应当能喂一块自己准备的内存，而不必为了测它去注入任何进程。
struct PointerSlotRegion: Sendable {
    /// 第一个槽的地址，按指针大小对齐。
    let baseAddress: UnsafeRawPointer
    /// 这一段有多少字节；凑不满一个槽的尾巴忽略。
    let byteCount: Int
    /// 写日志用的名字，例如 `__DATA,__common`。
    let name: String
}

@Loggable(subsystem: "com.MxIris.LaunchpadAwakener", category: "DockGlobalScanner")
enum DockGlobalScanner {
    /// 一个持有目标类实例的全局。
    struct FoundGlobal: Sendable {
        /// 这个全局本身的地址，只用于写日志。
        let slotAddress: UnsafeRawPointer
        /// 它持有的对象。
        let object: NSObject
    }

    /// 在 `regions` 里按先后顺序找持有 `targetClass` 实例的槽位；
    /// 某一段有命中就不再看后面的段。
    static func findGlobals(
        holdingInstanceOf targetClass: AnyClass,
        in regions: [PointerSlotRegion]
    ) -> [FoundGlobal]

    /// 宿主可执行文件里值得扫的几段，按先扫的在前排好：`__common`、`__bss`、`__data`。
    ///
    /// 三段都在 `__DATA` 里，dyld 把它们映射成可读写（27.2 上 `vmmap` 实测 `rw-`）。
    /// 段范围经 `getsectbynamefromheader_64` 问出来，加上 `_dyld_get_image_vmaddr_slide(0)`；
    /// 两者都是公开 API，所以这里没有一处写死的地址。
    static func mainExecutablePointerSlotRegions() -> [PointerSlotRegion]
}
```

一个候选要过三道筛子，每一道都不解引用还没证明过的内存：

1. 非空，且按指针大小对齐。
2. `malloc_size(候选) >= class_getInstanceSize(targetClass)`。`malloc_size` 对任意野指针安全（见前期调研），返回非 0 还证明了它是某个 malloc 块的起始；块比目标类的实例还小就不可能是它。
3. `object_getClass(候选) == targetClass`。只读堆块头部 8 字节并按 isa 的格式掩码，拿到的类指针直接比较，不向候选对象发任何消息。

命中不唯一不是问题：`DockBar` 与 `DockGlobals` 都是进程单例，多个槽位持有的必然是同一个对象。扫到的对象指向同一个就用它；真出现两个不同对象就一个也不用，并写日志——与项目里 hook 要么整批装要么一个不装的做法一致。

### 调用方

```swift
/// Dock 的 `DockBar` 与 `DockGlobals`，在宿主自己的数据段里按类认出来。
///
/// macOS 15 的 `-[DockAppEventHandler handleSpringboardEvent:type:]` 拿每次点击去比
/// `-[DockBar rect]`，好把落在 Dock 上的点击留给 Dock。27.2 上没有任何导出入口通向 `DockBar`，
/// 指针移过 Dock 时 `rect` 与 `setRollTile:` 都不被调用，观察这些方法永远等不到它——
/// 全局是唯一的入口，而这些全局在二进制里没有符号，只能按它持有的对象认。
@Loggable(subsystem: "com.MxIris.LaunchpadAwakener", category: "DockBarReference")
@MainActor
enum DockBarReference {
    private static weak var cachedDockBar: NSObject?
    private static weak var cachedDockGlobals: NSObject?

    /// Dock 的 `DockBar`；找不到时为 nil。
    static var dockBar: NSObject? { get }

    /// Dock 的 `DockGlobals`；找不到、或它还没被建起来时为 nil。
    ///
    /// macOS 26 的 `DockGlobals` 是 Objective-C 类，27 把它改写成了 Swift，
    /// 运行时名字是 mangled 的。两个名字都查一次，哪个类在这个系统上存在就用哪个。
    static var dockGlobals: NSObject? { get }

    /// 这一刻两个全局的可达性，用于回答 App 的状态请求。
    static var reachability: DockGlobalsReachability { get }
}
```

两个属性都保持 `weak` 缓存加「找不到不缓存」：扫描只有几十微秒，而延迟到第一次真用时才扫，正好避开注入发生在 Dock 启动后 250 毫秒内这件事。

### 通道

```swift
/// payload 启动时对它那批 hook 做了什么。
///
/// 除 ``installed(hookCount:)`` 以外的每种情况都让 Dock 保持原样：各个入口继续打开系统的 Apps。
public enum HookInstallation: Codable, Sendable, Equatable {
    case installed(hookCount: Int)
    /// 这个 Dock 里，payload 要调的方法与它记录的签名不符。
    case incompatibleDockMethods
    /// 有一个 hook 没通过校验，所以一个也没装。
    case failed(description: String)
}

/// 这一刻 payload 能不能在宿主里找到复刻要用的那几个全局。
///
/// 与 ``HookInstallation`` 分开，因为两者互不决定：hook 换的是 Launchpad 键的去向，
/// 全局给的是贴合 Dock 所需的几何与材质。缺了后者，复刻照样能开，只是 Dock 不滑走、
/// 玻璃背景不画、厚度取默认值。
public enum DockGlobalsReachability: Codable, Sendable, Equatable {
    case reachable
    /// 没找到的那些，按查找时用的类名写。
    case unreachable(missingClassNames: [String])
}

/// 这个 Dock 自己报出来的身份。
public struct DockBuildSummary: Codable, Sendable, Equatable {
    /// Dock.app 的 `CFBundleVersion`，从宿主自己的 bundle 读。
    public let bundleVersion: String
    /// 这个 Dock 正跑在哪个 macOS 上，形如 `27.2 (26B123)`。
    public let systemRelease: String
}
```

`PayloadStatus` 加一个 `dockGlobalsReachability` 字段，`dockBuild` 由可空改为必有。两边的 `Codable` 契约同时变，所以 payload 与 App 必须同批部署；App 本来就会按镜像 UUID 认出 Dock 里的旧 payload 并提示重启 Dock。

## 替代方案考量

- **反汇编锚点函数，解 `ADRP`/`ADD`/`LDR` 算出地址。** 否：那个函数前 90 条指令里就读了四个不同的全局，要区分它们还得认出紧随的 `objc_msgSend$<selector>` stub 并反推 selector。要写 ARM64 指令解码加 stub 解析，复杂度高一个量级，而且比按类扫描更依赖 Dock 的代码结构不变。
- **按符号名在符号表里找。** 否：Dock 被 strip 过，3116 个符号里只有 2 个数据符号。
- **从导出的单例访问器或属性链爬到 `DockBar`。** 否：两个类都没有单例入口，五个事件处理器都不持有它，唯一有 `dock` 属性的 `Tile` 自己就难以随时拿到。Dock 的架构就是单例放全局、各处直接读。
- **hook `DockBar` 自己一个会被周期性调用的方法，在回调里记下 `self`。** 否：拿不到对象，直到那个方法被调用过一次；而注入之后到用户按键之前未必有这样一次调用。项目已经试过 `rect` 与 `setRollTile:`，指针移过 Dock 时它们都不被调用。
- **保留白名单，但条目只剩 UUID 与版本号。** 否：加一条新构建的成本确实能降到读一次 UUID（可脚本化），但功能仍要等人补表才回来，而且以 UUID 为键的那个 `arm64e.x1` 缺口还在。
- **把扫描当成装 hook 的闸门。** 否：注入发生在 Dock 启动后 250 毫秒内，那时 `DockBar` 可能还没建好，正常启动会被判成失败。改为第一次真用时才扫，用户按键时 Dock 早已跑起来。
- **装 hook 时扫一次只为诊断。** 否：正常时序下这一次本就可能扫不到，控制面板会闪一下不实的失败态。改由控制面板刷新时现场问，状态永远是实时的。

## 影响

### 用户可见变化

- **macOS 26 与 27 的任何 Dock 构建都能用了。** 原先只有登记在档案里的 17 个构建生效；升级系统后功能消失、要等人补表的情况不再发生。
- **控制面板「Dock build」那一行的文字变了。** 原先显示「macOS 26.6.2 (25G83) · supported」这类从档案里取的发布列表，改为显示当前系统的版本与 build；原先的「Unknown build — not supported」不再出现，取而代之的新状态是「在这个 Dock 里找不到 Launchpad 的入口」。
- 已有的操作习惯没有失效：没有菜单项、快捷键或设置项被移除。

### 可发现性

没有新功能要被发现。这是一处维护性改动：用户感知到的只是「换了系统照样能用」，以及控制面板那一行文字更贴合实际。

### 数据与配置兼容

- 不读写任何持久化数据，不涉及偏好设置、缓存或钥匙串条目的迁移。
- payload 与 App 之间的 `Codable` 契约变了（删掉一个 hook 状态、加一个可达性字段、换掉 `DockBuildSummary` 的字段）。两者同批部署即可；Dock 里残留的旧 payload 会被 App 按镜像 UUID 认出来并提示重启 Dock，这套机制本来就有。

### 平台与最低版本

最低系统版本不变。扫描用的 `getsectbynamefromheader_64`、`_dyld_get_image_vmaddr_slide`、`malloc_size`、`class_getInstanceSize`、`object_getClass` 都是长期存在的公开 API。macOS 26 与 27 的差别只剩 `DockGlobals` 的类名，而新实现对两个名字各试一次，不再按构建区分。

### 发布

不需要新的权限、entitlement 或隐私清单条目，也不影响公证与自动更新。注入仍然要求整个关闭系统完整性保护，这一条不变。

## 落地步骤

1. 加 `PointerSlotRegion` 与 `DockGlobalScanner`，连同它的单元测试：测试自己 malloc 一块内存当作「段」，在某个槽里放一个真实对象的指针，验证能找到它、验证类不匹配时不误报、验证块小于实例大小时被筛掉。这一步不碰 Dock，可独立验证。
2. `DockBarReference` 改用扫描器；删掉 `DockBuildProfile`、`MachOImageInspector` 与 `DockBuildProfileTests`；`PayloadHooks.descriptors()` 的闸门只留签名核对。
3. 通道类型调整，App 一侧同步：`HookInstallation` 去掉一个状态，`PayloadStatus` 加可达性字段，`DockBuildSummary` 换字段并改为从宿主自己读。
4. 控制面板与就绪提示的文案。
5. 部署到两台测试机验证：27 用测试 MacBook，26 用 Ultra 上的虚拟机。看日志里找到两个全局的那两行、`Installed 2 hook(s)`，再看 Launchpad 开起来之后 Dock 会滑走、玻璃背景在画。
6. 文档同批落地：实现说明拆两段、术语表换条目、项目 `CLAUDE.md` 开头那句、未落地的复刻草案里提到构建档案的那一行、文档索引。

**收尾时必须判断两件事**（判断结果写进决策日志，不允许沉默跳过）：

- **要不要配套专题文章** —— 扫描为什么安全（`malloc_size` 对野指针安全、`object_getClass` 不解引用结果、槽里的指针没有签名）从代码本身看不出来，倾向写进实现说明「适配新的 Dock 构建」那一节。
- **有没有引入新术语** —— 术语表要删掉「DockBuildProfile（构建档案）」，并为新机制加一个条目。

## 决策日志

| 日期 | 变更 | 说明 |
|------|------|------|
| 2026-11-11 | Created as Draft | 起因是构建档案的维护成本：每个新的 Dock 构建都要人工下固件包、建 IDA 库、从反汇编里读出两个全局变量的地址，漏一条整个功能就不生效（26.7 上已发生过）。调研确认两个全局在 26 与 27 上都落在极小的 `__DATA,__common` 段里，可以按「持有的对象是不是目标类的实例」在运行时认出来。 |
| 2026-11-11 | 取消白名单闸门 | 用户决定不再限定已验证的构建。真正拦住「Dock 变了」的是 hook 安装前那套方法签名的整批核对，地址白名单只保护地址一件事，而地址现在能自我验证。收益是系统升级当天功能就在。 |
| 2026-11-11 | 删掉 `DockBuildProfile` 整个类型 | 白名单与地址都去掉后，它只剩「告诉 App 这是哪个 Dock」一个职责，而那两样（Dock 的 `CFBundleVersion`、当前系统版本）都是运行时能直接读的事实。术语表条目一并删除。 |
| 2026-11-11 | 控制面板显示当前系统版本，不再显示发布列表 | 「这个 Dock 随哪些 macOS 发布」是人工维护的知识，Dock 自己不知道；用户想知道的本来就是自己这台跑的是哪个版本。 |
| 2026-11-11 | 扫描放在第一次真要用时，不作为装 hook 的闸门 | 注入发生在 Dock 启动后 250 毫秒内，那一刻 `DockBar` 可能还没建好，当闸门会把正常启动误判成失败。五个用到它的地方本来就都处理了拿不到的情况并各自降级，所以延迟到真用时才扫是安全的。 |
| 2026-11-11 | 可达性由控制面板刷新时现场问 | 通道上已有的状态请求本来就在面板刷新时发出，payload 组装回复时现场扫一次即可，不必新增请求、也不必加补报路径。状态因此永远是实时的。 |
| 2026-11-11 | 扫描器只放本项目，不回写脚手架 | 这个技术对任何注入项目都通用，但先在本项目用稳，避免本次改动跨两个仓库。 |
| 2026-11-11 | 不留手动写死地址的后门 | 扫不到时日志会写清扫过哪几段、各多少槽位、找的是哪个类名；这是开发者自用的工具，改代码重新部署的成本低于多维护一条配置路径。 |
| 2026-11-11 | 用户批准，开始实现 | 状态改为 Accepted，实现落在 `feature/runtime-dock-global-discovery`。 |
