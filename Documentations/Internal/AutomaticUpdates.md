# 自动更新：实现说明

> 配套提案见[两个 App 用 Sparkle 自动更新](../Evolutions/0015-automatic-updates.md)。

注入版 LaunchpadAwakener 与独立版 Launchpad 都用 [Sparkle](https://sparkle-project.org) 2 更新自己：每天检查一次各自的更新源（appcast，Sparkle 读的一份 XML，列出可装的版本、下载地址与签名），有新版本就弹 Sparkle 的窗口，用户确认后安装。这份说明讲清更新源与密钥放在哪、两个 App 为什么提醒方式不同、装完之后发生什么，以及发布与测试时要做什么。

## 各样东西在哪

| 东西 | 在哪 | 说明 |
|---|---|---|
| 注入版的更新源 | `https://github.com/OpenLaunchpad/LaunchpadAwakener/releases/latest/download/LaunchpadAwakenerAppcast.xml` | 每次发布由 CI 生成、作为附件传到那次的 GitHub Release |
| 独立版的更新源 | 同一处的 `LaunchpadAppcast.xml` | 同上 |
| 独立版的安装包 | 每次 Release 上的 `Launchpad-<版本>-<构建号>.zip` | 从注入版包里的 `Launchpad.zip` 取出、装订公证票据后另压一份 |
| 正式私钥 | 仓库 secret `SPARKLE_PRIVATE_KEY`；备份由用户保管 | 2026-11-23 生成，见下文「密钥」 |
| 正式公钥 | 两个 App 的 Release 配置的 `UPDATE_PUBLIC_ED_KEY`，进 Info.plist 的 `SUPublicEDKey` | `P0qf9O0kQEJksneoqaPYx5lTaJmz9rTzwAE9fkitCxY=` |
| 测试密钥 | 私钥在开发机 `/Volumes/DerivedData/Agents.noindex/claude/UpdateTesting/LaunchpadAwakener/TestingPrivateKey.txt`，公钥在 Debug 配置 | 只签测试机上验证用的 zip |
| 更新源地址 | 两个 App 的 Release 配置的 `UPDATE_FEED_URL`，进 Info.plist 的 `SUFeedURL`；Debug 配置为空 | 开发构建不检查更新 |
| 代码 | `LaunchpadAwakenerPackage/Sources/LaunchpadAwakenerUpdating/` | `ApplicationUpdater` 包住 Sparkle 的标准 updater；两个 App 只链接这一个模块就拿到 Sparkle |

## 更新源挂在 Release 上，每份只有最新一版

`releases/latest/download/<文件名>` 由 GitHub 重定向到最新正式版（不含预发布版）的同名附件，所以 App 里写死这个地址，每次发布把新的两份 feed 传到新 Release 上即可，不往仓库提交任何东西。先前 LyricsX 的做法是把 feed 提交进仓库、经网页提供，放在这里每次发布都要往 `main` 推一个机器人提交，又会多触发一次 CI，还会和共用检出里别人没推的提交搅在一起。

每份 feed 只有这一版一个条目：Sparkle 只需要最新的那条，历史在 GitHub Releases 上本来就有；要合并历史就得在发布前先把上一版的 feed 下载回来，`latest` 被删或改时还会出错。`Release.zsh` 的 `release_preflight` 在发布时删掉 `Appcasts/` 里上一次留下的 feed，`generate_appcast` 从空 feed 开始写。

代价：预发布版不会被 `latest` 指到，所以没有 beta 通道；要做 beta 通道得换一个不跟着 `latest` 走的地址。

## 两个 App 为什么提醒方式不同

两个 App 平时都在后台：注入版是菜单栏 App，没有 Dock 图标；独立版收起后整个 App 藏起来（`NSApp.hide`），打开时又盖在一切之上（窗口层级 27）。Sparkle 对后台 App 的定时检查结果，在它判断不是「立即聚焦」的时机（刚启动、闲置之后回来之外）时，会把窗口开在别的 App 后面。所以两个 App 都声明支持 Sparkle 的「温和提醒」（gentle reminders，Sparkle 让后台 App 自己决定怎么提醒的一组代理方法），由 `UpdateReminder` 决定：

- **注入版**（`.shownBySparkle`）：照样让 Sparkle 显示；显示在后面的那次，菜单栏菜单顶上多一项「Install Update <版本>…」，点了把窗口带到前面（`checkForUpdates()` 先 `NSApp.activate()`）。
- **独立版**（`.remindedByApplication`）：从不让 Sparkle 自己显示定时检查的结果——藏起来的 App 的窗口看不见，界面开着时又会被盖住。改为 Dock 图标加角标「1」、Dock 菜单顶上的「Install Update <版本>…」、设置窗口「Updates」一行显示新版本号。用户点了，`prepareToShowWindow` 先收起界面（不把焦点交还给之前的 App）、`NSApp.unhide`，再显示 Sparkle 的窗口。

用户主动检查（菜单、设置里的「Check Now」）总是由 Sparkle 立即显示，不经过提醒。用户看过窗口或这次更新会话结束（装了、跳过、推迟），提醒就撤掉。

没用系统通知：要先向用户要通知权限，多一个弹窗；菜单栏图标也不改，它是状态指示，混进更新提醒会让「出问题」和「有更新」分不清。

## 装完之后

**注入版：第一次启动新构建时，Dock 里若还是旧 payload，自动重启一次 Dock。** payload 是加载进 Dock 的镜像，Dock 不重启就换不掉（`PayloadInjectionCoordinator.hasStalePayload` 按镜像 UUID 比对）。用户已经让 Sparkle 装了更新，所以补完这一步不再问。判断「第一次启动新构建」靠 `LaunchedBuildRecord`：记上次启动的 `CFBundleVersion`，不一样（或从没记过，例如从不带这个功能的版本升上来）就算。重启放在启动序列重连驻留 payload 之后；daemon 还在等批准、序列中途停下的，等它再跑到这里时照样重启。SIP 开着时不注入，也就不重启。重启之后 `restartTargets()` 自己注入新拉起的 Dock。只改了 App、payload 没变的构建（payload 的 UUID 相同）不重启，那时本来就不需要。

**被 Sparkle 重新打开时不打扰用户。** Sparkle 重新打开 App 之前会调 `updaterWillRelaunchApplication(_:)`，下一次启动却没有任何信号说明为什么被打开，所以旧进程在偏好里记一笔（`UpdateRelaunchRecord`，键 `RelaunchedToFinishAnUpdate`），新进程启动时读一次就清掉：独立版不盖住屏幕、等用户点 Dock 图标；注入版不弹控制面板，与登录时启动一样。走「退出时安装」那条路时没有重新打开，用户下次自己打开就照常显示。

**daemon 与输入法辅助进程照旧换新。** 整包被替换时，daemon 靠 `daemonVersion` 判断要不要重装（改了 daemon 才递增），输入法辅助进程的可执行文件被换过、App 启动时就结束它。2026-11-23 在 MacBook 上实测，Sparkle 换掉整个注入版之后 daemon 没有要求重新批准。

## 签名

Sparkle 框架里嵌着别的代码：`Versions/B/XPCServices/` 下的 `Installer.xpc` 与 `Downloader.xpc`、`Updater.app`、`Autoupdate`。

- **注入版**的由导出整体重签成 Developer ID。开发构建不经导出，这些辅助程序保留 Sparkle 厂商的签名，Sparkle 装更新时因此记「Skipping atomic rename/swap … because Autoupdate is not signed with same identity」，改用非原子的替换，照样装好。
- **独立版**压在注入版资源里的 `Launchpad.zip` 中，导出碰不到。「Embed Standalone Launchpad」构建阶段压缩前由内向外重签它：框架 `Resources` 里带可执行文件的 bundle、框架里的 XPC 服务与 `.app`（保留 entitlements）、与框架二进制同层的可执行文件，都带硬化运行时，再签框架、签 App。
- `Release.zsh` 的 `launchpad_awakener_verify_updates` 在导出后对两个 App 都核对这四样是本团队 Developer ID、带时间戳与硬化运行时，Info.plist 的 `SUFeedURL` 与 `SUPublicEDKey` 不能空。`RunScript.sh` 构建后核对两个 App 都带 Sparkle、Info.plist 有这两个键且公钥不空，Release 构建的更新源不空。

## 密钥

更新包与 feed 里的条目用 Ed25519（EdDSA）签名，App 只装签名对得上 Info.plist 里 `SUPublicEDKey` 的更新。**正式私钥丢了，已经装了的 App 就再也收不到自动更新**，只能请用户手动下载新版本，新版本带新公钥。

- 正式密钥 2026-11-23 用 Homebrew 的 OpenSSL 生成（系统自带的 LibreSSL 不支持 Ed25519），没有经过 Sparkle 的 `generate_keys`：后者把私钥存进登录钥匙串，可能弹授权框。私钥存成仓库 secret `SPARKLE_PRIVATE_KEY`，CI 经 `APP_RELEASE_SPARKLE_PRIVATE_KEY` 交给 AppRelease；另有一份备份交由用户转存进密码管理器。格式是 32 字节种子的 base64，与 `generate_keys -x` 导出的一样，`sign_update --ed-key-file` 与 `generate_appcast --ed-key-file` 都认。
- 本机要签东西时（例如手动补一份 feed）：`sign_update --ed-key-file <私钥文件> <zip>`，工具在 Sparkle 包里（Xcode 构建目录的 `SourcePackages/artifacts/sparkle/Sparkle/bin/`）。
- 测试密钥只签测试机上用的 zip，公钥写在 Debug 配置里；它泄露也只影响开发构建。

## 发布

发版步骤见项目 `CLAUDE.md`「发布」一节。与自动更新有关的：

- **发布说明在打 tag 之前写进 `ReleaseNotes/<版本>.md`**（`release_notes_path`），缺了发布在 `target` 段就停下。它同时进 GitHub Release 的正文和两个 feed 条目的说明（AppRelease 1.3.0 的 `release_appcast_embeds_release_notes`，Markdown 原样嵌入、Sparkle 自己渲染）。
- AppRelease 的 `sparkle-appcast` 发布器写注入版的 feed；`release_after_product` 从导出的 App 里取出独立版、`xcrun stapler staple`、另压成 zip 作为已公证产物登记，引擎随即核对票据与 Gatekeeper 的判断；`release_deploy_appcast` 用 `app_release_generate_appcast` 给独立版写 feed，再 `gh release upload --clobber` 把两份传上 Release。
- Release 标题仍是引擎给的 `v<版本>`，发布后照旧改成「LaunchpadAwakener <版本>」。
- 第一个带 Sparkle 的版本（1.2）发出后，已装 1.1.1 及更早版本的用户要手动换一次；从下一个版本起才自动更新。所以 1.2 的 feed 就算出错也没有人受影响，可以借它检查发布流程。

## 开发构建与测试机

开发构建的 `UPDATE_FEED_URL` 为空，`ApplicationUpdater` 不启动，菜单与设置里没有更新项。验证时用启动参数给它一个本地 feed（`UpdateFeedResolution` 只在开发构建里认 `UpdateFeedURL` 这个偏好键，正式版忽略它）：

```bash
# On the development machine: two builds with different build numbers. DYLIB_CURRENT_VERSION makes the
# payload differ too, or its UUID stays the same and the Dock needs no restart.
queued-build ./RunScript.sh --no-launch --derived-data <dir>                      # A: build 3
queued-build ./RunScript.sh --no-launch --derived-data <dir> -- CURRENT_PROJECT_VERSION=4 MARKETING_VERSION=1.1.2 DYLIB_CURRENT_VERSION=2   # B
ditto -c -k --keepParent LaunchpadAwakenerDebug.app LaunchpadAwakenerDebug-1.1.2-4.zip   # B, in a directory of its own
generate_appcast <that directory> --ed-key-file <testing private key> --download-url-prefix http://127.0.0.1:8765/ \
    --embed-release-notes -o LaunchpadAwakenerAppcast.xml
# On the MacBook: serve the feed and the zip, install A, and make Sparkle check at once and install on quit.
/usr/bin/python3 -m http.server 8765 --bind 127.0.0.1          # in the feed's directory, with nohup
defaults write com.MxIris.LaunchpadAwakener.debug SUAutomaticallyUpdate -bool YES
defaults write com.MxIris.LaunchpadAwakener.debug SULastCheckTime -date "2020-01-01 00:00:00 +0000"
open /Applications/LaunchpadAwakenerDebug.app --args -UpdateFeedURL http://127.0.0.1:8765/LaunchpadAwakenerAppcast.xml
# Wait for "EdDSA signature is correct" in the log, quit the app, and open it again.
```

独立版同理（偏好域 `com.MxIris.LaunchpadAwakener.Launchpad.debug`，feed 为 `LaunchpadAppcast.xml`）。打开它会盖住屏幕，属于交互操作；先 `defaults write … RelaunchedToFinishAnUpdate -bool YES`，它就当作「为完成更新重新打开」，不显示界面。测完删掉这些偏好、停掉文件服务、换回正常的开发构建。Sparkle 自己的日志在 subsystem `org.sparkle-project.Sparkle` 下。

「Install and Relaunch」那条路要点 Sparkle 窗口里的按钮，属于交互操作，用户同意时才做。

## 验证记录

- 2026-11-23（开发机与 MacBook 27.2.1，26B131）：单元测试覆盖更新源的选择、两种提醒、重新打开的记录、构建记录、Dock 重启的判断、独立版启动时显示与否；主菜单的位置有测试。MacBook 上照上面的做法走通「下载后退出时安装」：注入版从构建 3 装成 4，再打开时日志「First launch of this build with an older payload in the Dock: restarting the Dock once」，Dock 进程换新、新 payload 注入、23 个方法签名零不符、hook 全部装上，daemon 没要求重新批准；再次打开不再重启。独立版带着重新打开的记录启动时没有盖住屏幕，下载、校验、退出后装成构建 4，签名完整。feed 里的 Markdown 发布说明以 `sparkle:format="markdown"` 嵌入。控制面板与独立版设置里的两行、Dock 角标与菜单项没有在屏幕上看过。
- 2026-11-26（1.2 正式发布）：CI 的演练与正式发布都一次通过，Release 上有两个 zip 与两份 feed，`releases/latest/download/` 取到的两份 feed 都指向 1.2（构建 4），发布说明以 Markdown 嵌入。正式密钥第一次实际用上：独立版 zip 里 Info.plist 的 `SUPublicEDKey` 是正式公钥（两个 App 的 Release 配置是同一把），用它验 feed 里这个 zip 的 `sparkle:edSignature` 通过，换测试公钥验不过，说明 secret 里的私钥与公钥是一对。验法：公钥 base64 解码后前面接上 Ed25519 的 DER 头 `302a300506032b6570032100` 转成 PEM，再用 Homebrew OpenSSL 跑 `openssl pkeyutl -verify -pubin -inkey <公钥.pem> -rawin -in <zip> -sigfile <签名解码后的文件>`。从 1.2 自动更新到下一版，要等下一版发布才能实测。
