import Foundation
import LaunchpadAwakenerShared
import Testing
@testable import LaunchpadAwakenerAppCore

/// Which copy of the input method helper is running, read against the copy inside the app.
@Suite("The input method helper's state")
struct TextInputHelperStateTests {
    private static let bundledPath = "/Applications/LaunchpadAwakener.app/\(TextInputServiceIdentity.helperBundleProgram)"
    private static let launchDate = Date(timeIntervalSince1970: 1_793_000_000)

    private static func process(_ processIdentifier: pid_t, at path: String = bundledPath) -> TextInputHelperProcess {
        TextInputHelperProcess(processIdentifier: processIdentifier, executablePath: path, launchDate: launchDate)
    }

    @Test("no running copy means launchd starts one the next time Launchpad opens")
    func notRunning() {
        let state = TextInputHelperState(runningProcesses: [], bundledExecutablePath: Self.bundledPath, bundledExecutableChangeDate: Self.launchDate)
        #expect(state == .notRunning)
    }

    @Test("this app's copy, unchanged since it started, is current")
    func current() {
        let running = Self.process(4182)
        let state = TextInputHelperState(
            runningProcesses: [running],
            bundledExecutablePath: Self.bundledPath,
            bundledExecutableChangeDate: Self.launchDate.addingTimeInterval(-3600)
        )
        #expect(state == .current(running))
        #expect(!state.isRestartedAutomatically)
    }

    @Test("this app's copy, replaced after the process started, runs the old code and is restarted automatically")
    func replacedSinceLaunch() {
        let running = Self.process(4182)
        let state = TextInputHelperState(
            runningProcesses: [running],
            bundledExecutablePath: Self.bundledPath,
            bundledExecutableChangeDate: Self.launchDate.addingTimeInterval(1)
        )
        #expect(state == .replacedSinceLaunch(running))
        #expect(state.isRestartedAutomatically)
    }

    @Test("a copy from another build directory is reported, not restarted automatically")
    func otherCopy() {
        let running = Self.process(4182, at: "/Volumes/DerivedData/LaunchpadAwakener/Build/Products/Debug/LaunchpadAwakener.app/\(TextInputServiceIdentity.helperBundleProgram)")
        let state = TextInputHelperState(
            runningProcesses: [running],
            bundledExecutablePath: Self.bundledPath,
            bundledExecutableChangeDate: Self.launchDate.addingTimeInterval(-3600)
        )
        #expect(state == .otherCopy(running))
        #expect(!state.isRestartedAutomatically)
    }

    @Test("with the app's copy missing, a running copy at its path counts as current")
    func bundledCopyMissing() {
        let running = Self.process(4182)
        let state = TextInputHelperState(runningProcesses: [running], bundledExecutablePath: Self.bundledPath, bundledExecutableChangeDate: nil)
        #expect(state == .current(running))
    }

    @Test("of several running copies, the one that needs attention is reported")
    func severalCopies() {
        let current = TextInputHelperProcess(processIdentifier: 501, executablePath: Self.bundledPath, launchDate: Self.launchDate.addingTimeInterval(60))
        let replaced = Self.process(502)
        let elsewhere = Self.process(503, at: "/tmp/LaunchpadAwakener.app/\(TextInputServiceIdentity.helperBundleProgram)")
        let changeDate = Self.launchDate.addingTimeInterval(30)

        let withReplaced = TextInputHelperState(
            runningProcesses: [current, elsewhere, replaced],
            bundledExecutablePath: Self.bundledPath,
            bundledExecutableChangeDate: changeDate
        )
        let withoutReplaced = TextInputHelperState(
            runningProcesses: [current, elsewhere],
            bundledExecutablePath: Self.bundledPath,
            bundledExecutableChangeDate: changeDate
        )

        #expect(withReplaced == .replacedSinceLaunch(replaced))
        #expect(withoutReplaced == .otherCopy(elsewhere))
    }
}

/// The same, read from real processes: a copy of `/bin/sleep` posing as the helper inside an app bundle laid
/// out as the real one is.
@Suite("The input method helper's state, from the process table", .serialized)
struct TextInputHelperProcessTableTests {
    /// An app bundle in a temporary directory with a helper whose executable is a copy of `/bin/sleep`.
    private struct StandInApp {
        let appBundleURL: URL
        let helperExecutableURL: URL
        let helperBundleIdentifier: String

        init(in directoryURL: URL, helperBundleIdentifier: String) throws {
            appBundleURL = directoryURL.appending(path: "LaunchpadAwakener.app", directoryHint: .isDirectory)
            helperExecutableURL = appBundleURL.appending(path: TextInputServiceIdentity.helperBundleProgram)
            self.helperBundleIdentifier = helperBundleIdentifier
            let macOSDirectoryURL = helperExecutableURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: macOSDirectoryURL, withIntermediateDirectories: true)
            let information: [String: Any] = [
                "CFBundleIdentifier": helperBundleIdentifier,
                "CFBundleExecutable": helperExecutableURL.lastPathComponent,
                "CFBundlePackageType": "APPL",
            ]
            let informationData = try PropertyListSerialization.data(fromPropertyList: information, format: .xml, options: 0)
            try informationData.write(to: macOSDirectoryURL.deletingLastPathComponent().appending(path: "Info.plist"))
            try FileManager.default.copyItem(at: URL(filePath: "/bin/sleep"), to: helperExecutableURL)
        }

        func launchHelper() throws -> Process {
            let process = Process()
            process.executableURL = helperExecutableURL
            process.arguments = ["60"]
            try process.run()
            return process
        }

        /// Replaces the helper's executable as a build or `rsync` does: writes a new file and renames it over.
        func replaceHelperExecutable() throws {
            let replacementURL = helperExecutableURL.deletingLastPathComponent().appending(path: "replacement")
            try FileManager.default.copyItem(at: URL(filePath: "/bin/sleep"), to: replacementURL)
            guard rename(replacementURL.path(percentEncoded: false), helperExecutableURL.path(percentEncoded: false)) == 0 else {
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
        }

        func state() -> TextInputHelperState {
            .now(forAppAt: appBundleURL, helperBundleIdentifier: helperBundleIdentifier)
        }
    }

    /// Ends the stand-in helper and waits until it is gone, from the thread that launched it: these tests
    /// are synchronous, so no `await` moves them to another thread in between.
    private static func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        process.waitUntilExit()
    }

    private static func makeTemporaryDirectory() throws -> URL {
        let directoryURL = FileManager.default.temporaryDirectory.appending(path: "TextInputHelperProcessTableTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return directoryURL
    }

    @Test("a running copy of the app's helper is found with its path and launch time, and is current")
    func runningCopyIsCurrent() throws {
        let directoryURL = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let app = try StandInApp(in: directoryURL, helperBundleIdentifier: "com.example.textinput.\(UUID().uuidString)")
        let launchedAround = Date()
        let helper = try app.launchHelper()
        defer { Self.stop(helper) }

        let process = try #require(app.state().process)

        #expect(app.state() == .current(process))
        #expect(process.processIdentifier == helper.processIdentifier)
        #expect(process.executablePath == TextInputHelperState.realPath(of: app.helperExecutableURL))
        #expect(abs(process.launchDate.timeIntervalSince(launchedAround)) < 5)
    }

    @Test("replacing the app's helper after it started makes the running copy an old one")
    func replacedAfterLaunch() throws {
        let directoryURL = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let app = try StandInApp(in: directoryURL, helperBundleIdentifier: "com.example.textinput.\(UUID().uuidString)")
        let helper = try app.launchHelper()
        defer { Self.stop(helper) }

        try app.replaceHelperExecutable()

        #expect(app.state().isRestartedAutomatically)
        #expect(app.state().process?.processIdentifier == helper.processIdentifier)
    }

    @Test("a helper running from another copy of the app is another copy")
    func helperFromAnotherApp() throws {
        let directoryURL = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let helperBundleIdentifier = "com.example.textinput.\(UUID().uuidString)"
        let runningApp = try StandInApp(in: directoryURL.appending(path: "Build"), helperBundleIdentifier: helperBundleIdentifier)
        let thisApp = try StandInApp(in: directoryURL.appending(path: "Installed"), helperBundleIdentifier: helperBundleIdentifier)
        let helper = try runningApp.launchHelper()
        defer { Self.stop(helper) }

        guard case .otherCopy(let process) = thisApp.state() else {
            Issue.record("Expected another copy, got \(thisApp.state())")
            return
        }
        #expect(process.processIdentifier == helper.processIdentifier)
    }

    @Test("a helper of the other configuration, with another bundle identifier, is not this build's")
    func otherConfigurationIsIgnored() throws {
        let directoryURL = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let app = try StandInApp(in: directoryURL, helperBundleIdentifier: "com.example.textinput.\(UUID().uuidString)")
        let helper = try app.launchHelper()
        defer { Self.stop(helper) }

        #expect(TextInputHelperState.now(forAppAt: app.appBundleURL, helperBundleIdentifier: "com.example.textinput.debug.\(UUID().uuidString)") == .notRunning)
    }
}
