# LaunchpadAwakener 文档索引

- [Evolutions/README.md](Evolutions/README.md) —— 提案状态总表
- [Evolutions/draft-launchpad-replica.md](Evolutions/draft-launchpad-replica.md) —— 在 macOS 27 的 Dock 中复刻 macOS 15 的 Launchpad（In Progress）
- [Evolutions/draft-appkit-rewrite.md](Evolutions/draft-appkit-rewrite.md) —— 两个 App 的界面改用 AppKit 与 UIFoundation、AppKitPlus 重写，不再用 SwiftUI（In Progress）
- [Evolutions/0001-input-method-helper.md](Evolutions/0001-input-method-helper.md) —— 用常驻辅助进程给搜索框与改名框接上输入法（Implemented）
- [Evolutions/0002-standalone-launchpad.md](Evolutions/0002-standalone-launchpad.md) —— 不注入 Dock 的独立版 Launchpad：与注入版共用数据层与界面层（Implemented）
- [Evolutions/0003-app-control-panel.md](Evolutions/0003-app-control-panel.md) —— 照 DockIconOverride 重做注入版 App 的控制面板：状态横幅、payload 通道、daemon 自愈、重启 Dock、菜单栏 App（Implemented）
- [Evolutions/0004-background-switch.md](Evolutions/0004-background-switch.md) —— 在控制面板里切换 Launchpad 的背景：模糊壁纸或玻璃（Rejected）
- [Evolutions/0005-launchpad-organizer.md](Evolutions/0005-launchpad-organizer.md) —— 在注入版 App 里整理 Launchpad 的布局：多选移动、文件夹管理、拖动排序、一键整理（Implemented）
- [Evolutions/0006-objc-runtime-toolbox.md](Evolutions/0006-objc-runtime-toolbox.md) —— 用 FrameworkToolbox 的 ObjCRuntimeToolbox 改写 hook 与私有调用，删掉 HookKit（Implemented）
- [Internal/LaunchpadReplica.md](Internal/LaunchpadReplica.md) —— Launchpad 复刻的实现说明：关键决策、模块结构、验证、新 Dock 构建的适配流程
- [Internal/StandaloneLaunchpad.md](Internal/StandaloneLaunchpad.md) —— 独立版 Launchpad 的实现说明：宿主接口、Dock 图层类的等价实现、验证
- [Internal/ControlPanel.md](Internal/ControlPanel.md) —— 注入版 App 控制面板的实现说明：payload 通道、旧 payload 的识别、闪退保护、状态横幅的顺序
- [Internal/LaunchpadOrganizer.md](Internal/LaunchpadOrganizer.md) —— 整理 Launchpad 窗口的实现说明：App 不碰数据库、编辑带版本号、一批编辑一个事务、拖动与分类
- [Internal/ReviewAdjudications.md](Internal/ReviewAdjudications.md) —— 代码审查的已裁决清单：判为误报或不修的发现与理由
- [Glossary.md](Glossary.md) —— 术语表：构建档案、DockSwipe、宿主、注入版、独立版、退回开关、payload 通道、闪退保护、常驻 payload、等价图层、离屏自检、Springboard、文本输入辅助进程
