# 0001 - 用常驻辅助进程给搜索框与改名框接上输入法

- **状态**: Implemented
- **作者**: JH
- **创建日期**: 2026-11-08
- **最后更新**: 2026-11-08
- **所属愿景**: 无
- **关联提案**: [在 macOS 27 的 Dock 中复刻 macOS 15 的 Launchpad](draft-launchpad-replica.md)（第 6 批第 6 步剩下的输入法）
- **实现分支 / PR**: `feature/input-method-helper`，已合进 `main`，分支已删除；原型在 `experiment/input-method-probe`
- **配套文档**: [实现说明](../Internal/LaunchpadReplica.md)「输入法靠一个托管文本框的辅助进程」

## 摘要

复刻的搜索框与文件夹改名框自己处理按键，接不了输入法，打不出中文、日文、韩文。15 的这两个框是 Dock 包里另一个进程（`com.apple.dock.ecti` 服务）托管的真 `NSTextField`：画面经 `CALayerHost` 显示在 Dock 的界面里，按键由 Dock 转发过去，输入法在那个进程里照常工作。27.2 删掉了这个服务。本提案新增一个随 App 安装、由 launchd 按需启动的辅助进程，照 15 的做法托管文本框；payload 连上它就改用它的框，连不上时退回现在的本地编辑。

## 动机

- **搜索打不出中文。** 测试机上的 App 名大多是中文（「日历」「计算器」），现在只能靠 App 文件名的英文去匹配；文件夹改名也只能输入键盘直接打出的字符。
- **输入法不该由复刻自己实现。** 组字、候选窗、表情与符号面板都属于系统的文本输入体系，只有真正的文本框才接得上；15 也是这样做的。
- 总提案把这一项列为第 6 批的后续项（决策日志 2026-11-08「输入法留作后续项，另起提案」），用户要求接着做。

## 前期调研

- **现状代码怎么走的**：
  - 搜索框是 `SpringboardSearchFieldLayer`（`Interface/SpringboardControlLayers.swift`），文字、光标与选区都自己画。编辑交给 `SpringboardFieldEditor`，按键分流在 `SpringboardInterface.searchFieldCommand`（`Interface/SpringboardInterface.swift`）。
  - 改名框在 `SpringboardFolderPanel` 里，同样用 `SpringboardFieldEditor`。
  - 按键经 hook `-[DockAppEventHandler handleDockBarEvent:type:]` 进入 payload。界面打开时 Dock 用 `CPSStealKeyFocusOnConnection` 持有键盘焦点（实现说明「事件入口」一段）。
- **15.5 的做法**（逆向笔记 `/Volumes/RE/Dock/15.5/Notes/LaunchpadFoldersAndDragging.md` 3.1）：
  - 每个框连 ecti 服务的一个实例。建立时传宽高、字符串、字体、颜色、是否有焦点。
  - 服务把文本框放进 Dock 图块的 mini view 窗口。这个窗口不上屏，却能成为 key 窗口。窗口供跨进程显示的上下文编号交给 Dock，Dock 用 `CALayerHost` 显示它。
  - Dock 一直持有键盘焦点，把按键与框内的点按复制后，标上服务窗口的编号和位置，用 `CGEventPostToPid` 发给服务。组字期间按键全部转发。
  - 服务回报文字、是否编辑结束、是否在组字。
  - 服务的 `NSApplication` 子类把 `_stealKeyFocusWithOptions:` 与 `_releaseKeyFocus` 覆写成直接返回 0，并调用 `_TSMSetRemoteViewActivation(1)`、`_TSMRegisterRemoteViewClient(1)`。这样 AppKit 与文本服务都把它当作已激活的 App，输入法照常工作。
- **27.2 还剩什么**：
  - Dock.app 里没有 ecti 服务，Dock 也不再导入 `CALayerHost` 与 `CGEventPostToPid`。
  - 系统一侧都还在，见 27.2 dyld shared cache 的 AppKit 头文件与 27.2 SDK 的 tbd：
    - `-[NSApplication _stealKeyFocusWithOptions:]` 与 `_releaseKeyFocus`
    - `NSDockTile.miniView`
    - `NSDockMiniViewWindow`，带 `canBecomeKeyWindow` 与 `_isNonactivatingPanel`
    - `-[NSWindow _contextForLayerHosting]`
    - HIToolbox 导出的 `_TSMSetRemoteViewActivation`、`_TSMRegisterRemoteViewClient`
    - CoreGraphics 导出的 `CGEventPostToPid`、`CGEventSetWindowLocation`
  - Dock 进程有发事件的权限（`kTCCServicePostEvent`）。
- **第一步原型验证过的**（2026-11-08，测试用的 MacBook，macOS 27.2；代码在分支 `experiment/input-method-probe`）：
  - Dock 里的 `CALayerHost` 只设 `contextId`，就能显示辅助进程窗口的上下文（`window._contextForLayerHosting.contextId`），不需要 `hostingToken`。
  - 27.2 的 Dock 不再通知 App「mini view 已显示」，所以辅助进程要自己调 `-[NSDockTile _setMiniViewShown:YES]`：
    - 不调的话，mini view 窗口成不了 key 窗口，覆写的抢焦点方法根本不会被调用，转发的按键进不了文本框。
    - 调了之后，AppKit 会调用覆写的 `_stealKeyFocusWithOptions:`。窗口成为 key，App 算作已激活，第一响应者是字段编辑器，按键能打字。
  - 转发事件时照 15 把字段 51 设成辅助进程的窗口编号。不设它行不行，没单独验证。
  - 拼音组字正常，空格能上屏。候选窗要照 15 把窗口层级设成 27（`_setMiniViewWindowLevel:27`），才会出现在 Launchpad 上方。它出现在框的正下方，位置取自辅助进程窗口在屏幕上的位置。

## 提议方案

1. **辅助进程**：新增 `LaunchpadAwakenerTextInput.app`。它没有 Dock 图标与菜单栏（LSUIElement），放在 App 的 `Contents/Library/LoginItems/`。App 用 `SMAppService.agent` 把它注册成 LaunchAgent，带一个 Mach 服务名，Debug 与 Release 各用一个，与 daemon 的做法一致。payload 用 XPC 连这个名字，由 launchd 按需启动它；它退出后，下次连接时会再启动。
2. **一个框一个会话**：辅助进程照 15 的 ecti，为搜索框、改名框各建一个会话：
   - 建 mini view 窗口与 `NSTextField`，回报上下文编号、进程号与窗口编号；
   - 之后回报文字、选区、是否在组字、是否编辑结束。
3. **payload 一侧**：
   - 在框的位置放一个 `CALayerHost` 显示辅助进程的框。
   - 按 15 的规则转发 Dock 收到的按键与框内的点按，组字期间全部转发。
   - 搜索与改名的逻辑不变，只是文字改由辅助进程提供。
4. **退回**：连不上辅助进程、它中途退出，或者第一步证明这条路不可行时，照旧用现在的本地编辑，其他功能不受影响。

### 非目标

- 不改搜索的匹配规则，不在 payload 里自己实现组字。
- 不为个别第三方输入法的候选窗位置等差异做专门处理，只保证不出错、能退回。
- 不做 15 的文本框没有的特性。

## 详细设计

**共享常量**放在 `LaunchpadAwakenerShared`，它不依赖任何东西，App、辅助进程、payload 都能用：

```swift
public enum TextInputServiceIdentity {
    /// The LaunchAgent's Mach service; Debug and Release differ, as the daemon's do.
    public static let machServiceName: String
    public enum MessageKey {
        public static let request = "request"
    }
}
```

**消息**都是 XPC 字典，键 `request` 指明种类：

| 方向 | 种类 | 内容 |
|---|---|---|
| payload → 辅助进程 | `setup` | 框的种类（搜索 / 改名）、宽、高、字符串、选区、字体描述、前景色、是否有焦点 |
| payload → 辅助进程 | `update` | 新的字符串或焦点；收起时要求提交组字并结束 |
| 辅助进程 → payload | `hosted` | 上下文编号、进程号、窗口编号 |
| 辅助进程 → payload | `stringUpdate` | 字符串、选区、是否在组字、是否编辑结束 |

按键与点按不走 XPC：payload 照 15 用 `CGEventPostToPid` 直接发给辅助进程，事件上标好窗口编号与窗口内位置。

**模块**按「谁链接它」划分：

- 包里新增 `LaunchpadAwakenerTextInputCore`（AppKit），只给辅助进程链接。里面放 `NSApplication` 子类、XPC 监听与会话。
- 辅助进程的 Xcode target 只有一个两行的 `main.swift`。
- payload 一侧：`Host/TextInputHelperClient.swift` 负责连接与消息；`Interface/SpringboardRemoteTextField.swift` 负责 `CALayerHost` 与事件转发。payload 仍然不链接 AppKit。

## 替代方案考量

- **在 Dock 进程里直接接文本服务**：Dock 不加载 AppKit 与 HIToolbox。要接，就得在系统进程里加载整套 AppKit，体积与风险都大；而且输入法按进程激活，Dock 不是前台 App。否。
- **把辅助进程做成 App 包里的 XPC 服务**：XPC 服务只有所在的 bundle 连得上，Dock 连不到。否。
- **由 App 本身托管文本框**：假装成 key 的窗口会抢走 App 自己窗口的 key 状态；而且 App 不一定在运行。否。

## 影响

### 用户可见变化

搜索框与改名框能用所有输入法，包括组字、候选窗、表情与符号面板。框里的文字、光标与选区改由 AppKit 绘制，与 15 一致。辅助进程不可用时，行为与现在相同。

### 可发现性

默认开启，不需要设置。第一次注册时系统会提示「已添加后台项目」，这个后台项目可以在「系统设置 › 通用 › 登录项」里看到。

### 数据与配置兼容

没有数据迁移。多出一个后台项目；用户关掉它，就退回本地编辑。

### 平台与最低版本

与总提案相同，只支持 macOS 27.2。依赖几处私有接口，每个新系统构建都要复核，复核方式与 Dock 的构建档案相同。

### 发布

App 与辅助进程都不需要新的权限或 entitlement：发事件的是 Dock，它本来就有这个权限。

## 落地步骤

1. ✅ **原型（一次性）**：2026-11-08 证明可行，结论见「前期调研」。辅助进程手工编译，payload 里加调试代码。在 MacBook 上依次证明：
   - Dock 里的 `CALayerHost` 能显示辅助进程的文本框；
   - 转发的按键能打字，点按能放光标；
   - 拼音组字与候选窗的位置正确。
   结论记进本提案，原型代码推到 `experiment/input-method-probe`。证明不可行就停在这一步，提案改记结论。
2. ✅ **工程**：新增辅助进程 target、包里的 `LaunchpadAwakenerTextInputCore` 模块、生成 LaunchAgent plist 的脚本，App 负责注册这个 agent。
3. ✅ **辅助进程**：XPC 监听、会话、文本框与回报。
4. ✅ **payload**：连接、`CALayerHost`、事件转发，先接进搜索框。
5. ✅ **改名框**接进来，Return、Enter 与 Esc 都照 15 按当前文字提交。
6. ✅ **退回与清理**：连接失败或中途断开时退回本地编辑；收起时提交组字，并关掉 remote view 激活。

每一步都在 MacBook 上验证（用户同意交互验证）。

**收尾时必须判断两件事**（判断结果写进决策日志，不允许沉默跳过）：

- **要不要配套专题文章**：有「从 API 签名看不出来的调用方契约」就写使用指南；有「下次维护会踩、代码本身看不出来的决策」就写实现说明。写了就登记到头部的「配套文档」。
- **有没有引入新术语**：有就同批次登记进术语表（项目级 `Documentations/Glossary.md`）。

## 决策日志

| 日期 | 变更 | 说明 |
|------|------|------|
| 2026-11-08 | Created as Draft | 复刻的搜索框与改名框接不了输入法，打不出中文；总提案把它列为后续项，另起提案 |
| 2026-11-08 | 用户要求接着做，并选择提案写完直接按它做；提案由 agent 起草，用户事前未审阅 | — |
| 2026-11-08 | 开始实现，在 `feature/input-method-helper` 上。新增进程属于完整档，按完整模板写 | — |
| 2026-11-08 | 辅助进程做成 LaunchAgent，不做 XPC 服务，也不交给 App 本身托管 | 理由见「替代方案考量」 |
| 2026-11-08 | 第一步原型证明可行，按方案继续；原型代码推到 `experiment/input-method-probe` | 显示、打字、拼音组字与候选窗都在 MacBook 上看到了。比 15 多两处调用：辅助进程自己声明 mini view 已显示，并把窗口层级设成 27 |
| 2026-11-08 | 第 2–6 步做完，都在 MacBook 上交互验证过（见实现说明「验证」） | App 注册 LaunchAgent 不用用户批准；搜索框、改名框都能用拼音，结束辅助进程后退回本地编辑，再打开时 launchd 重新拉起它 |
| 2026-11-08 | 辅助进程只托管一个框，搜索框与改名框轮流用；每次换框先结束上一段编辑 | 一个进程只有一扇 mini view 窗口；两个框不会同时编辑。不先结束编辑，字段编辑器会沿用上一个框的对齐方式，改名框就靠左了 |
| 2026-11-08 | 组字状态由改写了 `setMarkedText`、`unmarkText` 的字段编辑器报告，回报的文字不含组字部分 | 输入法组字时文本框不发变更通知；搜索照 15 只按已上屏的文字找，组字时本地的占位文字让开 |
| 2026-11-08 | 辅助进程只接受 Dock 的连接（按进程路径核对） | 框里打的字会经它回报，别的进程不该连得上 |
| 2026-11-08 | 实现完成 | 文档：实现说明加了做法、验证与已知降级，项目 CLAUDE.md 加了第五个二进制、服务名与重启方法，术语表登记了「文本输入辅助进程」；没有调用方契约，不需要使用指南 |
| 2026-11-08 | 自审（code-review medium）：10 条发现，修 9 条。收起得比辅助进程回复还快时它不放手；改名时组字中点到别处丢字；在打开的文件夹里改名后、或捏合打开时，托管框按缩放中的图层定位，点按与候选窗都偏；无焦点时仍显示光标；辅助进程退出后占位文字一直隐藏；只按进程路径认 Dock，进程号可能被复用；部署后旧辅助进程还在跑；`CALayerHost` 的私有接口在界面层直接调用，没先核对签名；TSM 函数每次都重新查找。另 1 条（两处重复代码）判为不修，记在已裁决清单 | 托管框的位置改按几何规格计算，补了单元测试；其余在 XPC、AppKit 与界面之间，测试进程里没有 seam，都在 MacBook 上交互验证过：无焦点没有光标、打字后出现；touch 辅助进程的可执行文件模拟部署后它自行退出、下次由新进程托管；改名后搜索框位置与候选窗正常；组字中点到面板外，名字补成组字上屏的文字 |
| 2026-11-08 | 自审第二轮（只审第一轮的修复）：10 条发现，修 7 条，测试那条补了能补的，另 2 条登记 | 修的：辅助进程还没托管上改名就结束时，它回报的旧名字会盖掉本地打的新名字；托管失败后它会回报上一个框残留的文字；界面收起得比回复快时补写的名字丢失；签名不符的消息被拒时不留日志；`CALayerHost` 的签名按字符串原样比较、每次都重新查（辅助进程里同样的写法一并改用 HookKit 现成的比较）；焦点重复发送；一处重复的状态重置。改名结束时是否采用辅助进程文字的判断抽成纯函数，补了修前失败的测试。登记的：改名框位置按图层换算（误报）、焦点与按键分两路到达（不修）、其余修复没有回归测试（没有 seam）。合起来的构建在 MacBook 上验证过：组字中点到外面的改名补写后收起再打开仍在，英文改名按回车不被改回，无焦点无光标、打字后出现 |
| 2026-11-08 | 实现完成，待用户看过后收尾 | — |
| 2026-11-08 | Implemented，编号 0001 | 用户看过后收尾。文档的判断见「实现完成」那一行：实现说明已有专节，没有调用方契约、不需要使用指南，「文本输入辅助进程」已登记进术语表。后续项：总提案同日把支持范围扩到 macOS 26.0 到 27.2，辅助进程只在 27.2 上验证过，26 上没试 |
