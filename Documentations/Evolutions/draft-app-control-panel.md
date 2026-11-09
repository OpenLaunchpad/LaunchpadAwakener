# Draft - 照 DockIconOverride 重做注入版 App 的控制面板

- **状态**: In Progress
- **创建日期**: 2026-11-09
- **最后更新**: 2026-11-09
- **实现分支 / PR**: `feature/app-control-panel`
- **配套文档**: [实现说明](../Internal/ControlPanel.md)

## 摘要

注入版 App（`LaunchpadAwakener.app`）的窗口只有三行状态和几个按钮：看不出现在到底能不能用，App 重开后不知道 Dock 里已经有 payload，daemon 坏了不会自己修，也没有「重启 Dock」。同一套脚手架生成的姊妹项目 DockIconOverride 已经把这些都做过一遍、在真机上踩过坑。本提案把它 App 端的功能整套搬过来，界面照它的单窗口分组表单重画，再加上 Launchpad 自己的三项状态：当前 Dock 构建是否受支持、退回开关、文本输入辅助进程。

## 方案

### 从 DockIconOverride 搬过来的

- **状态横幅**：窗口顶部一句话说清现在能不能用、下一步做什么；启动流程分阶段（检查 daemon → 找已在的 payload → 注入），停在哪一步就写哪一步。
- **开机启动**单独一个开关，状态每次从 `SMAppService` 读回；在系统设置里被关掉时说明并给跳转按钮；Debug 构建提示登录项指向 DerivedData。
- **daemon 自愈**：连不上或版本不对就重装（`ensureDaemonUsable`，取代 `reconcileVersion`），两次重装至少隔 60 秒（`RepairCooldown`）；连接过期时重连并重试一次。
- **注入**：进程监视器每一轮都报告在跑的 Dock，之前注入失败的会在 15 秒退避后重试；每次注入前先确保 daemon 可用；注入结果标明是用户点的还是自动的；结果说的进程都退出后自动撤掉。
- **重启 Dock**：先忘掉旧 Dock，向它发 `SIGTERM`，等新 Dock 出现后注入它，不依赖「自动注入」开关。
- **payload 通道**：注入前 App 先在 daemon 里登记自己的端点，payload 起来后连回来、把自己的监听端点登记进 daemon 的注册表；App 重开时读注册表连回去。App 经它问 payload 的状态。daemon 因此新增 `InjectedEndpointRegistryService`，`daemonVersion` 升到 1.1.0。
- **状态刷新**：窗口开着时每 3 秒核对一次：宿主进程还在不在（`kill(pid, 0)`）、payload 还答不答。payload 不答只断通道、不撤注入记录（DockIconOverride 踩过的注入死循环）。
- **菜单栏 App**：`LSUIElement`，窗口开着时是普通 App、关掉后只留菜单栏图标；App 已在运行时再打开它会重新弹出窗口；开机启动打开时启动不弹窗口；不恢复上次的窗口。
- **错误区**：开机启动、注入、文本输入辅助进程、退回开关的错误一起列出，不只显示第一条。
- **回归测试**：搬它的 AppCore 测试（重装冷却、注入死循环、状态过期、重启 Dock、进程监视器）。

### Launchpad 自己加的

- **Dock 构建**：payload 回报装 hook 的结果——装上几个、构建不认识、方法对不上、安装失败——以及构建档案里的 Dock 版本与系统版本。构建不受支持时横幅直接说 Dock 还在打开系统的 Apps。
- **退回开关**：开关替用户建或删 `/tmp/LaunchpadAwakener.disabled`，立即生效，重启后自动失效。路径常量从 `SpringboardCore` 挪到 `LaunchpadAwakenerShared`，两边共用一处。
- **文本输入辅助进程**：显示 LaunchAgent 的登记状态；在登录项里被关掉时给跳转按钮；没登记时可以登记。

### 和 DockIconOverride 不同的地方

- **payload 是不是旧的，看镜像 UUID，不看手写版本号**。payload 回报自己镜像的 `LC_UUID`，App 读包里那份 payload 每个切片的 UUID，对不上就是旧的。这边 payload 改得勤，手写的版本号一定会忘了递增。
- **保留这边已有的闪退保护**：注入后 15 秒内退出、连续三次，自动注入就关掉。抽成可测的 `QuickExitGuard`；用户自己点「重启 Dock」退出的那个 Dock 不计入。
- **开机启动默认打开**：第一次注入成功时，用户没表过态就登记一次；之后以用户的开关为准。原来的做法是开机启动跟着「自动注入」开关一起开关。
- **状态横幅的判断放进 AppCore**（`ControlPanelReadiness`），界面只负责配文字和颜色，这样优先级能单测。

### 落地步骤

1. ✅ AppCore 与 payload 通道：搬冷却、存活检查、刷新判断、daemon 自愈、监视器每轮回报、注入协调器重写（含闪退保护、重启 Dock）、开机启动 / 文本输入辅助进程 / 退回开关的控制器、启动进度、横幅判断；新模块 `LaunchpadAwakenerPayloadInterface`、payload 的 `PayloadPeer`、daemon 的注册表服务、AppCore 的 `PayloadChannel` 与 UUID 比对；新建 `LaunchpadAwakenerAppCoreTests`。
2. ✅ App 外壳：`ApplicationDelegate` 与启动流程、`LSUIElement`、窗口各区、菜单栏。
3. ✅ 文档：[实现说明](../Internal/ControlPanel.md)、术语表、`CLAUDE.md` 的模块表与「改完代码之后要做什么」。

### 后续项

- 开机启动打开时，从 Finder 手动打开一个没在运行的 App 也不弹窗口。要分辨启动来源得读登录项启动带的 Apple Event，先在测试机上实测 SwiftUI 何时读 `defaultLaunchBehavior`（已裁决清单 2026-11-09）。
- 快速切换用户时，监视器也会注入别的用户的 Dock（改之前就这样）。要不要只注入当前用户的 Dock，另行决定。

### 没问就定下的假设

- 独立版「Launchpad」不动。
- 界面文字沿用英文，和现有 App 一致。
- 验证做到：本机编译、单元测试，部署到测试 MacBook 看日志；截图与点击等用户另提。

## 决策日志

| 日期 | 决定 | 理由 |
|------|------|------|
| 2026-11-09 | Created as Draft | 用户要把注入版 App 做得好看一点，DockIconOverride 有的功能都要有 |
| 2026-11-09 | 用户批准：单窗口分组表单；三项 Launchpad 状态都加；写完提案直接开工 | 一轮澄清提问的答案 |
| 2026-11-09 | 开始实现 | — |
| 2026-11-09 | payload 是否过期按镜像 UUID 判断，不用手写版本号 | 这边 payload 改动频繁，手写版本号会忘了递增，「过期」提示就失灵了 |
| 2026-11-09 | 开机启动改成独立开关，第一次注入成功时默认登记一次 | 照 DockIconOverride 拆开；默认打开保住这边「重启后自己回来」的原有行为 |
| 2026-11-09 | 重启 Dock 改用向 Dock 进程发 `SIGTERM`，不调用 `killall` | 进程号已经由监视器拿到，不必再起一个子进程 |
| 2026-11-09 | 启动时不弹窗口的条件，从「daemon 已启用」改成「开机启动已打开」 | 照 DockIconOverride：开机启动关着时，这次启动一定是用户手动开的，就该看到窗口 |
| 2026-11-09 | AppCore 与 payload 通道合成一个落地步骤 | 协调器重写时两者分不开，分开就有一步编不过 |
| 2026-11-09 | 横幅在有一键可做的下一步时带一个按钮 | 提案外的小改动：横幅已经说了下一步，把那一步做成按钮，不必再去下面找 |
| 2026-11-09 | 匹配 Dock 改用完整路径，不再只比可执行文件名 | 照 DockIconOverride：别的进程碰巧也叫 Dock 时不会被注入 |
| 2026-11-09 | 文本输入辅助进程在 App 启动时就登记，不再等 daemon 可用且自动注入打开 | 登记它不需要 daemon，launchd 只在 payload 连它时才启动它；这样 daemon 稍后才获批准时也不会漏登记 |
| 2026-11-09 | 自审与测试机验证发现 8 条要修：监视器抢在找回 Dock 之前注入、同时检查 daemon 互相挡、握手等满 5 秒、状态请求不限时、重启时注入正在退出的 Dock、给别的用户的 Dock 发信号报错、几处通道没关、启动停下后不再重试；另 2 条登记为不修 | 能抽出纯函数的都先写了测试、确认修前失败；其余几处在 XPC 与真实 Dock 之间，靠测试机日志验证 |
