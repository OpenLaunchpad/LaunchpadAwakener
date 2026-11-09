# 0004 - 在控制面板里切换 Launchpad 的背景：模糊壁纸或玻璃

- **状态**: Rejected
- **创建日期**: 2026-11-09
- **最后更新**: 2026-11-09

## 摘要

Launchpad 的背景有两种：默认的 15 模糊壁纸，以及 Dock 自己的液态玻璃。现在要换成玻璃只能在终端里 `defaults write com.apple.dock springboard-background glass`。本提案在注入版 App 的控制面板里加一个「背景」开关，两种背景一点就换，下次打开 Launchpad 生效，不用重启 Dock。

## 方案

- **开关放在控制面板的「Launchpad」一节**：一个两段的选择器，「Blurred Wallpaper」与「Glass」，副标题写「下次打开 Launchpad 时生效」。悬停提示说明玻璃只在 macOS 27 上有：26 的 Dock 没有这种玻璃，会退回 15 的模糊壁纸。
- **开关直接读写 Dock 的偏好域**（`com.apple.dock` 的 `springboard-background`），不经 payload 通道。Dock 每次打开 Launchpad 都重新读这个键，所以写下去就生效；没注入、payload 是旧版、Dock 正在重启时也照样能改。终端里的 `defaults write` 与开关等价，窗口每 3 秒刷新时把终端改的值也读回来。
- **选模糊壁纸时删掉这个键**，不写 `wallpaper`：那是默认值，删掉就不在 Dock 的偏好里留痕迹。键里是别的值时，Dock 按模糊壁纸处理，开关也显示模糊壁纸。
- **键名与取值只定义一处**：放进不依赖任何东西的 `LaunchpadAwakenerShared`（同退回开关的路径一样），App 与 payload 都从这里取。界面层的 `SpringboardBackground.Style` 改为指向它。
- **AppCore 加一个控制器**，形状照 `KillSwitchController`：`@Observable`，每次刷新从偏好读回，写失败记进错误区。它用的偏好对象可以注入，单元测试用临时的偏好域，绝不碰开发机上真的 `com.apple.dock`。

没有询问就采用的假设：

- 只做两种背景的切换。Dock 的三种玻璃（`springboard-glass-variant` 的 0、2、4）仍只能在终端里改。
- 在 macOS 26 上不把「Glass」置灰：判断要靠 payload 回报玻璃能不能建，得改 payload 通道的回报类型；先用悬停提示说明。
- 独立版不加这个开关：它没有 Dock 的玻璃，选了也显示模糊壁纸。

## 决策日志

| 日期 | 决定 | 理由 |
|------|------|------|
| 2026-11-09 | 开关读写 Dock 的偏好域，不经 payload 通道 | Dock 每次打开都重新读这个键，经偏好改不需要 payload 在线，也与终端里的 `defaults write` 等价 |
| 2026-11-09 | 用户批准，按方案实现，三条假设照旧 | 玻璃样式、26 上置灰、独立版的开关都不做 |
| 2026-11-09 | 实现完成：`LaunchpadBackground` 放进 `LaunchpadAwakenerShared`，界面层的 `SpringboardBackground.Style` 改成它的别名；AppCore 加 `LaunchpadBackgroundController`；窗口的 Launchpad 一节加两段选择器，错误区加一行。全部测试通过，`RunScript.sh` 构建的 daemon 与 payload 带 arm64e 切片 | 与方案一致 |
| 2026-11-09 | 单元测试共用一个固定的测试偏好域，整组串行 | 删掉偏好域仍会在 `~/Library/Preferences` 留一个空文件，每个测试各取新域名会让每次运行多留几个文件 |
| 2026-11-09 | 文档判断：更新控制面板实现说明（结构表、关键决策、验证）与 Launchpad 复刻实现说明里讲背景的两处；不需要使用指南，没有调用方要遵守的契约；没有新术语 | |
| 2026-11-09 | 玻璃改成只透壁纸：打开时同样截壁纸，不加滤镜垫在玻璃下面，玻璃里的 backdrop 关掉 `windowServerAware`，只采样这张壁纸；玻璃建不出来时退回 15 的模糊壁纸，不再用会透出窗口的替代模糊。用户批准 | 用户在开发机上试了开关，嫌玻璃把后面的 App 窗口透出来难看，要 Dock 栏那种只透壁纸的玻璃 |
| 2026-11-09 | 放弃整个功能，代码、测试与实现说明的改动全部撤回；状态改为 Rejected。背景仍是 15 的模糊壁纸，`springboard-background` 设为 `glass` 的旧选项保持原样 | 用户在开发机上看过两版玻璃：透出 App 窗口的，和只透壁纸的。铺满全屏的 Dock 玻璃两版都不好看，不值得在控制面板里给一个开关 |
| 2026-11-09 | 以 Rejected 状态归档进 `main`，编号 0004 | 被否决的提案也留档，记下当初为什么没走这条路 |
