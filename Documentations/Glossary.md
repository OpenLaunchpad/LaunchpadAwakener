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

以 Dock 可执行文件 arm64e 切片的 `LC_UUID` 为键、记着只对那一个 Dock 构建成立的事实的一条记录（目前是 `DockBar` 全局变量的地址）。不在表里的构建，payload 一个 hook 都不装。

- **主要出现在**：`LaunchpadAwakenerPayloadCore/Host/DockBuildProfile.swift`、[实现说明](Internal/LaunchpadReplica.md)「适配新的 Dock 构建」

### DockSwipe

系统手势在 Dock 那里的原始形态：CGEvent 类型 30、HID 事件类型 23 的事件，字段 123 是动作（3 为捏合或张开），124 是进度，132 是阶段。捏合手势就是读它实现的；它不是 macOS 27 的 Gestures.framework 识别出的手势。

- **主要出现在**：`LaunchpadAwakenerPayloadCore/Interface/SpringboardInputEvent.swift`、`Integration/SpringboardInputEvent+CoreGraphics.swift`

### Kill switch（退回开关）

文件 `/tmp/LaunchpadAwakener.disabled`。它存在时，所有「打开 Apps」的入口退回系统的 Apps，正在显示的界面在下一个事件时收起。界面失控、屏幕不能用时，经 ssh 创建它是出路。

- **主要出现在**：`LaunchpadAwakenerPayloadCore/Interface/SpringboardController.swift`、项目 `CLAUDE.md`

### Self-check（离屏自检）

开发构建在 Dock 启动、布局第一次加载时，不上屏地建一次界面，把 Dock 图层类的产物（网格类名、图标与标题的位置、文件夹缩略图、壁纸截图尺寸）写进日志。用来在不打开界面的情况下核对接线。正式构建没有它。

- **主要出现在**：`LaunchpadAwakenerPayloadCore/Interface/SpringboardSelfCheck.swift`

### Springboard

本项目沿用 macOS 15 的叫法：Launchpad 的主界面及其主控。代码里的 `Springboard*` 类型分别对应 15.5 的 `Springboard`、`ECSBSpringboard`、`ECSBLayer`、`ECSBGroupLayer` 等；与 iOS 的 SpringBoard 无关。

- **主要出现在**：`LaunchpadAwakenerPayloadCore/Interface/`
