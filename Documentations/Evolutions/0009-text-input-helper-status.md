# 0009 - 在控制面板里显示输入法辅助进程，并自动换掉旧版本

- **状态**: Implemented
- **创建日期**: 2026-11-10
- **最后更新**: 2026-11-10
- **实现分支**: `feature/text-input-helper-status`，叠在 `feature/text-input-swift-xpc` 上
- **配套文档**: 同步更新了[控制面板实现说明](../Internal/ControlPanel.md)（「输入法辅助进程看进程表，旧版本自动换掉」与代码地图）、项目 `CLAUDE.md`「改文本输入辅助进程」一条、术语表的「Text input helper」

## 摘要

App 有两个后台进程：以 root 运行、负责注入的特权 daemon，和以用户身份常驻、替 Launchpad 托管搜索框与改名框的输入法辅助进程（LaunchAgent `LaunchpadAwakenerTextInput`）。控制面板对 daemon 显示状态、能卸载与安装，版本不符时 App 还会自动重装；对辅助进程却只显示「注册了没有」，看不出它在不在运行、是不是旧版本，也没法重启它。重装 daemon 不会碰辅助进程，所以换了新构建之后，旧的辅助进程会一直跑下去，直到注销或手动 `pkill`。[0008 文本输入通道改用系统的 Swift XPC 接口](0008-text-input-swift-xpc.md) 之后，旧辅助进程读不懂新消息，输入法随之失效，用户在开发机上就这样踩到过。这次让面板显示辅助进程的运行状态与版本，加一个「重启」按钮，并让 App 启动时自动换掉旧版本。

## 方案

### 认出辅助进程与它是不是旧版

- **找进程**：照 `TargetProcessMonitor` 的做法列出所有进程（`proc_listpids` 加 `proc_pidpath`），取可执行文件名为 `LaunchpadAwakenerTextInput`、所在 `.app` 的 bundle ID 等于 `TextInputServiceIdentity.machServiceName` 的那些。按 bundle ID 认，Debug 与 Release 的辅助进程就不会混在一起。启动时间用 `proc_pidinfo` 的 `PROC_PIDTBSDINFO` 读。
- **判状态**（纯函数，能单测），三种：
  - **没在运行**：launchd 会在下次打开 Launchpad 时拉起它。
  - **在运行，是当前版本**：可执行文件就是这个 App 包里的那份，而且进程启动之后文件没被换过。「被换过」比的是文件的状态变更时间（ctime）与进程启动时间：构建、拷贝、改名都会更新 ctime，而 `rsync -a` 会把修改时间拷成源文件的，不能用来比。路径按 `realpath` 解析，与 `proc_pidpath` 报的一致。
  - **在运行，是旧版本**，分两种：
    - 这个 App 包里的那份文件在进程启动之后被换过（重新构建、覆盖安装）；
    - 运行的是别处的一份（另一个构建目录、另一个安装位置）。

### 面板与自动处理

- 「Input method helper」一行的文字与色点照现有的状态行（`StatusLine`）来：注册状态不是「已启用」时照旧显示注册状态；已启用时显示上面三种之一。旧版本是提醒色，文字说明是哪一种旧版。
- 加一个「Restart」按钮，辅助进程在运行时显示。按下给它发 `SIGTERM`（复用 `ProcessTermination`），之后由 launchd 在下次打开 Launchpad 时拉起这个 App 包里的那份。重启不需要注销、重新注册 LaunchAgent。
- **App 启动时自动处理**：发现「这个 App 包里的那份被换过」就自动重启它，与 daemon 版本不符时自动重装是同一个思路。「运行的是别处的一份」不自动重启，只在面板上提示，由用户按按钮：同一个服务名可能被另一份构建注册着，自动处理可能两边来回抢。
- 面板每次变为活跃时刷新这一行，与注册状态的刷新放在一起。

### 没有询问就采用的假设

- 重启只发 `SIGTERM`，不调 `launchctl kickstart`：辅助进程的 LaunchAgent 没设 `KeepAlive`，退出后 launchd 不会马上重启它，等 Dock 下次连它的 Mach 服务时才拉起。
- 用户正在 Launchpad 里打字时按了重启，这一次退回本地编辑，下一次打开就恢复，不另做保护。
- 不改辅助进程与 payload，只改 App（`LaunchpadAwakenerAppCore` 与 `LaunchpadAwakenerAppUI`），不需要重启 Dock。

### 测试与验证

- 判状态的纯函数：没在运行、当前版本、文件被换过、别处的一份，以及多个进程同时在时取哪个。
- 面板文字与色点（`StatusLineTests` 里同样的写法）。
- 找进程与重启走真实进程：测试里在临时目录搭一个同样结构的 `.app`，放进 `/bin/sleep` 的副本并写好 bundle ID，启动后断言能找到它、读到的启动时间对；改一下文件的修改时间，断言判成旧版；重启后进程退出。
- 开发机上跑全部单元测试与 `RunScript.sh` 构建。面板的样子要看界面，属于交互验证，用户提出才做。

### 落地步骤

1. ✅ **认出辅助进程**：`AppCore` 里找进程、读启动时间、判状态的类型，加纯函数测试和真实进程测试。
2. ✅ **重启与自动处理**：`TextInputAgentController` 持有辅助进程状态，提供重启，App 启动时自动换掉被换过的那份；状态行文字与色点加测试。
3. ✅ **面板**：「Input method helper」一行显示新的状态行，加「Restart」按钮。
4. ✅ **文档与验证**：控制面板实现说明与 `CLAUDE.md`，全部单元测试与 `RunScript.sh` 构建。

### 文档

同一批次更新[控制面板实现说明](../Internal/ControlPanel.md)里辅助进程那一行，以及项目 `CLAUDE.md`「改文本输入辅助进程」一条：App 启动时会自动换掉旧版，面板里也能手动重启。

## 后续

- 面板上这一行和「Restart」按钮的样子没有看过，属于交互验证。

## 决策日志

| 日期 | 决定 | 理由 |
|------|------|------|
| 2026-11-10 | Created as Draft | 换了新构建后旧的输入法辅助进程一直在跑，面板上看不出来，重装 daemon 也不管它；用户要求把它显示出来 |
| 2026-11-10 | 显示运行状态与是否旧版、加「重启」按钮、App 启动时自动换掉旧版 | 用户在三种范围里选定这一种；另两种是照 daemon 做卸载与安装、只显示状态 |
| 2026-11-10 | 用户批准，开始实现 | — |
| 2026-11-10 | 分支叠在 `feature/text-input-swift-xpc` 上，提案随功能分支的第一个提交走、不先提交到 main | 两边都改 `CLAUDE.md`「改文本输入辅助进程」那一行和两份索引，分头切会冲突；用户正要把 main 快进到那条分支做测试，先往 main 提交会让快进失败 |
| 2026-11-10 | 「被换过」比文件的状态变更时间（ctime），不比修改时间 | `rsync -a` 部署会把修改时间拷成源文件的，进程若在构建之后、部署之前启动，比修改时间就认不出它是旧的；ctime 只有内核能设 |
| 2026-11-10 | 路径用 `realpath` 解析，不用 `URL.resolvingSymlinksInPath()` | 后者把 `/private/var` 写回 `/var`，与 `proc_pidpath` 报的路径对不上，测试里的临时目录正好踩到 |
| 2026-11-10 | 顺带修 `TargetProcessMonitorTests` 两个 async 测试结束子进程的方式 | 它们在 `await` 之后调用阻塞的 `waitUntilExit()`，换到别的线程后收不到退出通知；新加的真实进程测试与它并行时，20 次里卡死 2 次（采样确认卡在 `waitUntilExit`），基线 20 次 0 次。改为异步轮询子进程被收走，修复后 30 次 0 次。不改就无法加真实进程测试，所以放在这个分支 |
| 2026-11-10 | 实现完成，待用户看过后收尾 | 全部单元测试通过（App 核心测试新增 23 个），`RunScript.sh` 构建通过、三个切片都在；面板的样子属于交互验证，没有看 |
| 2026-11-10 | 用户收尾，状态改 Implemented，编号 0009 | 全部单元测试与 `RunScript.sh` 构建通过；控制面板实现说明已同步，术语表的「Text input helper」补上出处，没有新术语 |
