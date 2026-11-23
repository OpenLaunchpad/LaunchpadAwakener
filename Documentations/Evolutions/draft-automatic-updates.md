# Draft - 两个 App 用 Sparkle 自动更新

- **状态**: In Progress
- **作者**: JH
- **创建日期**: 2026-11-23
- **最后更新**: 2026-11-23
- **所属愿景**: 无
- **关联提案**: [0002 不注入 Dock 的独立版 Launchpad](0002-standalone-launchpad.md)、[0003 照 DockIconOverride 重做注入版 App 的控制面板](0003-app-control-panel.md)、[0010 SIP 没关时引导用户改用独立版，并一键安装](0010-system-integrity-protection-guide.md)
- **实现分支 / PR**: `feature/automatic-updates`
- **配套文档**: 实现说明 [自动更新](../Internal/AutomaticUpdates.md)
- **网页版**: 同目录同名的 `.html`

## 摘要

注入版 LaunchpadAwakener 与独立版 Launchpad 各自接上 [Sparkle](https://sparkle-project.org) 2，每天检查一次更新，有新版本时弹 Sparkle 的标准窗口、用户确认后安装；菜单里加「Check for Updates…」，设置里加「自动检查更新」开关。两个 App 各有一个更新源（appcast），都作为附件挂在每次的 GitHub Release 上，由 CI 在发布时生成并用 EdDSA 签名；独立版的 zip 从注入版包里取出、单独上传。两个 App 都是常驻后台的（菜单栏 App、收起后藏起来的全屏 App），所以定时检查到的更新先以「提醒」出现：注入版在菜单栏菜单里，独立版在 Dock 图标的角标与菜单里。注入版更新后第一次启动时，如果 Dock 里跑的还是旧 payload，自动重启一次 Dock；独立版被 Sparkle 重新打开时不盖住屏幕。

## 动机

现在两个 App 都没有任何更新途径：

- 用户只能自己去 GitHub Releases 看有没有新版本，下载 zip 手动替换。1.0（2026-11-12）、1.1（2026-11-22）、1.1.1（2026-11-23）十一天里发了三个版本，修的都是用户一用就会碰到的问题（拖动排序、文件夹开合、删除时的空位），没有更新途径就到不了已经装了的人手里。
- 独立版更新得更难：它只装在注入版包里的 `Contents/Resources/Launchpad.zip` 里，控制面板「Install Launchpad」把它解到「应用程序」，已经装过的就原样保留（`StandaloneLaunchpadInstaller.install()`，`LaunchpadAwakenerPackage/Sources/LaunchpadAwakenerAppCore/StandaloneLaunchpadInstaller.swift`：「A copy of it already there is kept as it is」）。手动换掉注入版之后，独立版仍停在旧版，界面上也没有任何提示。
- SIP 开着的用户主要用独立版，注入版只用来装它，不一定开着（SIP 开着时注入版连开机启动都不默认打开）。只给注入版接更新，这些用户的独立版就永远收不到更新。
- 换了注入版之后，Dock 里已经加载的 payload 卸不掉，要重启 Dock 才换成新的；现在只在控制面板横幅里提示「older build」、等用户自己点「Restart Dock」（`ControlPanelReadiness` 的 `.stalePayload`）。自动更新之后再让用户补这一步，等于更新只做了一半。

## 前期调研

### 现状代码

- **注入版的启动**：`ApplicationDelegate.applicationDidFinishLaunching(_:)`（`LaunchpadAwakenerPackage/Sources/LaunchpadAwakenerAppUI/Application/ApplicationDelegate.swift:68`）建主菜单、菜单栏项，SIP 开着时只弹控制面板就返回；否则开自动注入、登记输入法辅助进程（并结束可执行文件被换掉的旧辅助进程 `restartHelperIfReplaced()`），不是登录时启动就弹控制面板，最后跑 `runLaunchSequence()`：确认 daemon 可用 → `reconnectToResidentPayloads()` → 自动注入 → `.ready`。
- **旧 payload 的判断**：`PayloadInjectionCoordinator.hasStalePayload`（`PayloadInjectionCoordinator.swift:340`）——Dock 里驻留的 payload 的镜像 UUID 不是包里 payload 的任何一个切片就算旧。`restartTargets()`（同文件 `:610`）是「Restart Dock」按钮的实现：结束 Dock、等 launchd 拉起新的、再注入。
- **daemon 与辅助进程**：daemon 版本号不一致时 App 会自动注销重装（`InjectionServiceIdentity.daemonVersion`，见项目 `CLAUDE.md`「改完代码之后要做什么」）；输入法辅助进程的可执行文件被换过，App 启动时会结束它。整包被替换（Sparkle 更新就是这样）时这两条都照常生效，本提案不改它们。
- **菜单**：两个 App 的主菜单都由 `ApplicationMainMenu.make(applicationName:settingsItem:windowItems:)`（`LaunchpadAwakenerPackage/Sources/LaunchpadAwakenerSharedUI/ApplicationMainMenu.swift:16`）建；注入版的菜单栏菜单在 `StatusItemController`（`AppUI/MenuBar/StatusItemController.swift`），SIP 开着与关着各一套条目；独立版的 Dock 菜单是 `StandaloneLaunchpadApplicationDelegate.applicationDockMenu(_:)`（`StandaloneCore/StandaloneLaunchpad.swift:183`），现在只有「Settings…」。
- **设置**：注入版控制面板的「General」节（`ControlPanelViewController.swift:213`、`:223`，SIP 开着时只有「Launch at login」一行）；独立版的设置窗口 `StandaloneSettings`（两行：快捷键、Open at Login）。
- **独立版的启动**：`applicationDidFinishLaunching(_:)`（`StandaloneLaunchpad.swift:139`）不是登录时启动就 `show(reason: "launched")`，盖住整块屏幕。界面收起后 `NSApp.hide(nil)` 把整个 App 藏起来（见 `Documentations/Internal/StandaloneLaunchpad.md`「焦点」一段），窗口层级 27，高于菜单栏与 Dock。
- **Info.plist**：注入版有 `LaunchpadAwakener/Info.plist`（只有 `LSUIElement`），其余靠 `GENERATE_INFOPLIST_FILE` 生成；独立版没有 Info.plist 文件，全靠生成。两个 App 都没开沙盒（`ENABLE_APP_SANDBOX = NO`），都开着硬化运行时。
- **嵌入独立版**：「Embed Standalone Launchpad」构建阶段（`LaunchpadAwakener.xcodeproj/project.pbxproj` 里的 `PBXShellScriptBuildPhase`）把独立版拷进临时目录，由内向外重签——先签框架 `Resources` 里带可执行文件的 bundle、再签框架、最后签 App——再压成 `Launchpad.zip`。它只处理框架 `Resources/*.bundle`，不处理框架里别的嵌套代码。
- **发布**：`Release.zsh` 用 AppRelease 1.0.0，`release_publishers=(github-release)`，没设 `release_notes_path`，发布说明在 Release 建好后用 `gh release edit` 补；钩子 `release_verify_archive` / `release_verify_export` 核对切片、plist、嵌入的独立版与每个 Mach-O 的 Developer ID 签名和时间戳。`.github/workflows/Release.yml` 推 `v*` tag 时完整发布，手动运行时只跑到 zip。

### 上游能力

- **Sparkle 2.10.1**（2026-10-25，`https://github.com/sparkle-project/Sparkle`，支持 SwiftPM，二进制 XCFramework）。
  - `SPUStandardUpdaterController(startingUpdater:updaterDelegate:userDriverDelegate:)`；`SPUUpdater` 的 `automaticallyChecksForUpdates`、`canCheckForUpdates`（KVO）、`checkForUpdates()`。
  - 后台 App 的「温和提醒」（gentle reminders，`Sparkle/SPUStandardUserDriverDelegate.h`）：`supportsGentleScheduledUpdateReminders`；`standardUserDriverShouldHandleShowingScheduledUpdate(_:andInImmediateFocus:)` 返回 `NO` 时由 App 自己提醒；`standardUserDriverWillHandleShowingUpdate(_:forUpdate:state:)`；`standardUserDriverDidReceiveUserAttention(forUpdate:)`；`standardUserDriverWillFinishUpdateSession()`。头文件原话：后台 App 在 `immediateFocus` 为 `NO` 时，标准窗口会「立即显示，但在其他 App 后面」。用户主动检查不经过这个询问，总由 Sparkle 显示。
  - `SPUUpdaterDelegate`：`feedURLString(for:)`（覆盖更新源）、`updater(_:willInstallUpdate:)`、`updaterWillRelaunchApplication(_:)`。
  - `generate_appcast`（`generate_appcast/main.swift`）：与压缩包同名的 `.html`、`.md`、`.txt` 当作这一项的发布说明；`--embed-release-notes` 强制嵌进新条目；`--download-url-prefix`；`--ed-key-file`。
  - Info.plist 键：`SUFeedURL`、`SUPublicEDKey`、`SUEnableAutomaticChecks`（设为 `YES` 就不在第二次启动时问用户要不要自动检查）、`SUScheduledCheckInterval`（默认 86400 秒）。
- **AppRelease**（`/Volumes/Repositories/Private/Personal/Scripts/AppRelease`，最新 1.2.0）：
  - `sparkle-appcast` 发布器（`Sources/Publishers/SparkleAppcast.zsh`）用 App 链接的 Sparkle 包里的 `generate_appcast`（`<DerivedData>/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast`），只放这次的 zip 进暂存目录，生成或合并进 `release_appcast_path`，下载地址前缀是这次 Release 的下载地址，预发布版加 `--channel beta`，私钥来自环境变量 `APP_RELEASE_SPARKLE_PRIVATE_KEY`；之后调 `release_deploy_appcast` 钩子把它放上线。
  - 发布顺序固定（`Sources/Publishers/Publish.zsh`）：tag → GitHub Release（上传全部产物）→ appcast → 部署钩子，所以钩子运行时 Release 已经在了，可以往它上面传附件。
  - 暂存目录里只放 zip，所以**发布说明进不了 appcast**；钩子也拿不到引擎内部的 `generate_appcast` 路径与私钥文件（都是下划线开头的内部变量）。
  - `release_after_product` 钩子在 zip 做好后运行，可以用 `app_release_add_product` 加产物（会随 Release 上传）。
- **前人的做法**：LyricsX（`/Volumes/Repositories/Private/Org/MxIris-LyricsX-Project/LyricsX/Release.zsh`）用同一个发布器，生成单条目的 feed，再由 `release_deploy_appcast` 用自己的脚本把条目插进两个仓库里的 `appcast.xml` 并推送；发布说明事先按版本写在 `ReleaseNotes/` 里，`release_preflight` 在构建前检查它们在。

### 推测，待验证

- **嵌在 zip 里的独立版能不能单独装订公证票据**：公证服务会检查 App 资源里的 zip（项目 `CLAUDE.md`「发布」一节），推测它把里面代码的 cdhash 也登记了，`xcrun stapler staple` 就能对取出来的独立版装订。第 5 步的演练里验证；不行就由钩子把独立版的 zip 单独提交公证（CI 里有 App Store Connect 的密钥）。
- **导出会不会重签 Sparkle 的嵌套代码**（`Autoupdate`、`Updater.app`、两个 XPC 服务）：项目里的注释说导出「re-signs every piece of nested code」，`release_verify_export` 的逐个 Mach-O 检查会给出答案。
- **Sparkle 换掉整个注入版之后，后台任务管理会不会再要求批准 daemon**：同一路径、同一团队签名，推测不会；测试机上验证，结论写进实现说明。

## 提议方案

1. **两个 App 都接 Sparkle**，放进新模块 `LaunchpadAwakenerUpdating`：一个 `ApplicationUpdater` 包住 Sparkle 的标准 updater，两个 App 只是用法不同。
   - 更新源：注入版 `https://github.com/OpenLaunchpad/LaunchpadAwakener/releases/latest/download/LaunchpadAwakenerAppcast.xml`，独立版同一处的 `LaunchpadAppcast.xml`。`latest` 永远指向最新的正式版，不含预发布版。
   - `SUEnableAutomaticChecks = YES`：默认每天自动检查，不弹「要不要自动检查」的询问；设置里可以关。是否自动下载安装（`SUAutomaticallyUpdate`）保持 Sparkle 的默认（关），用户可在 Sparkle 窗口里勾选。
   - 开发构建没有更新源，updater 不启动、更新相关的菜单项不出现；带启动参数 `-UpdateFeedURL <地址>` 时才启动，专供测试机验证。开发构建的公钥用一把测试密钥，与正式密钥分开。
2. **入口**：两个 App 的 App 菜单在「About」下面加「Check for Updates…」；注入版的菜单栏菜单（SIP 开着、关着两套都加）在「Quit」上面加；独立版的 Dock 菜单加。设置里加「Check for updates automatically」开关和一行「Updates」（当前版本号 + 「Check Now」按钮）。
3. **定时检查到更新时**（温和提醒）：
   - 注入版：Sparkle 自己显示窗口；不在「立即聚焦」时（它会显示在别的 App 后面，而菜单栏 App 没有 Dock 图标可点），菜单栏菜单顶上多一项「Install Update <版本>…」，点了把窗口带到前面。用户看过窗口或这次更新会话结束，这一项就撤掉。
   - 独立版：从不让 Sparkle 自己显示定时检查的结果——App 平时是藏起来的，界面开着时又盖在一切之上，窗口要么看不见、要么被盖住。改为 Dock 图标加角标、Dock 菜单顶上多一项「Install Update <版本>…」、设置窗口的「Updates」一行显示新版本号；用户点了才收起界面、显示 Sparkle 窗口。
4. **更新之后**：
   - 注入版：记下上次启动的构建号（`CFBundleVersion`）。启动时发现构建号变了（Sparkle 更新、手动替换都算），在 `reconnectToResidentPayloads()` 之后若 `hasStalePayload` 为真，调一次 `restartTargets()`。SIP 开着时不注入，不会重启。这次启动如果是 Sparkle 为完成更新重新打开的，控制面板不弹出（与登录时启动一样）。
   - 独立版：Sparkle 重新打开它时不盖住屏幕（`updaterWillRelaunchApplication(_:)` 记一笔，下次启动读一次就清掉），等用户点 Dock 图标。手动打开的照旧显示。
5. **发布**：
   - 先给 AppRelease 加两样（1.3.0）：`sparkle-appcast` 发布器把 Release 的发布说明以 `<zip 名>.md` 放进暂存目录并加 `--embed-release-notes`；公开一个钩子可用的 `app_release_generate_appcast <压缩包> <feed> [<发布说明>]`，用同一个 `generate_appcast`、同一把私钥、同一个下载地址前缀生成另一个 App 的 feed。
   - `Release.zsh` 升到 1.3.0，发布器加 `sparkle-appcast`，`release_appcast_path` 指向本次运行目录里的 `LaunchpadAwakenerAppcast.xml`（每次从空 feed 开始，只有这一版一条）；`release_notes_path='ReleaseNotes/{tag_version}.md'`，发布说明在打 tag 之前写好。
   - `release_after_product`：从导出的 App 里取出 `Launchpad.zip`，解开、装订公证票据、再压成 `Launchpad-<版本>-<构建号>.zip` 加进产物。
   - `release_deploy_appcast`：用 `app_release_generate_appcast` 生成 `LaunchpadAppcast.xml`，把两个 feed 用 `gh release upload --clobber` 传到这次的 Release 上。
   - 「Embed Standalone Launchpad」阶段在签框架之前，先由内向外签 Sparkle 的嵌套代码；`release_verify_export` 加上对两个 App 里 Sparkle 嵌套代码的签名与硬化运行时检查。
   - 生成一对正式的 EdDSA 密钥：公钥写进 Release 配置的 `SUPublicEDKey`，私钥存成仓库的 GitHub secret `SPARKLE_PRIVATE_KEY`，`Release.yml` 把它交给 `APP_RELEASE_SPARKLE_PRIVATE_KEY`。设 secret 前先问用户。
6. **文档**：新写实现说明 `Documentations/Internal/AutomaticUpdates.md`；改项目 `CLAUDE.md` 的结构表与发版步骤、控制面板与独立版的实现说明、README。

### 非目标

- 不做 beta 通道：`latest` 不指向预发布版，预发布版的 feed 也不会被读到。
- 不做增量更新（delta）、分阶段推送、关键更新标记。
- 不保留 feed 的版本历史：每次的 feed 只有最新一版，Sparkle 也只需要它。
- 不让注入版在更新后顺带替换已装的独立版：独立版自己更新。
- 不为已经装了 1.1.1 及更早版本的用户做什么：他们手动换到第一个带 Sparkle 的版本之后，才开始自动更新。
- 不改 daemon 与输入法辅助进程的换新机制。
- 不发系统通知（要先向用户要通知权限）。

## 改动地图

| 文件 / 类型 | 动作 | 改什么 | 为什么 | 步骤 |
|---|---|---|---|---|
| `LaunchpadAwakenerPackage/Package.swift` | 修改 | 依赖 `.package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.1")`；新 target `LaunchpadAwakenerUpdating`（依赖 Sparkle、OSToolbox）；`LaunchpadAwakenerAppUI`、`LaunchpadAwakenerStandaloneCore` 依赖它；新测试 target `LaunchpadAwakenerUpdatingTests` | 两个 App 共用一套更新逻辑；payload、daemon、输入法辅助进程不链接 Sparkle | 1 |
| `Sources/LaunchpadAwakenerUpdating/ApplicationUpdater.swift` · `ApplicationUpdater` | 新增 | `@MainActor @Observable final class`：包住 `SPUStandardUpdaterController`，实现 `SPUUpdaterDelegate` 与 `SPUStandardUserDriverDelegate`，对外给 `canCheckForUpdates`、`automaticallyChecksForUpdates`、`pendingUpdate`、`checkForUpdates()`、`isStarted` | 两个 App 的唯一入口 | 1、2 |
| `Sources/LaunchpadAwakenerUpdating/UpdateFeedResolution.swift` · `UpdateFeedResolution` | 新增 | 由 Info.plist 的 `SUFeedURL` 与开发构建的 `UpdateFeedURL` 覆盖值算出更新源，算不出就不启动 updater | 开发构建不碰正式更新源，测试机上又能指定本地 feed | 1 |
| `Sources/LaunchpadAwakenerUpdating/UpdateReminder.swift` · `UpdateReminder` | 新增 | 纯值状态：定时检查找到的更新是让 Sparkle 显示还是由 App 提醒、提醒什么时候撤掉 | Sparkle 的回调类型（`SPUUserUpdateState`）不能在测试里构造，判断放在能测的值类型里 | 2 |
| `Sources/LaunchpadAwakenerUpdating/UpdateRelaunchRecord.swift` · `UpdateRelaunchRecord` | 新增 | 在 `UserDefaults` 里记「这次是 Sparkle 为完成更新重新打开的」，启动时读一次即清 | 独立版被重新打开时不盖住屏幕；注入版不弹控制面板 | 4 |
| `Sources/LaunchpadAwakenerSharedUI/ApplicationMainMenu.swift` · `ApplicationMainMenu.make` | 修改 | 新参数 `updateItem: NSMenuItem? = nil`，放在「About」下面，后跟分隔线 | Mac App 检查更新的惯常位置 | 2 |
| `Sources/LaunchpadAwakenerAppCore/LaunchedBuildRecord.swift` · `LaunchedBuildRecord` | 新增 | 记上次启动的构建号，`recordLaunch(ofBuild:)` 返回这次是否换了构建 | 判断「更新后第一次启动」，不依赖是谁换的 | 4 |
| `Sources/LaunchpadAwakenerAppCore/DockRestartAfterUpdate.swift` · `DockRestartAfterUpdate` | 新增 | 纯判断：换了构建、允许注入、Dock 里有旧 payload 才重启 | 能单测；逻辑不散在 delegate 里 | 4 |
| `Sources/LaunchpadAwakenerAppUI/Application/ApplicationDelegate.swift` · `ApplicationDelegate` | 修改 | 建 `ApplicationUpdater(scheduledUpdatePresentation: .shownBySparkle)`；把更新菜单项交给主菜单、菜单栏、控制面板；`runLaunchSequence()` 在重连之后按 `DockRestartAfterUpdate` 重启 Dock；被 Sparkle 重新打开时不弹控制面板 | 注入版的接线 | 2、4 |
| `Sources/LaunchpadAwakenerAppUI/MenuBar/StatusItemController.swift` · `StatusItemController` | 修改 | 两套菜单都在「Quit」上面加「Check for Updates…」；有待装的更新时顶上加「Install Update <版本>…」 | 菜单栏 App 的主要入口与提醒位置 | 2 |
| `Sources/LaunchpadAwakenerAppUI/ControlPanel/ControlPanelViewController.swift` · `ControlPanelViewController` | 修改 | 「General」节（含 SIP 开着时那一版）加「Check for updates automatically」开关行与「Updates」行（版本号 + 「Check Now」） | 设置入口 | 3 |
| `Sources/LaunchpadAwakenerStandaloneCore/StandaloneLaunchpad.swift` · `StandaloneLaunchpad`、`StandaloneLaunchpadApplicationDelegate` | 修改 | 建 `ApplicationUpdater(scheduledUpdatePresentation: .remindedByApplication)`；App 菜单与 Dock 菜单加更新项；按 `pendingUpdate` 设 Dock 角标；点「Install Update」先收起界面再显示 Sparkle 窗口；被 Sparkle 重新打开时不 `show` | 独立版的接线 | 2、4 |
| `Sources/LaunchpadAwakenerStandaloneCore/StandaloneSettings.swift` · `StandaloneSettingsViewController` | 修改 | 加「Check for Updates Automatically:」开关与「Updates:」行 | 设置入口 | 3 |
| `Tests/LaunchpadAwakenerUpdatingTests/UpdateFeedResolutionTests.swift` | 新增 | 见第 1 步行为 | | 1 |
| `Tests/LaunchpadAwakenerUpdatingTests/UpdateReminderTests.swift` | 新增 | 见第 2 步行为 | | 2 |
| `Tests/LaunchpadAwakenerUpdatingTests/UpdateRelaunchRecordTests.swift` | 新增 | 见第 4 步行为 | | 4 |
| `Tests/LaunchpadAwakenerAppCoreTests/LaunchedBuildRecordTests.swift`、`DockRestartAfterUpdateTests.swift` | 新增 | 见第 4 步行为 | | 4 |
| `Tests/LaunchpadAwakenerStandaloneCoreTests/StandaloneLaunchShowingTests.swift` | 新增 | 启动时显示与否的判断（登录时启动、被 Sparkle 重新打开、手动打开） | | 4 |
| `LaunchpadAwakener/Info.plist` | 修改 | 加 `SUFeedURL = $(UPDATE_FEED_URL)`、`SUPublicEDKey = $(UPDATE_PUBLIC_ED_KEY)`、`SUEnableAutomaticChecks = YES` | Sparkle 从 Info.plist 读这些；值按配置取 | 1 |
| `LaunchpadAwakenerStandalone/Info.plist` | 新增 | 同上三个键 | 独立版原来没有 Info.plist 文件，生成的 Info.plist 放不了自定义键 | 1 |
| `LaunchpadAwakener.xcodeproj/project.pbxproj` | 修改 | 两个 App target：`UPDATE_FEED_URL`（只在 Release 有值）、`UPDATE_PUBLIC_ED_KEY`（Release 正式公钥，Debug 测试公钥）；独立版设 `INFOPLIST_FILE`；「Embed Standalone Launchpad」先签 Sparkle 的嵌套代码 | 正式与开发构建分开；zip 里的独立版过公证 | 1、5 |
| `Release.zsh` | 修改 | `release_engine_version=1.3.0`；`release_publishers=(github-release sparkle-appcast)`；`release_appcast_path`；`release_notes_path`；新钩子 `release_after_product`、`release_deploy_appcast`；`release_verify_export` 加 Sparkle 嵌套代码的检查 | 发布时生成、签名、上传两个 feed 与独立版 zip | 5 |
| `.github/workflows/Release.yml` | 修改 | `APP_RELEASE_SPARKLE_PRIVATE_KEY: ${{ secrets.SPARKLE_PRIVATE_KEY }}`；第一步检查 secret 在不在 | CI 签 feed；缺了在构建前就停 | 5 |
| `ReleaseNotes/<版本>.md` | 新增（目录） | 每个版本的英文发布说明，打 tag 前写好；已发布的 1.0、1.1、1.1.1 从各自的 Release 补进来 | 同时进 GitHub Release 与 Sparkle 窗口 | 5 |
| `Appcasts/.gitignore` | 新增 | 忽略发布时写进来的 `*.xml` | `release_appcast_path` 的目录在 `target` 段就要存在，CI 上 `build/` 不存在 | 5 |
| `RunScript.sh` | 修改 | 构建后核对两个 App 都带 Sparkle、Info.plist 有更新源与公钥两个键且公钥不空，Release 构建的更新源不空 | 少一个键时构建「通过」、App 却永远不更新 | 1、5 |
| `Tests/LaunchpadAwakenerSharedUITests/ApplicationMainMenuTests.swift` | 修改 | 更新项在「About」下面 | 第 2 步行为 | 2 |
| GitHub secret `SPARKLE_PRIVATE_KEY`（仓库级） | 新增 | 正式 EdDSA 私钥 | CI 签名；设之前问用户 | 5 |
| AppRelease `Sources/Publishers/SparkleAppcast.zsh`、`Sources/Support/Configuration.zsh`、`Sources/Version`、`README.md`、`Documentations/Evolutions/draft-generic-mac-release-engine.md`、`Tests/Target/TestAppcast.zsh`、`Tests/Support/Fakes/generate_appcast` | 修改 / 新增 | 可选变量 `release_appcast_embeds_release_notes`；公开 `app_release_generate_appcast`，发布器也改用它；7 个测试与一个记录参数的假 `generate_appcast`；打 1.3.0 | 另一个仓库，引擎能力 | 5 |
| `Documentations/Internal/AutomaticUpdates.md` | 新增 | 实现说明：更新源放哪、签名与密钥、两个 App 的提醒方式、更新后的 Dock 重启、测试机上怎么验 | 下一任维护者看代码看不出的决定 | 6 |
| `CLAUDE.md` | 修改 | 结构表加 `LaunchpadAwakenerUpdating`；发版步骤加「先写 `ReleaseNotes/<版本>.md`」，删掉事后 `gh release edit` 补说明那一步；记下私钥在哪 | 发版流程变了 | 6 |
| `Documentations/Internal/ControlPanel.md`、`StandaloneLaunchpad.md` | 修改 | 新的设置行、菜单项、提醒 | 同步实现说明 | 6 |
| `README.md` | 修改 | 一句话说明两个 App 会自动检查更新 | 对外可见的变化 | 6 |
| `Documentations/README.md`、`Documentations/Evolutions/README.md` | 修改 | 登记本提案（现在）与实现说明（第 6 步） | 索引 | 0、6 |

## 架构图

模块依赖（改了什么）：

```text
LaunchpadAwakener.app
└─ LaunchpadAwakenerAppUI ~
   ├─ LaunchpadAwakenerAppCore ~          + LaunchedBuildRecord, + DockRestartAfterUpdate
   ├─ LaunchpadAwakenerSharedUI ~         ~ ApplicationMainMenu.make(updateItem:)
   └─ + LaunchpadAwakenerUpdating         + ApplicationUpdater, UpdateReminder,
        └─ + Sparkle (binary, 2.10.1)       UpdateFeedResolution, UpdateRelaunchRecord
Launchpad.app (standalone)
└─ LaunchpadAwakenerStandaloneCore ~
   ├─ LaunchpadAwakenerSharedUI ~
   └─ + LaunchpadAwakenerUpdating
LaunchpadAwakenerPayload / Daemon / TextInput      (unchanged, no Sparkle)
```

发布与更新的数据流：

```text
tag v<version> ─▶ Release.yml ─▶ app-release all --publish   (AppRelease 1.3.0)
  product:  LaunchpadAwakener-<v>-<b>.zip
            + release_after_product: Resources/Launchpad.zip ─▶ unzip ─▶ staple ─▶ Launchpad-<v>-<b>.zip
  publish:  tag ─▶ GitHub Release (both zips, notes from ReleaseNotes/<v>.md)
            ─▶ sparkle-appcast: generate_appcast(main zip + notes) ─▶ LaunchpadAwakenerAppcast.xml
            ─▶ + release_deploy_appcast:
                 app_release_generate_appcast(standalone zip + notes) ─▶ LaunchpadAppcast.xml
                 gh release upload <tag> both feeds --clobber

LaunchpadAwakener.app ─ SUFeedURL ─▶ releases/latest/download/LaunchpadAwakenerAppcast.xml ─▶ zip on that release
Launchpad.app         ─ SUFeedURL ─▶ releases/latest/download/LaunchpadAppcast.xml         ─▶ zip on that release
```

更新之后的启动（注入版）：

```text
SPUUpdater installs ─▶ updater(_:willInstallUpdate:)
                    ─▶ updaterWillRelaunchApplication(_:) ─▶ + UpdateRelaunchRecord.noteRelaunch()
new process: applicationDidFinishLaunching
  ├─ + UpdateRelaunchRecord.takeRelaunchNote()  ─▶ true: control panel stays closed
  ├─ + LaunchedBuildRecord.recordLaunch(ofBuild:) ─▶ isNewBuild
  └─ runLaunchSequence()
       ├─ ensureDaemonUsable()            (daemonVersion check, unchanged)
       ├─ reconnectToResidentPayloads()
       ├─ + DockRestartAfterUpdate.isNeeded(isNewBuild, isInjectionAllowed, hasStalePayload)
       │     └─ true ─▶ injectionCoordinator.restartTargets()   (once)
       └─ injectIntoRunningTargets()
```

## 详细设计

### `LaunchpadAwakenerUpdating`

```swift
import Sparkle

@MainActor
@Observable
public final class ApplicationUpdater {
    /// How an update found by a scheduled check reaches the user. Checks the user starts always show
    /// Sparkle's window at once.
    public enum ScheduledUpdatePresentation: Sendable {
        /// Sparkle shows its window; when it shows it behind other apps, the app adds a reminder too.
        case shownBySparkle
        /// The app only reminds, and Sparkle's window shows once the user asks for it.
        case remindedByApplication
    }

    public let scheduledUpdatePresentation: ScheduledUpdatePresentation
    /// False in a build with no feed or no key: nothing checks, and no update item shows.
    public private(set) var isStarted: Bool
    public private(set) var canCheckForUpdates: Bool
    public var automaticallyChecksForUpdates: Bool { get set }   // Sparkle's own setting
    /// "Version 1.2 (4)", for the settings.
    public let currentVersionDescription: String
    /// The update the app reminds of.
    public var pendingUpdate: PendingUpdate? { get }
    /// Runs just before Sparkle's window shows at the user's request; the standalone app hides its
    /// springboard and unhides itself here.
    public var prepareToShowWindow: (@MainActor () -> Void)?

    public init(
        scheduledUpdatePresentation: ScheduledUpdatePresentation,
        bundle: Bundle = .main,
        defaults: UserDefaults = .standard
    )

    /// Starts checking, when the build has a feed and a key. Once, at launch, before building the menus.
    public func start()

    /// Shows Sparkle's window, checking now or showing the update already found.
    public func checkForUpdates()

    /// The item the menus share: "Check for Updates…", or "Install Update <version>…" while one waits.
    public func makeMenuItem() -> NSMenuItem
}

/// An update waiting for the user, while the app reminds of it. Top level rather than nested in the
/// main-actor class, so that the plain value UpdateReminder can use it.
public struct PendingUpdate: Equatable, Sendable {
    public let displayVersion: String
}
```

调用点：

```swift
// Injected app
let updater = ApplicationUpdater(scheduledUpdatePresentation: .shownBySparkle)
NSApp.mainMenu = ApplicationMainMenu.make(applicationName: "LaunchpadAwakener", updateItem: updater.isStarted ? updater.makeMenuItem() : nil, windowItems: …)

// Standalone app
let updater = ApplicationUpdater(scheduledUpdatePresentation: .remindedByApplication)
observe { NSApp.dockTile.badgeLabel = updater.pendingUpdate == nil ? nil : "1" }
```

- `ApplicationUpdater` 内部持有一个 `SPUStandardUpdaterController`，构造时不启动；`start()` 在算得出更新源、且 Info.plist 的 `SUPublicEDKey` 不空时才 `startUpdater()`，否则只记一条日志。`canCheckForUpdates` 用 KVO 跟着 `SPUUpdater`；`automaticallyChecksForUpdates` 直接读写 Sparkle 的设置。
- 代理对象是一个私有的 `NSObject` 子类（`@MainActor`），把 Sparkle 的回调翻成 `UpdateReminder` 的事件，也是菜单项的目标：它实现 `NSMenuItemValidation`，会校验菜单项的菜单（主菜单、Dock 菜单）每次打开时标题跟着提醒变。Sparkle 的 `SPUUpdaterDelegate` 已是主线程隔离，`SPUStandardUserDriverDelegate` 不是，遵循后者要写 `@preconcurrency`。
- `supportsGentleScheduledUpdateReminders` 恒为 `true`。`standardUserDriverShouldHandleShowingScheduledUpdate(_:andInImmediateFocus:)` 记下 `immediateFocus`，返回 `UpdateReminder.letsSparkleShow(_:immediateFocus:)`：`.shownBySparkle` 恒真，`.remindedByApplication` 恒假。
- `standardUserDriverWillHandleShowingUpdate(_:forUpdate:state:)` 调 `UpdateReminder.updateWillShow(...)`：非用户发起、且（Sparkle 不显示，或显示但不在立即聚焦）时设 `pendingUpdate`。
- `standardUserDriverDidReceiveUserAttention(forUpdate:)` 与 `standardUserDriverWillFinishUpdateSession()` 清掉 `pendingUpdate`。
- `checkForUpdates()` 先调 `prepareToShowWindow`，再 `NSApp.activate()`（注入版是 `LSUIElement`，不激活窗口会在别的 App 后面），最后 `SPUUpdater.checkForUpdates()`；有待装的更新时 Sparkle 直接显示它。
- `feedURLString(for:)` 返回启动时算出的更新源：Info.plist 的，或开发构建里启动参数给的（Sparkle 自己不读后者）。
- `updaterWillRelaunchApplication(_:)`：`UpdateRelaunchRecord(defaults:).noteRelaunch()`。

```swift
public enum UpdateFeedResolution {
    public static let overrideDefaultsKey = "UpdateFeedURL"
    public static let allowsOverride: Bool   // true only in a development build
    /// The feed to check, or nil when there is none: a development build launched without an override.
    public static func feedURL(infoDictionaryValue: String?, overrideValue: String?, allowsOverride: Bool) -> URL?
    public static func feedURL(of bundle: Bundle, defaults: UserDefaults) -> URL?
}

public struct UpdateReminder: Equatable, Sendable {
    public static func letsSparkleShow(_ presentation: ApplicationUpdater.ScheduledUpdatePresentation, immediateFocus: Bool) -> Bool
    public private(set) var pendingUpdate: PendingUpdate?
    public mutating func updateWillShow(displayVersion: String, isUserInitiated: Bool, isShownBySparkle: Bool, isInImmediateFocus: Bool)
    public mutating func userSawUpdate()
    public mutating func sessionEnded()
    /// "Install Update 1.2…" or "Check for Updates…".
    public static func menuItemTitle(for pendingUpdate: PendingUpdate?) -> String
}

public struct UpdateRelaunchRecord {
    public init(defaults: UserDefaults = .standard)
    public func noteRelaunch()
    /// Whether Sparkle relaunched the app to finish an update; reading it clears it.
    public func takeRelaunchNote() -> Bool
}
```

### `LaunchpadAwakenerAppCore`

```swift
public struct LaunchedBuildRecord {
    public init(defaults: UserDefaults = .standard)
    /// Records `build` and returns whether it differs from the build launched last, or none was recorded.
    @discardableResult
    public func recordLaunch(ofBuild build: String) -> Bool
}

public enum DockRestartAfterUpdate {
    public static func isNeeded(isNewBuild: Bool, isInjectionAllowed: Bool, hasStalePayload: Bool) -> Bool
}
```

`ApplicationDelegate` 在 `applicationDidFinishLaunching` 一开头读 `UpdateRelaunchRecord().takeRelaunchNote()`（为真就不弹控制面板），并把 `LaunchedBuildRecord().recordLaunch(ofBuild:)`（构建号取 `Bundle.main` 的 `CFBundleVersion`）存进属性 `isFirstLaunchOfNewBuild`。`runLaunchSequence()` 在 `reconnectToResidentPayloads()` 之后判断一次、随即清掉这个属性，所以序列中途停下（daemon 等批准）时，等它再跑到这里照样判断：

```swift
let restartsDockForNewBuild = DockRestartAfterUpdate.isNeeded(
    isNewBuild: isFirstLaunchOfNewBuild,
    isInjectionAllowed: !isInjectionBlockedBySystemIntegrityProtection,
    hasStalePayload: injectionCoordinator.hasStalePayload
)
isFirstLaunchOfNewBuild = false
if restartsDockForNewBuild {
    #log(.info, "First launch of this build with an older payload in the Dock: restarting the Dock once")
    injectionCoordinator.restartTargets()   // injects into the new Dock by itself
    launchProgress.enter(.ready)
    return
}
```

### 独立版

- `StandaloneLaunchpad` 持有 `updater`（`.remindedByApplication`）；`startUpdating()` 设好 `prepareToShowWindow`（界面开着就 `hide(reason: "showing an update", returningToPreviousApplication: false)`，再 `NSApp.unhide(nil)`）后启动它。自检启动（`--self-check`）不启动 updater。
- `applicationDidFinishLaunching`：`wasRelaunchedForUpdate = UpdateRelaunchRecord().takeRelaunchNote()`；显示与否交给纯函数 `StandaloneLaunchShowing.showsOnLaunch(wasLaunchedAtLogin:wasRelaunchedForUpdate:)`，两者任一为真就不显示，并记一条日志说明原因。
- 主菜单的「Check for Updates…」在「About」下面；Dock 菜单有待装更新时它排第一、后跟分隔线，否则排在「Settings…」下面。
- Dock 角标用 `NSApp.dockTile.badgeLabel = "1"`，经 swift-navigation 的 `observe` 跟着 `pendingUpdate`。

### 设置行

注入版控制面板「General」节，两版表单都加：

```text
Check for updates automatically      [switch]
Updates                     Version 1.2 (4)   [Check Now]
```

独立版设置窗口加：

```text
Check for Updates Automatically:  [switch]
Updates:                          Version 1.2 (4)  [Check Now]
```

开关的状态从 Sparkle 读（控制面板每次刷新时、设置窗口每次出现时），切换时写回：Sparkle 窗口里的勾选框也会改这个设置。有待装更新时「Updates」一行的副标题变成「Version <版本> is available.」、按钮变成「Install…」（`observe` 跟着 `pendingUpdate`）。注入版的两行放在「Launch at login」两行之后，独立版的放在「Open at Login」下面。`isStarted` 为假（开发构建）时两行都不出现。

### 签名

「Embed Standalone Launchpad」在签每个框架之前，先签框架里 `Versions/Current` 下的嵌套代码：`XPCServices/*.xpc` 与 `*.app`（`--preserve-metadata=entitlements`），再签与框架二进制同层的可执行文件（Sparkle 的 `Autoupdate`），都带 `--options runtime`；写成通用的循环，不只认 Sparkle。

`release_verify_export` 新增 `launchpad_awakener_verify_updates`，对两个 App（导出的注入版、zip 里的独立版）都核对：`Sparkle.framework/Versions/B/Autoupdate`、`Updater.app`、两个 XPC 服务是这个团队的 Developer ID、带时间戳与硬化运行时；Info.plist 的 `SUFeedURL` 与 `SUPublicEDKey` 不空。`RunScript.sh` 构建后核对两个 App 都带 Sparkle、Info.plist 有这两个键且公钥不空，Release 构建的更新源不空。

### 发布钩子

```zsh
release_engine_version=1.3.0
release_publishers=(github-release sparkle-appcast)
# The directory must exist when target checks it; Appcasts/.gitignore keeps it in git and its feeds out.
release_appcast_path=Appcasts/LaunchpadAwakenerAppcast.xml
release_notes_path='ReleaseNotes/{tag_version}.md'
release_appcast_embeds_release_notes=true

release_preflight() {
    [[ $app_release_publishes == true ]] || return 0
    rm -f "$app_release_project_directory"/Appcasts/*.xml(N)    # each feed lists this release only
}

release_after_product() {
    # Launchpad.zip out of the exported app ($app_release_application_path), stapled, zipped again as
    # Launchpad-<version>-<build>.zip, and added as a notarized product: the engine checks its ticket.
}

release_deploy_appcast() {
    local application_feed_path=$1
    local standalone_feed_path=${application_feed_path:h}/LaunchpadAppcast.xml
    app_release_generate_appcast "$app_release_run_directory/Products/Launchpad-<version>-<build>.zip" \
        "$standalone_feed_path" "$app_release_project_directory/ReleaseNotes/${app_release_tag#v}.md"
    gh release upload "$app_release_tag" --repo "$app_release_github_repository" --clobber \
        "$application_feed_path" "$standalone_feed_path"
}
```

`release_appcast_path` 的目录在 `target` 段就要存在（引擎检查），CI 的输出目录在 runner 的临时目录里、`build/` 不存在，所以放在提交进仓库的 `Appcasts/` 下，它的 `.gitignore` 忽略里面的 `*.xml`。

AppRelease 1.3.0 新增两样，都是可选的（按它的演进策略算 minor）：

- `release_appcast_embeds_release_notes`（默认 `false`，要配 `release_notes_path`）：发布器把 GitHub Release 的说明文件以「压缩包同名 + 原扩展名」放在暂存目录里，加 `--embed-release-notes`。默认关，因为打开它会改变已有项目的 appcast 输出。
- `app_release_generate_appcast <压缩包> <appcast> [<发布说明>]`：发布器自己也用它，钩子可以拿来给第二个 App 写 feed；用同一把私钥、这次 Release 的下载地址、预发布版的 beta 频道与 `release_appcast_arguments`，每个压缩包一个暂存目录。

### 密钥

- 两把密钥都用 Homebrew 的 OpenSSL 生成 Ed25519 密钥（系统自带的 LibreSSL 不支持），取 32 字节种子的 base64 作私钥文件，与 `generate_keys -x` 导出的格式相同；不经 Sparkle 的 `generate_keys`，因为它把私钥存进登录钥匙串、可能弹授权框。生成后用 `sign_update --ed-key-file` 签一次、`--verify` 验一次。
- 正式密钥：私钥经 `gh secret set SPARKLE_PRIVATE_KEY --repo OpenLaunchpad/LaunchpadAwakener` 存成仓库 secret，另留一份 `~/LaunchpadAwakener-SparklePrivateKey.txt`（权限 600）交用户转存进密码管理器后删除；公钥 `P0qf9O0kQEJksneoqaPYx5lTaJmz9rTzwAE9fkitCxY=` 写进两个 App 的 Release 配置。私钥丢了，已装的用户就只能手动更新。
- 测试密钥：私钥放在 agent 自己的目录 `/Volumes/DerivedData/Agents.noindex/claude/UpdateTesting/LaunchpadAwakener/`，公钥写进 Debug 配置，只签测试机上验证用的 zip。

### 测试机上的验证

非交互地走「下载后退出时安装」这条路，命令见实现说明「开发构建与测试机」。独立版打开会盖住屏幕，先预置重新打开的记录，它就不显示界面。点 Sparkle 窗口里的按钮属于交互操作，只在用户同意时做。

## 替代方案考量

- **只给注入版接更新，它更新后顺带替换已装的独立版**：用户否决。SIP 开着的用户主要用独立版，注入版不一定开着，独立版会一直停在旧版。
- **feed 提交进仓库、经 raw 地址或 GitHub Pages 提供**（LyricsX 的做法）：每次发布要往 `main` 推一个机器人提交，又触发一次 CI，还会和共用检出里别人没推的提交搅在一起；挂在 Release 附件上什么都不用提交，`latest/download` 天然指向最新正式版。
- **feed 保留版本历史**：要在发布前把上一版的 feed 下载回来合并，`latest` 被删或改时还会出错；Sparkle 只需要最新一条，历史在 GitHub Releases 上本来就有。
- **不改 AppRelease，全在本项目的钩子里做**：发布器的产物写到一个丢弃的文件，钩子自己再生成两个带发布说明的 feed。可行，但等于只借发布器的钩子、绕开它的输出，还得在钩子里猜引擎内部的 `generate_appcast` 路径与私钥文件；把「发布说明进 appcast」和「给第二个 App 生成 feed」做进引擎，别的项目也用得上。
- **独立版另开一个仓库或另一串 Release**：两个 App 同版本、同一次构建出来，分开发布只会让版本对不上。
- **默认静默自动安装**（`SUAutomaticallyUpdate = YES`）：这个工具会注入 Dock、装特权 daemon，更新前让用户看一眼装的是什么更合适；Sparkle 窗口里有勾选框，愿意的用户自己打开。
- **用系统通知提醒**：要先向用户要通知权限，多一个弹窗；Dock 角标和菜单项不需要权限。
- **注入版提醒时改菜单栏图标**：图标是状态指示（`StatusIndicatorView`），混进更新提醒会让「出问题」和「有更新」分不清。
- **自己写更新器**：签名校验、原地替换、重新打开、权限，Sparkle 都做好了。

## 影响

### 用户可见变化

- 两个 App 的 App 菜单多「Check for Updates…」；注入版菜单栏菜单与独立版 Dock 菜单也有；有待装的更新时变成「Install Update <版本>…」。
- 注入版控制面板「General」节、独立版设置窗口各多两行：自动检查开关、版本号与「Check Now」。
- 有新版本时：注入版弹 Sparkle 窗口（在别的 App 后面时菜单栏菜单里有提醒）；独立版 Dock 图标出现角标。
- 注入版更新后 Dock 会重启一次（闪一下），新 payload 自动注入。
- 独立版被 Sparkle 重新打开时不盖住屏幕。
- 原有操作都不变。

### 可发现性

默认开启自动检查（`SUEnableAutomaticChecks = YES`），不额外弹询问：这类工具的用户本来就要跟着 macOS 的 Dock 变化拿修复。菜单与设置里都有入口和开关。

### 数据与配置兼容

- 新增偏好：Sparkle 自己的 `SU*` 键（如 `SULastCheckTime`、`SUEnableAutomaticChecks` 的用户选择）；`LaunchedBuildRecord` 与 `UpdateRelaunchRecord` 各一个键。都在各自 App 的偏好域里，不碰布局库与已有设置。
- 从没装过 Sparkle 的版本升上来，`LaunchedBuildRecord` 没有记录，按「换了构建」算：Dock 里若是旧 payload 就重启一次，与用户手动点「Restart Dock」结果相同。
- 降级（手动装回旧版）后旧版没有 Sparkle，不读这些键，不受影响。

### 平台与最低版本

不变（macOS 15 起；Sparkle 2.10 支持更早的系统）。两个 App 不分 macOS 26 与 27，行为相同。

### 发布

- 不需要新的 entitlement：两个 App 都没开沙盒，Sparkle 的 XPC 服务用不上但随框架带着，照样签名。
- 公证：多了 Sparkle 的嵌套代码，导出与「Embed Standalone Launchpad」都要签好，`release_verify_export` 检查。
- 每次发布多传一个 `Launchpad-<版本>-<构建号>.zip` 与两个 feed；发布说明改为打 tag 前写进 `ReleaseNotes/<版本>.md`。
- 需要一个新的仓库 secret `SPARKLE_PRIVATE_KEY`。
- 第一个带 Sparkle 的版本（预计 1.2）发出后，自动更新从下一个版本起才起作用。

## 落地步骤

0. **提案入库** —— 改动地图最后一行
   - 行为：无代码变化。
1. **Sparkle 骨架与更新源**（已完成）—— `Package.swift`、`ApplicationUpdater`（只建 updater、不接 UI）、`UpdateFeedResolution`、两个 `Info.plist`、`project.pbxproj` 的构建设置、测试密钥
   - 行为：`releaseBuildUsesTheBundledFeed`
   - 行为：`developmentBuildWithoutOverrideHasNoFeed`
   - 行为：`developmentBuildUsesTheOverrideFeed`
   - 行为：`releaseBuildIgnoresTheOverride`
   - 行为：`emptyFeedValueCountsAsNone`
   - 行为：两个 App 的 Release 构建 Info.plist 里有 `SUFeedURL`、`SUPublicEDKey`、`SUEnableAutomaticChecks`（构建后用 `plutil` 核对，写进 RunScript 的检查）
2. **菜单入口与温和提醒**（已完成）—— `UpdateReminder`、`ApplicationUpdater.makeMenuItem()`、`ApplicationMainMenu`、`StatusItemController`、独立版的 App 菜单与 Dock 菜单、Dock 角标
   - 行为：`shownBySparkleLetsSparkleShowScheduledUpdates`
   - 行为：`remindedByApplicationNeverLetsSparkleShowScheduledUpdates`
   - 行为：`updateShownOutOfFocusLeavesAReminder`
   - 行为：`updateShownInFocusLeavesNoReminder`
   - 行为：`userInitiatedCheckLeavesNoReminder`
   - 行为：`reminderClearsWhenTheUserSeesTheUpdate`
   - 行为：`reminderClearsWhenTheSessionEnds`
   - 行为：`menuItemOffersTheWaitingUpdate`
   - 行为：`mainMenuPutsTheUpdateItemUnderAbout`
3. **设置行**（已完成）—— `ControlPanelViewController`、`StandaloneSettings`
   - 行为：两版控制面板表单（SIP 开着、关着）都有两行更新设置；开发构建没有更新源时没有
   - 行为：切换开关写回 `automaticallyChecksForUpdates`
4. **更新之后**（已完成）—— `LaunchedBuildRecord`、`DockRestartAfterUpdate`、`UpdateRelaunchRecord`、`ApplicationDelegate`、独立版启动
   - 行为：`firstRecordedLaunchCountsAsNewBuild`
   - 行为：`sameBuildIsNotNew`
   - 行为：`differentBuildIsNew`
   - 行为：`restartsTheDockOnceForANewBuildWithAStalePayload`
   - 行为：`doesNotRestartWithoutAStalePayload`
   - 行为：`doesNotRestartWhileInjectionIsBlocked`
   - 行为：`doesNotRestartForTheSameBuild`
   - 行为：`relaunchNoteIsReadOnce`
   - 行为：`standaloneStaysHiddenWhenRelaunchedForAnUpdate`
   - 行为：`standaloneStaysHiddenWhenLaunchedAtLogin`
   - 行为：`standaloneShowsWhenOpenedByTheUser`
5. **发布**（已完成）—— AppRelease 1.3.0、`Release.zsh`、`Release.yml`、「Embed Standalone Launchpad」、`ReleaseNotes/`、正式密钥与 secret（设之前问用户）
   - 行为：AppRelease 的测试覆盖发布说明进 appcast、`app_release_generate_appcast` 生成第二个 feed
   - 行为：手动跑一次 `Release.yml` 演练：通过，产物里有 `Launchpad-<版本>-<构建号>.zip`，其中的独立版已装订公证票据（`stapler validate`）、`spctl -a -vv` 判为 Notarized
   - 行为：`release_verify_export` 对两个 App 的 Sparkle 嵌套代码都通过
   - 行为：CI 的单元测试与 Release 构建通过
6. **测试机验证与文档**（已完成）—— 实现说明、`CLAUDE.md`、两份实现说明的更新、README、索引
   - 行为：MacBook 上照「测试机上的验证」走通两个 App 的下载、退出时安装、重新打开；注入版重启 Dock 一次且注入正常，daemon 没要求重新批准
   - 行为：文档登记完毕

**收尾时必须判断两件事**（判断结果写进决策日志，不允许沉默跳过）：

- **要不要配套专题文章** —— 预计要写实现说明 `AutomaticUpdates.md`：更新源为什么挂在 Release 附件上、密钥在哪、两个 App 为什么提醒方式不同、Dock 为什么在更新后重启，都是看代码看不出来的。
- **有没有引入新术语** —— 「更新源（appcast）」「温和提醒（gentle reminders）」可能要登记进 `Documentations/Glossary.md`。

## 决策日志

| 日期 | 变更 | 说明 |
|------|------|------|
| 2026-11-23 | Created as Draft | 用户要给 App 加自动更新。定下两个 App 各自用 Sparkle 更新、各有一个更新源，注入版更新后自动重启一次 Dock。自行决定：每天自动检查、弹窗确认后安装，更新源挂在 GitHub Release 附件上，开发构建不检查更新，先给 AppRelease 加上发布说明进 appcast 与第二个 feed 的能力。 |
| 2026-11-23 | Accepted | 用户批准，开始实现。功能分支 `feature/automatic-updates`，从 main 切出。 |
| 2026-11-23 | 第 1 步完成 | `UpdateFeedResolution` 写成无实例的 `enum`（只有静态成员），多一个按 `Bundle` 与 `UserDefaults` 取值的便捷方法。`ApplicationUpdater` 在 Info.plist 没有 `SUPublicEDKey` 时也不启动：正式公钥到第 5 步才写进 Release 配置，在那之前的 Release 构建不该启动一个装不了任何更新、还会在启动时报错的 updater。updater 由 `start()` 启动而不是在构造时启动，好让 App 在建菜单之前决定。测试密钥不经钥匙串：系统的 LibreSSL 不支持 Ed25519，改用 Homebrew 的 OpenSSL 生成，私钥放在 agent 自己的目录 `/Volumes/DerivedData/Agents.noindex/claude/UpdateTesting/LaunchpadAwakener/`，`sign_update --ed-key-file` 实测能用它签名并通过 `--verify`。RunScript 构建后核对两个 App 都带 Sparkle、Info.plist 有更新源与公钥两个键，Release 构建的更新源不能为空。 |
| 2026-11-23 | 第 2 步完成 | `PendingUpdate` 放在模块顶层，不嵌在 `ApplicationUpdater` 里（嵌进主线程隔离的类里，纯值的 `UpdateReminder` 用它就要跨隔离）；`UpdateReminder` 的事件方法叫 `updateWillShow(displayVersion:isUserInitiated:isShownBySparkle:isInImmediateFocus:)`，另有 `menuItemTitle(for:)` 给出两种菜单项标题。菜单项的目标是代理对象，它实现 `NSMenuItemValidation`：会校验菜单项的菜单（主菜单、Dock 菜单）每次打开时标题跟着提醒变，菜单栏菜单本来就每次重建。独立版「先收起界面、再显示 Sparkle 窗口」做成 `ApplicationUpdater.prepareToShowWindow` 闭包，由 `checkForUpdates()` 在激活 App 之前调用，所有入口（主菜单、Dock 菜单、设置）都经过它。独立版 Dock 菜单：有待装更新时它排第一、后跟分隔线；否则「Check for Updates…」排在「Settings…」下面。自检启动（`--self-check`）不启动 updater。Sparkle 的 `SPUUpdaterDelegate` 已是主线程隔离，`SPUStandardUserDriverDelegate` 不是，后者的遵循要写 `@preconcurrency`。 |
| 2026-11-23 | 第 3 步完成 | 注入版控制面板「General」节在「Launch at login」两行之后加「Check for updates automatically」开关行与「Updates」行，SIP 开着、关着两版表单都有；独立版设置窗口在「Open at Login」下面加「Check for Updates Automatically:」与「Updates:」。「Updates」行的副标题平时是版本号与构建号，有待装更新时变成「Version <版本> is available.」，按钮从「Check Now」变成「Install…」（`observe` 跟着 `pendingUpdate`）。开关的状态在控制面板每次刷新、设置窗口每次出现时从 Sparkle 读：它的窗口里的勾选框也会改这个设置。两边都没有界面测试：项目里本来就没有控制面板与设置窗口的测试，构造整个控制面板要连带 daemon、注入这些控制器；这一步只靠编译与测试机上核对。 |
| 2026-11-23 | 第 4 步完成 | `DockRestartAfterUpdate` 照改动地图单独成文件。「第一次启动新构建」的标记在启动序列走到重连驻留 payload 之后才清掉：daemon 还在等批准、序列中途停下时，等用户批准回来、序列再跑到这里时照样重启一次 Dock。重启 Dock 之后序列直接进入 `.ready`，不再另外注入：`restartTargets()` 自己会注入新拉起的 Dock。独立版的启动判断写成 `StandaloneLaunchShowing.showsOnLaunch(wasLaunchedAtLogin:wasRelaunchedForUpdate:)`，不显示时记一条日志说明原因。两个 App 的启动日志都写明这次是登录时启动、为完成更新重新打开，还是用户打开，以及是否第一次启动这个构建。 |
| 2026-11-23 | 第 5 步：嵌入独立版时签好 Sparkle | 「Embed Standalone Launchpad」在签框架之前先签框架里 `Versions/Current` 下的 XPC 服务与 `.app`（保留 entitlements），再签与框架同层的可执行文件（`Autoupdate`），都带硬化运行时。Debug 构建实测：zip 里独立版的 `Installer.xpc`、`Downloader.xpc`、`Autoupdate`、`Updater.app` 都是这次构建的身份、带 `runtime` 标志，`codesign --verify --deep --strict` 通过；Sparkle 原件里的 Downloader 本来就没有 entitlements。`release_verify_export` 新增 `launchpad_awakener_verify_updates`：两个 App 的这四样都要是本团队 Developer ID、带时间戳与硬化运行时，Info.plist 的 `SUFeedURL` 与 `SUPublicEDKey` 都不能空。 |
| 2026-11-23 | 第 6 步：测试机上走通更新 | MacBook（27.2.1，26B131）上用这条分支的两版开发构建实测「下载后退出时安装」：A 版构建 3，B 版构建 4、版本 1.1.2，另把 `DYLIB_CURRENT_VERSION` 改成 2 让 payload 的 UUID 不同（payload 的版本号写死为 1，只改构建号时 payload 可能不变，那时本来也不需要重启 Dock）。B 版用测试密钥签名，`generate_appcast --embed-release-notes` 生成两个更新源，Markdown 发布说明以 `sparkle:format="markdown"` 嵌进条目；在 MacBook 本机端口用 `python3 -m http.server` 提供。注入版：带 `-UpdateFeedURL` 打开 A 版，Sparkle 立即检查（预置了很早的 `SULastCheckTime`）、下载 B 版，「EdDSA signature is correct」；退出后装成 1.1.2（4）；再打开时日志为「Launched by the user, build 4 for the first time」与「First launch of this build with an older payload in the Dock: restarting the Dock once」，Dock 进程换新、新 payload 注入、23 个方法签名零不符、hook 全部装上，daemon 没有要求重新批准；再退出重开只记「build 4」，Dock 不再重启。独立版：预置重新打开的记录后打开 A 版，日志为「Launched to finish an update: waiting for a click on the Dock icon」，没有盖住屏幕；下载、校验、退出后装成 1.1.2（4），`codesign --verify --deep --strict` 通过。开发构建里主 App 的 Sparkle 辅助程序保留厂商签名，Sparkle 因此记「Skipping atomic rename/swap」改用非原子替换，照样装好；导出的正式版会被整体重签，不受影响。「Install and Relaunch」（会写重新打开记录的那条路）要点 Sparkle 窗口里的按钮，属于交互操作，没有做。验证后测试机换回 A 版，删掉测试用的偏好与更新源。 |
| 2026-11-23 | 第 5 步：密钥与 AppRelease 1.3.0 | 用户同意由 agent 生成正式密钥、设仓库 secret，并改 AppRelease、推 main、打 1.3.0。两把密钥都用 Homebrew 的 OpenSSL 生成，不经 `generate_keys`（它把私钥存进登录钥匙串，可能弹授权框）；正式私钥存成仓库 secret `SPARKLE_PRIVATE_KEY`，备份文件 `~/LaunchpadAwakener-SparklePrivateKey.txt` 交用户转存。`Release.yml` 第一步也检查这个 secret。AppRelease 的嵌入发布说明做成可选变量 `release_appcast_embeds_release_notes`，而不是有说明就嵌：后者会改变已有项目（LyricsX）的 appcast 输出，按它的演进策略算破坏性变更；发布器改用新的公开函数 `app_release_generate_appcast`，每个压缩包一个暂存目录。`release_appcast_path` 改放在提交进仓库的 `Appcasts/`（`.gitignore` 忽略 `*.xml`）：引擎在 `target` 段就检查它的目录存在，CI 的输出目录在 runner 临时目录里，`build/` 不存在。发布说明从这一版起写在 `ReleaseNotes/<版本>.md`，已发布的三版从 Release 补进来。Release 标题仍要手动改：引擎没有设标题的选项，不为这个再改引擎。 |
| 2026-11-23 | 第 6 步：文档 | 新写实现说明 `Documentations/Internal/AutomaticUpdates.md`；项目 `CLAUDE.md` 的结构表加 `LaunchpadAwakenerUpdating`，「发布」一节改成打 tag 前写发布说明、核对 Release 上有两个 zip 与两个更新源，记下签名私钥的 secret 与丢失的后果；控制面板与独立版的实现说明补上更新入口、提醒与更新后重启 Dock；术语表登记「Appcast（更新源）」「Gentle reminders（温和提醒）」；README 加「Updates」一节与 Sparkle 的致谢。 |
| 2026-11-23 | 第 5 步：发布演练通过 | 功能分支不升版本号，另开临时分支把版本改成 1.2（构建 4）、放一份演练用的 `ReleaseNotes/1.2.md`，手动跑 `Release.yml`（只跑到打 zip，不发布）：一次通过。日志里两个 App 都是「Sparkle signed」（四样嵌套代码为本团队 Developer ID、带时间戳与硬化运行时）且更新源不空；`release_after_product` 从导出的 App 里取出独立版、`stapler staple` 成功，引擎核对 `Launchpad-1.2-4.zip`「stapled, and Gatekeeper takes it for notarized」——公证服务确实登记了压在注入版资源里的独立版，不必单独提交公证。本机对同一分支 `app-release all --dry-run --publish` 的输出显示发布说明会以 `LaunchpadAwakener-1.2-4.md` 嵌进注入版的更新源、`generate_appcast` 取自 Xcode 构建目录里的 Sparkle 包；预演不调用钩子，所以独立版的更新源与上传只在真正发布时第一次运行（`app_release_generate_appcast` 本身由 AppRelease 的测试覆盖）。第一个带 Sparkle 的版本没有已装的用户会读它的更新源，它出错也不影响任何人。演练完删掉临时分支。 |
| 2026-11-23 | 验证 | 最终状态下 `swift test` 709 个测试通过（这次新增 27 个），`RunScript.sh` 的完整构建、三个架构切片与两个 App 更新设置的核对通过。 |
| 2026-11-23 | 实现完成，待用户看过后收尾 | 配了实现说明 `Documentations/Internal/AutomaticUpdates.md`（登记在头部「配套文档」）；新术语「Appcast（更新源）」「Gentle reminders（温和提醒）」已登记进术语表。控制面板与独立版设置里的两行、Dock 角标与菜单项没有在屏幕上看过，「Install and Relaunch」那条路没有实测，都要交互操作。 |
