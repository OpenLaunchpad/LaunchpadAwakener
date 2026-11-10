# 0006 - 用 ObjCRuntimeToolbox 改写 hook 与私有调用

- **状态**: Implemented
- **创建日期**: 2026-11-09
- **最后更新**: 2026-11-10
- **实现分支**: LaunchpadAwakener `feature/objc-runtime-toolbox`；FrameworkToolbox `feature/objc-runtime-method-families`（0.17.2）、`feature/runtime-proxy-coverage`（0.18.0）
- **配套文档**: 同步更新了 [Launchpad 复刻的实现说明](../Internal/LaunchpadReplica.md) 里校验签名的一段，以及项目 `CLAUDE.md` 的结构表、私有方法的写法与「加 hook」一节

## 摘要

payload、独立版与文本输入辅助进程里调用 Objective-C 私有方法、替换方法实现的代码，原先每处都手写三样东西：选择子、类型编码、`@convention(c)` 函数类型，三者之间没有任何东西互相核对。改用 FrameworkToolbox 的 ObjCRuntimeToolbox：hook 用 `@RuntimeClassHook`，Dock 里类名固定的类用 `@RuntimeClassProxy`（实例方法、构造、类方法、block 参数都在内），经环境对象拿到、类名随版本变的对象用 `@RuntimeObjectProxy`，全部从一处 Swift 声明推出选择子与编码，参数类型由编译器检查，代码里不再有手写的类型编码，也不再用 `DynamicObject`。系统框架导出的私有类改为按头文件声明直接调用。工具箱缺的几样（`DynamicObject` 处理 init 的引用计数、proxy 的构造与类方法、block 参数、按对象核对的 proxy）先在 FrameworkToolbox 里补上，分别发 0.17.2 与 0.18.0。项目自己的 `LaunchpadAwakenerHookKit` 是工具箱 `RuntimeMethodHook` 的前身，随之删除。

## 方案

### 先修 FrameworkToolbox，再发 0.17.2

`DynamicObject` 按选择子判断返回值归谁时有两处错，都会让对象多 release 一次：

- 不认 init 族。init 会消耗接收者、返回 +1，`DynamicObject` 两样都没处理：init 返回 `self` 时计数恰好抵消，返回 `nil` 或换了一个对象时，被 init 释放过的接收者会再被释放一次。
- 只看前缀。`newsItem`、`copyright` 这类 +0 返回的方法被当成 new 族、copy 族，返回值多释放一次。按 ARC 的规则，前缀之后必须不是小写字母（proxy 宏已经这样判断）。

修法：按 ARC 规则判断 alloc、new、copy、mutableCopy、init 五个方法族；调用 init 族前给接收者多保留一次交给 init 消耗，返回值按 +1 接管。每种情况先写在修复前失败的测试（init 返回 `self`、返回 `nil`、换成别的对象，以及 `newsItem` 式的 +0 方法），用引用计数断言，不靠崩溃。

同类排查：工具箱里另外三处也不认这些方法族——`@RuntimeClassProxy` 不认 init 族，`@RuntimeClassHook` 与 `@DynamicSubclassHook` 生成的 block 按 +0 返回、也不消耗接收者。它们本来就不支持这几族，改为在编译期报错，各配一个宏测试；加报错前先搜各仓库有没有现成用法。这是 bug 修复，不在 FrameworkToolbox 另写提案。

修复在 FrameworkToolbox 的 worktree 里做，合进它的 `main` 后推送，再打 0.17.2 的 tag 推送。0.17.2 同时带上 `main` 上已有、尚未发版的修复：`ObjCRuntimeToolbox-Static` 声明为 `.static`。0.17.1 里这个产物是自动链接，构建一旦出现重复链接，它就被悄悄改成 `@rpath` 动态库，payload 进了 Dock 便加载不了；声明为 `.static` 后，同样情况直接构建失败。

### 依赖

- LaunchpadAwakener 依赖 FrameworkToolbox `from: "0.18.0"`。
- 只有 PayloadCore 依赖 `ObjCRuntimeToolbox-Static`，只有 Dock 里嵌一份，满足「每个进程只能嵌一份」。独立版、文本输入辅助进程与共用的 SpringboardCore 调的都是系统框架导出的类，改按头文件声明之后不再需要它。
- 构建后核对 payload 的 `otool -L`：除自身外没有 `@rpath` 依赖，也没有 AppKit。工具箱的 `DynamicObject+Unwrapping.swift` 写了 `import AppKit`，但链接器只链真正用到的自动链接库：现在 PayloadCore 的目标文件里记着 OpenGL、Metal，payload 里一个也没有。

### 写法的分工

| 调用 | 写法 | 处数 |
|------|------|------|
| `-[DockAppEventHandler handleDockBarEvent:type:]`、`-[Spotlight sendLaunchAppsBrowsing]` | `@RuntimeClassHook` + `@RuntimeMethodReplacement`，`callOriginal` 带类型 | 2 |
| 系统框架导出的私有类：IconServices 的 `ISIcon`、`ISImageDescriptor`、`ISImage`，IconFoundation 的 `IFColor`，SkyLight 的 `SLSIconAppearanceConfiguration`，QuartzCore 的 `CAFilter`、`CALayerHost`、`CAContext`，AppKit 的 `NSDockTile`、`NSWindow` 私有方法 | 在 `LaunchpadAwakenerPrivateInterfaces` 与 `LaunchpadAwakenerAppKitPrivateInterfaces` 的头文件里声明，直接调用，运行时不核对 | 23 |
| Dock 里类名固定的类：`WALayerKitWindow`、`DockBar`、`DisplayDescriptor`、`DockVisibility`、`ECGridLayer`、`ECImageGridLayer`、`ECShadowTextLayer`、`ECTextLayer`、`CALayer` 的 Dock 分类、玻璃的四个类 | `@RuntimeClassProxy`：实例方法照常写，构造写成 `init?(…)`，`+currentDockMaterialEnvironmentWithColorScheme:` 写成 `static func` | 31 个实例方法、6 个构造、1 个类方法 |
| 经 `DockBar.environment` 拿到的对象：环境对象、图标样式的监视器与 `IconAppearance`、卸载器 | `@RuntimeObjectProxy`，按对象自己的类核对；卸载的回调写成 `@escaping @convention(block)` 参数 | 7 |
| SkyLight、CoreGraphics、HIToolbox 经 `dlsym` 取的 C 函数 | 不变，不归 Objective-C 运行时管 | — |

一个 proxy 协议只放同生共死的方法：proxy 在第一次使用时整批核对，一个不符整个协议停用。可选功能（玻璃、Dock 显隐）的方法单独成协议，即使同属 `DockBar`，缺了也只丢那个功能，和现在一样。

**为什么不用 `DynamicObject`。** 它按方法的真实签名装参数，寄存器不会错位，但有三处短板：

- 参数按 `Any?` 的内存原样拷贝，不做类型换算，也不经编译器检查。实现说明记过的坑（`EC*` 的 `scaleFactor` 是 `float`，按 `CGFloat` 传会错）在它这里不报错，只会传进一个错的值；proxy 里写错类型，推出的编码对不上，第一次使用时就整批停用并写日志。
- 超过三个字长的结构体（`CGRect`）要手动包进 `NSValue`，忘了也能编译，传进去的是装箱的指针。
- 每次调用都经 `NSInvocation`，还会在 debug 日志里格式化接收者与每个参数的描述；proxy 直接调方法的实现。

一开始 proxy 表达不了构造、类方法、block 参数与类名不固定的对象，这些先用 `DynamicObject`，并在调用旁边手写类型编码去核对。随后给 FrameworkToolbox 补上了这几样（0.18.0，提案见它仓库里的《补齐 runtime proxy：init、类方法、block 参数与按对象核对的 proxy》），payload 里的手写编码与 `DynamicObject` 调用一并去掉。0.17.2 修好的 `DynamicObject` 引用计数问题仍然成立，只是本项目不再用它。

### 核对与日志保持原样

- 装 hook 前仍把复刻要调的 23 个 Dock 方法逐个核对，不符的每个都在项目的 subsystem 下写出新编码；清单全部由各 proxy 生成的 `methodRequirements` 汇总，构造方法也在内。`Checked N Dock method(s), M mismatch(es)` 与 `Installed 2 hook(s)` 两行不变，实现说明里「适配新的 Dock 构建」的流程不用改。
- 工具箱自己的日志（每个 hook 装上、某个 proxy 被停用）在 subsystem `ObjCRuntimeToolbox` 下。

### 删掉 HookKit

`RuntimeMethodHook` 是 `MethodHookInstaller` 的泛化版，多了两项检查（同一方法装第二次、同一批里重复），比对编码时把 x86_64 上 `BOOL` 的 `c` 与 arm64 的 `B` 视为相同。`MethodHookInspector` 换成 `RuntimeMethodInspector` 与 `ObjCTypeEncodingNormalization`。

### 测试与验证

- FrameworkToolbox：新加的引用计数测试与宏测试先红后绿，整个包的测试通过后才打 tag。
- PayloadCoreTests 与 StandaloneCoreTests 各加一组测试：每个 proxy 与 hook 推出的编码，与现在从 27.2 元数据记下的编码一致，Swift 类型写错在开发机上就会失败；另锁定 23 个必查方法的清单。
- `RunScript.sh` 构建（核对切片）、跑包测试、核对 payload 的 `otool -L`。
- 部署到 MacBook（27.2）与 26 虚拟机做非交互验证：日志里 23 个方法全部吻合、2 个 hook 装上、离屏自检与改前一致；独立版跑 `--self-check`。不做交互验证。

### 文档

`CLAUDE.md` 的结构表与「加 hook」一节、实现说明《Launchpad 复刻》里校验签名的一段、`PayloadHooks.swift` 开头的说明。

### 落地步骤

1. **已完成。** FrameworkToolbox：`DynamicObject` 按 ARC 规则判断方法族、正确处理 init，先写失败的引用计数测试；三个宏对接不住的方法族在编译期报错，配宏测试；更新文档；合进 `main` 推送，打 0.17.2 推送。
2. **已完成。** LaunchpadAwakener 依赖 0.17.2 与 `ObjCRuntimeToolbox-Static`，`HookKit` 的用处换成工具箱后删掉 `HookKit`；构建、测试、核对 payload 的 `otool -L`。
3. **已完成。** 两个 hook 改 `@RuntimeClassHook`，加编码一致性测试。
4. **已完成。** 37 处实例方法改 `@RuntimeClassProxy`，23 个方法的核对清单改由 proxy 汇总，加编码一致性测试。
5. **已完成。** 27 处改 `DynamicObject`，含 7 处 init。
6. **已完成。** 文档：`CLAUDE.md`、实现说明、`PayloadHooks.swift` 开头的说明。
7. **已完成。** 部署到 MacBook 与 26 虚拟机做非交互验证，独立版跑 `--self-check`。
8. **已完成。** 系统框架导出的私有类改为按头文件声明、直接调用。
9. **已完成。** FrameworkToolbox 0.18.0：proxy 支持 `init?`、`static`、block 参数，新增 `@RuntimeObjectProxy`。
10. **已完成。** 剩下 11 处手写编码改由 proxy 推出，去掉 `DynamicObject`；构建、测试、部署到两台测试机验证。

### 没有询问就采用的假设

- 在 `.worktrees/LaunchpadAwakener-ObjCRuntimeToolbox` 里做，基于 `main`；主检出里未提交的 FrameworkToolbox 升级保持不动。
- 与 AppKit 重写那条线只在 `Package.swift` 上重叠，合并时手动解决。
- 部署前先看 MacBook 上跑的是谁的构建，覆盖了别人的就在汇报里说明。

## 决策日志

| 日期 | 决定 | 理由 |
|------|------|------|
| 2026-11-09 | Created as Draft | 用户希望用 FrameworkToolbox 的 ObjCRuntimeToolbox 取代项目里手写的私有调用与 hook，并指出 `DynamicObject` 能按名字直接调用私有方法 |
| 2026-11-09 | 私有调用以 `@RuntimeClassProxy` 为主，`DynamicObject` 只补宏表达不了的调用 | 用户选定。proxy 的编码由声明推出、参数类型经编译器检查，`DynamicObject` 按内存原样拷参数，类型写错不报错 |
| 2026-11-09 | 依赖 FrameworkToolbox 0.17.2，由 agent 打 tag 并推送 | 用户选定。`.static` 让意外的重复链接直接构建失败，而不是变成 payload 带不走的动态库 |
| 2026-11-09 | 7 处 alloc + init 先在 FrameworkToolbox 修好 `DynamicObject` 的引用计数，再改用 `DynamicObject` | 用户选定。按 bug 修复处理，同类问题（两个 hook 宏、proxy 宏不认的方法族）一并改为编译期报错 |
| 2026-11-09 | 用户批准，开始实现 | 先做 FrameworkToolbox 的修复与发版，再做 LaunchpadAwakener |
| 2026-11-09 | FrameworkToolbox 的修复按 bug 修复处理，没有另写提案 | 规则把显而易见的 bug 修复排除在提案之外；修法、复现测试与同类排查都写在它的提交说明与 `CLAUDE.md` 里 |
| 2026-11-09 | 同类排查加的编译期报错只针对返回对象的方法族方法，返回 `Void` 的照常可替换 | ARC 的方法族只管返回对象的所有权；`copy:` 这类动作方法若一并报错，就把原本正确的替换也拦掉了 |
| 2026-11-09 | 第 2、3 步合成一个提交，第 4、5 步也合成一个提交 | 好几个文件里两种写法都有，拆开要先做出一个只为分提交而存在的中间状态 |
| 2026-11-09 | 可能为空的 CF 指针（`CGImage`、`otherIconTintColor`）经 `DynamicObject` 按 `UnsafeRawPointer??` 取 | 按非可选的 `CGImage` 取，空指针会被当成有效引用 |
| 2026-11-09 | 辅助进程读 `contextId` 不另加编码核对 | 无参 getter：`DynamicObject` 按真实签名取返回值，`asUInt32` 还核对返回值的大小；原来用 KVC 读，也没有核对。`_contextForLayerHosting` 照旧核对 |
| 2026-11-09 | 文本输入辅助进程的 `NSDockTile` proxy 没有签名测试 | 这个模块没有测试 target；两个编码由 `Int`、`Bool` 推出，运行时 proxy 自己也会核对。两个方法在 27.2 的 AppKit 里声明在 `NSDockTile` 本身上 |
| 2026-11-09 | 实现完成，第 7 步的测试机验证待做 | 包测试与两个 scheme 的构建都通过，payload 的链接清单与改动前一致；MacBook 正被 AppKit 重写那条线做交互测试，部署会打断它，26 虚拟机没有开机。没有合进主检出：主检出里有未提交的 `Package.swift` 与 `Package.resolved` 改动，挡住了快进 |
| 2026-11-09 | `ISIcon` 的初始化方法改回在 `alloc` 出的对象上核对 | 第一次部署时所有图标都取不到：`ISIcon` 是类簇，`initWithURL:` 在 `+alloc` 给出的 `ISIconFactory` 上，按类名核对找不到。同类排查：另外两处由「在对象上核对」改成按类名核对的（`DockVisibility`、`SLSIconAppearanceConfiguration`）查过，对象就是那个类本身，不受影响 |
| 2026-11-09 | 测试机验证完成 | MacBook 27.2 与 26.6.2 虚拟机：23 个方法全部吻合、两个 hook 装上、离屏自检与改前一致，图标全部取到；独立版自检解析出图标样式。没有做交互验证 |
| 2026-11-09 | 系统框架导出的私有类改为按头文件声明、直接调用，运行时不再核对；Dock 自己的类照旧经 proxy 与 `DynamicObject` 核对 | 用户选定，免得这些调用旁边还挂着类型编码字面量。这些类由各自的框架导出、SDK 里有可链接的存根，用到的 23 个方法在 26.6.2 与 27.2 上逐个核对过，存在且编码相同；Dock 不导出任何类，只能在运行时按名字找。代价是将来某个系统改了签名不会被拦下，靠开发机上的冒烟测试与适配新系统时的核对发现。生产代码里的编码字面量从 27 处减到 11 处，全在调 Dock 的地方 |
| 2026-11-09 | 剩下 11 处也改由声明推出：给 FrameworkToolbox 补上 proxy 的构造、类方法、block 参数与按对象核对的 `@RuntimeObjectProxy`，发 0.18.0 | 用户希望连 Dock 这边的手写编码也去掉，并同意在工具箱表达不了时给它加功能；之后一路做完、最后验收。11 处正好是 proxy 表达不了的四种调用：构造、类方法、block 参数、类名随版本变的对象（环境对象在 26.6.2 叫 `Environment`，27.2 叫 `_TtC8DockCore11Environment`） |
| 2026-11-09 | 文字图层也改由 proxy 的 `init?()` 构造（原来按 `CATextLayer.Type` 直接调 `init`） | 两个 `init` 本来就在 23 个必查方法里，靠手写的签名条目登记；改成 proxy 后由声明推出，清单与数目不变 |
| 2026-11-09 | 卸载的回调闭包标 `@Sendable` | 回调在 XPC 或全局队列上到来；不标的话，它会被当成随所在函数隔离在主 actor 上的闭包 |
| 2026-11-09 | 第二轮测试机验证完成，实现完成，待用户验收后收尾 | MacBook 27.2 与 26.6.2 虚拟机：23 个方法全部吻合、两个 hook 装上，环境对象在两个版本的类名下都核对通过，图标样式、卸载器、网格、图标、壁纸与 27.2 的玻璃都与改前一致；独立版自检照旧。代码里的类型编码字面量为 0，也不再调用 `DynamicObject`。真正删除应用要交互，没有验证 |
| 2026-11-10 | 落地：编号 0006，状态 Implemented，快进进 `main`，与 AppKit 重写同一批推送、排在它前面 | 摘要承诺的都已实现：hook、Dock 的类与经环境对象拿到的对象全部由声明推出编码，系统框架的私有类按头文件直接调用，HookKit 已删。落地前的验证在两条线合起来的最终代码上跑：两个 scheme 的 `RunScript.sh` 构建与包的全部测试。真正删除应用要交互，仍没有验证，留作后续。文档判断：Launchpad 复刻的实现说明与 `CLAUDE.md` 已随实现更新，不需要另写实现说明或使用指南；没有新的项目术语，`@RuntimeClassProxy` 这类是工具箱的 API 名，术语表不动 |
