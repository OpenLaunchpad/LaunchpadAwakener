# 术语表

本项目专有名词与约定用法。

跨项目通用的术语收录在全局术语表中，本表只收本项目特有的，不重复登记。全局表不在本仓库内，位于 iCloud Global 镜像的 `Documentations/Glossary.md`。

## 收录范围

**收**：项目自造词与内部代号、本项目内反复出现的缩写、通用术语在本项目里的特定含义、容易混淆的近义词对。

**不收**：语言与框架的通用术语（Swift 的 `optional`、Core Animation 的 `CALayer`）。

## 维护约定

提案或专题文章引入新术语时，同批次登记进本表。文档里首次出现该术语时展开一次并链到这里。

## 术语

按英文名 / 标识符字母序排列。

### DockBuildProfile（构建档案）

以 Dock 可执行文件 arm64e 切片的 `LC_UUID` 为键、记着只对那一个 Dock 构建成立的事实的一条记录：`DockBar` 与 `DockGlobals` 两个全局变量的地址、`DockGlobals` 的类名，以及它随哪些系统版本发布。不在表里的构建，payload 一个 hook 都不装。表里登记了 macOS 26.0 到 27.2 的全部正式构建。

- **主要出现在**：`LaunchpadAwakenerPayloadCore/Host/DockBuildProfile.swift`、[实现说明](Internal/LaunchpadReplica.md)「适配新的 Dock 构建」

### DockSwipe

系统手势在 Dock 那里的原始形态：CGEvent 类型 30、HID 事件类型 23 的事件，字段 123 是动作（3 为捏合或张开），124 是进度，132 是阶段。捏合手势就是读它实现的；它不是 macOS 27 的 Gestures.framework 识别出的手势。

- **主要出现在**：`LaunchpadAwakenerSpringboardCore/Interface/SpringboardInputEvent.swift`、`SpringboardInputEvent+CoreGraphics.swift`

### Host（宿主）

画 Launchpad 的那个进程，以及它提供给界面层的那组能力（`SpringboardHost`）：窗口、图层类、Dock 的几何、图标样式、壁纸、玻璃、托管文本框、卸载器。Dock 里的宿主由 payload 提供，用 Dock 自己的类；独立版 App 是另一个宿主。每个进程启动时选定一次（`SpringboardHostSystem.bootstrap(host:)`），界面层只经它拿这些东西。不要和注入时的「目标进程」混用：目标进程只说注入到哪，宿主说的是界面层靠谁画。

- **主要出现在**：`LaunchpadAwakenerSpringboardCore/Hosting/SpringboardHost.swift`、`LaunchpadAwakenerPayloadCore/Host/DockSpringboardHost.swift`、[实现说明](Internal/LaunchpadReplica.md)「模块结构」

### Injected build（注入版）

注入 Dock 的那一版：`LaunchpadAwakener.app` 经特权 daemon 把 payload 注入 Dock，Launchpad 画在 Dock 自己的窗口里，用 Dock 的图层类与玻璃，要关 SIP。与「独立版」相对：两版共用 `LaunchpadAwakenerSpringboardCore`，差别只在宿主。

- **主要出现在**：项目 `CLAUDE.md`、[实现说明](Internal/LaunchpadReplica.md)

### Jiggle mode（抖动模式）

长按图标或按住 Option 后，当前页面（文件夹开着时是文件夹里）的图标一起抖动的状态，可以接着拖动整理。15 的代码管它叫 `deleting`，因为 15 在这个状态下给 App Store 的 App 显示关闭按钮用来删除；复刻只做了抖动，没做删除。不要和 15 代码里的 `editing` 混淆：那是「正在按着或拖着图标」，与抖动无关。

- **主要出现在**：`LaunchpadAwakenerSpringboardCore/Interface/SpringboardJiggle.swift`、`SpringboardPagedGrids.isJiggling`、[实现说明](Internal/LaunchpadReplica.md)「关键设计决策」

### Kill switch（退回开关）

文件 `/tmp/LaunchpadAwakener.disabled`。它存在时，所有「打开 Apps」的入口退回系统的 Apps，正在显示的界面在下一个事件时收起。界面失控、屏幕不能用时，经 ssh 创建它是出路。

- **主要出现在**：`LaunchpadAwakenerSpringboardCore/Interface/SpringboardController.swift`、项目 `CLAUDE.md`

### Replica layers（等价图层）

独立版用来代替 Dock 的 `ECGridLayer`、`ECImageGridLayer`、`ECTextLayer`、`ECShadowTextLayer` 与选中材质的纯 Core Animation 实现，照 Dock 的二进制逐条写成，在 Dock 里逐像素对照过。没有选定宿主时（单元测试）也用它们。注入版仍用 Dock 自己的类。

- **主要出现在**：`LaunchpadAwakenerSpringboardCore/Interface/SpringboardReplicaLayers.swift`、[独立版实现说明](Internal/StandaloneLaunchpad.md)「关键设计决策」

### Self-check（离屏自检）

开发构建在 Dock 启动、布局第一次加载时，不上屏地建一次界面，把 Dock 图层类的产物（网格类名、图标与标题的位置、文件夹缩略图、壁纸截图尺寸）写进日志，并把等价图层与 Dock 的类逐项对照。用来在不打开界面的情况下核对接线。正式构建没有它。

- **主要出现在**：`LaunchpadAwakenerSpringboardCore/Interface/SpringboardSelfCheck.swift`

### Springboard

本项目沿用 macOS 15 的叫法：Launchpad 的主界面及其主控。代码里的 `Springboard*` 类型分别对应 15.5 的 `Springboard`、`ECSBSpringboard`、`ECSBLayer`、`ECSBGroupLayer` 等；与 iOS 的 SpringBoard 无关。

- **主要出现在**：`LaunchpadAwakenerSpringboardCore/Interface/`

### Standalone app（独立版）

不注入 Dock 的那一版：App「Launchpad」（`Launchpad.app`，bundle ID 前缀 `com.MxIris.LaunchpadAwakener.Launchpad`）自己开一扇层级 27、盖住整块主屏幕（连 Dock 与菜单栏）的窗口，用等价图层画同一套 Launchpad，不需要关 SIP。布局存在自己的库里，首次启动从注入版的库导入；注入版把它当作启动器，即使装着也不放进布局。

- **主要出现在**：`LaunchpadAwakenerStandaloneCore/`、`LaunchpadAwakenerStandalone/`、[独立版实现说明](Internal/StandaloneLaunchpad.md)

### Text input helper（文本输入辅助进程）

嵌在 App 里的 LaunchAgent `LaunchpadAwakenerTextInput`，替 Launchpad 托管搜索框或改名框（一次一个），好让输入法能用；相当于 15 的 Dock 包里的 `com.apple.dock.ecti` 服务。payload 在 Dock 里用 `CALayerHost` 显示它的文本框，把按键与点按转发给它；它不可用时 payload 退回本地编辑。

- **主要出现在**：`LaunchpadAwakenerPackage/Sources/LaunchpadAwakenerTextInputCore/`、`LaunchpadAwakenerPayloadCore/Host/SpringboardRemoteTextField.swift`、[实现说明](Internal/LaunchpadReplica.md)「输入法靠一个托管文本框的辅助进程」

### Unsaved folder（未存的文件夹）

拖动时界面上已经出现、库里还没有的文件夹：停在 App 上 1 秒弹开的那个，或快速松手后库写好之前的那个。它的标识符是负数（`LaunchpadItemIdentifier.unsavedFolder`），库发布的新布局到达时按第一个 App 换成真正的文件夹；停住弹开的那个要在面板里松手才写库，拖出面板就解散，库里什么也不留。

- **主要出现在**：`LaunchpadAwakenerSpringboardCore/Interface/SpringboardInterface+FolderMaking.swift`、[实现说明](Internal/LaunchpadReplica.md)「建文件夹先在界面上做出来」
