# Draft - SIP 没关时引导用户改用独立版，并一键安装

- **状态**: In Progress
- **创建日期**: 2026-11-10
- **最后更新**: 2026-11-10
- **实现分支**: `feature/system-integrity-protection-guide`

## 摘要

注入版要把 payload 注入 Dock，只有关掉系统完整性保护（SIP）才做得到。SIP 没关时，它现在照样去装 daemon、去注入，再在横幅上报一串用户看不懂的失败。改为启动时先读 SIP 的实际配置：关了照旧走注入；没关就不碰注入相关的任何东西，横幅改为说明原因，引导用户改用不需要关 SIP 的独立版，并能一键安装、打开它。

## 方案

- **判断**：`LaunchpadAwakenerAppCore` 新增 `SystemIntegrityProtectionConfiguration`，经 `libsystem_kernel` 导出的 `csr_get_active_config` 读内核正在执行的配置。「关了」指 `csrutil disable` 写入的那组标志都在（`isDisabled`）；`csrutil enable --without …` 这类部分关闭算没关。读不出来时按「关了」处理，照旧走注入，失败由现有横幅报告。
- **没关时**：
  - 不登记 daemon（不会叫用户去「登录项」批准），不登记输入法辅助进程，不开自动注入，启动流程直接停在新的状态上。
  - 横幅的第一条原因是「系统完整性保护开着」：说明注入版要关 SIP，独立版不用。按钮在独立版没装时是「Install Launchpad」，装了是「Open Launchpad」。
  - 表单里注入相关的各节隐藏；菜单栏菜单的第一行跟着横幅走。
- **一键安装**：
  - 构建注入版时，同一个 scheme 顺带编出独立版，压成 `Launchpad.zip` 放进注入版的 `Contents/Resources`。直接放 `.app` 有被 LaunchServices 与 Spotlight 当成又一个 Launchpad 的风险。
  - 按钮把它解到 `/Applications/Launchpad.app`（不可写时退到 `~/Applications`），再打开它。
  - 「装了没有」按独立版的 bundle ID 向 LaunchServices 查。
- **关了时**：一切照旧。
- **测试**：两台测试机的 SIP 都关着，开发构建加启动参数 `--assume-system-integrity-protection-enabled`，用来走「没关」那条路。单元测试覆盖标志判断、横幅顺序与安装（解到临时目录、识别已装）。
- **不做**：已装旧版独立版时的更新；运行中 SIP 状态的变化（改 SIP 要重启，App 下次启动时重读）。
- **文档**：控制面板实现说明，`CLAUDE.md` 的「运行前提」与构建两节，术语表（有新词时）。

落地步骤（每步各自构建、测试通过）：

1. ✅ SIP 判断：`SystemIntegrityProtectionConfiguration` 与它的单元测试。
2. ✅ 独立版的安装：找到包里的 `Launchpad.zip`、识别已装的独立版、解压到目标目录、打开，以及单元测试。
3. ✅ 横幅与启动流程：就绪判断的新原因与两个按钮、SIP 没关时跳过注入相关的启动步骤、表单隐藏注入各节、开发构建的启动参数。
4. ✅ 工程：注入版依赖独立版 target，构建时把它压进 `Contents/Resources/Launchpad.zip`；`RunScript.sh` 构建后核对包里有它。
5. ✅ 文档同步。

## 决策日志

| 日期 | 决定 | 理由 |
|------|------|------|
| 2026-11-10 | Created as Draft | 用户要求注入版先判断 SIP：关了照旧注入，没关就引导改用独立版，并帮用户一键安装 |
| 2026-11-10 | 两个 App 仍然分开，注入版只负责判断与安装 | 0002 已否决把两种模式并进同一个 App；这次只加引导，不推翻那个决定 |
| 2026-11-10 | 安装包嵌进注入版，不从 GitHub Release 下载 | 用户选定。不用联网、版本总是匹配；仓库目前没有任何 Release，下载还得先建发布流程 |
| 2026-11-10 | 用户批准，开始实现；补上落地步骤 | 实现放在 `feature/system-integrity-protection-guide` |
| 2026-11-10 | SIP 没关时，表单仍留「登录时启动」一行 | SIP 关着时登记过开机启动、后来又打开 SIP 的，每次登录都会起一个什么也做不了的菜单栏 App，要能在这里关掉 |
| 2026-11-10 | 「应用程序」里已有同名的别的 App 时报错，不覆盖；已有独立版时保留原样 | 覆盖别人的 App 不可撤销；已装的独立版可能正在运行 |
| 2026-11-10 | 已装的独立版先问 LaunchServices，再看两个「应用程序」文件夹；读 `Info.plist` 而不用 `Bundle` | 刚拷进去的 App 还没被登记；`Bundle` 按路径缓存，删掉的 App 它还会报在 |
| 2026-11-10 | 压缩独立版的构建阶段每次都跑（`alwaysOutOfDate`） | 与工程里另两个生成阶段一致；以目录为输入时 Xcode 只看目录本身的修改时间，独立版改了也可能不重压 |
| 2026-11-10 | 实现完成，待用户看过后收尾 | 开发机上全部单元测试通过（新增 14 个），`RunScript.sh` 构建通过、三个切片都在，包里的 `Launchpad.zip` 约 14 MB，解出来签名有效、bundle ID 对得上。没有在真机上看过：测试机的 SIP 都关着，要用启动参数走「没关」那条路。文档：控制面板与独立版的实现说明、`CLAUDE.md` 已同步；没有新术语 |
