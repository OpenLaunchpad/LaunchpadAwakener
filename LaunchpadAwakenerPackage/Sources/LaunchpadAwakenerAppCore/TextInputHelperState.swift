import Darwin
import Foundation
import LaunchpadAwakenerShared

/// A running copy of the input method helper, as the process table reports it.
public struct TextInputHelperProcess: Equatable, Sendable {
    public let processIdentifier: pid_t
    /// Where the running executable lives, as `proc_pidpath` reports it: symbolic links resolved.
    public let executablePath: String
    public let launchDate: Date

    public init(processIdentifier: pid_t, executablePath: String, launchDate: Date) {
        self.processIdentifier = processIdentifier
        self.executablePath = executablePath
        self.launchDate = launchDate
    }
}

/// Where the input method helper stands next to the copy inside this app.
///
/// The helper is a LaunchAgent that stays up once launchd starts it, so a new build or installation of the
/// app leaves the old helper running until the user logs out. Reinstalling the daemon does not touch it.
public enum TextInputHelperState: Equatable, Sendable {
    /// Not running; launchd starts it the next time Launchpad opens.
    case notRunning
    /// Running this app's copy, unchanged since it started.
    case current(TextInputHelperProcess)
    /// Running this app's copy, which a build or an installation replaced after the process started: the
    /// process still runs the old code.
    case replacedSinceLaunch(TextInputHelperProcess)
    /// Running a copy from somewhere else: another build directory or another installation registered the
    /// same LaunchAgent.
    case otherCopy(TextInputHelperProcess)

    /// Reads the running copies against this app's.
    ///
    /// - Parameters:
    ///   - runningProcesses: Every running copy of the helper with this build's bundle identifier.
    ///   - bundledExecutablePath: The helper inside this app, symbolic links resolved as the kernel resolves
    ///     them, so that it compares with a process's path.
    ///   - bundledExecutableChangeDate: When that file last changed: its status change time, which writing,
    ///     copying or renaming the file sets and which nothing can set back, unlike the modification time
    ///     `rsync -a` copies over. Nil when the file is missing.
    ///
    /// Copies that need attention come first when several run: one replaced since launch, then one from
    /// elsewhere, then a current one.
    public init(runningProcesses: [TextInputHelperProcess], bundledExecutablePath: String, bundledExecutableChangeDate: Date?) {
        let states = runningProcesses.map { process -> TextInputHelperState in
            guard process.executablePath == bundledExecutablePath else { return .otherCopy(process) }
            if let bundledExecutableChangeDate, bundledExecutableChangeDate > process.launchDate {
                return .replacedSinceLaunch(process)
            }
            return .current(process)
        }
        self = states.min { $0.attentionRank < $1.attentionRank } ?? .notRunning
    }

    public var process: TextInputHelperProcess? {
        switch self {
        case .notRunning:
            nil
        case .current(let process), .replacedSinceLaunch(let process), .otherCopy(let process):
            process
        }
    }

    /// Whether the app replaces the helper by itself when it launches: only its own copy, rebuilt or
    /// reinstalled in place. A copy from elsewhere may be the one launchd starts for this label, which
    /// another build registered last; restarting it automatically could have two builds take turns.
    public var isRestartedAutomatically: Bool {
        if case .replacedSinceLaunch = self {
            return true
        }
        return false
    }

    private var attentionRank: Int {
        switch self {
        case .replacedSinceLaunch:
            0
        case .otherCopy:
            1
        case .current:
            2
        case .notRunning:
            3
        }
    }
}

extension TextInputHelperState {
    /// The helper as it stands now for the app at `appBundleURL`, read from the process table.
    public static func now(
        forAppAt appBundleURL: URL = Bundle.main.bundleURL,
        helperBundleIdentifier: String = TextInputServiceIdentity.machServiceName
    ) -> TextInputHelperState {
        let bundledExecutablePath = realPath(of: appBundleURL.appending(path: TextInputServiceIdentity.helperBundleProgram))
        return TextInputHelperState(
            runningProcesses: runningHelperProcesses(
                bundleIdentifier: helperBundleIdentifier,
                executableName: (bundledExecutablePath as NSString).lastPathComponent
            ),
            bundledExecutablePath: bundledExecutablePath,
            bundledExecutableChangeDate: statusChangeDate(ofFileAt: bundledExecutablePath)
        )
    }

    /// The path the kernel reports for a process running the file at `url`: every symbolic link resolved,
    /// `/var` included, which `URL.resolvingSymlinksInPath()` leaves as `/var` where `proc_pidpath` says
    /// `/private/var`. The path as given when the file does not exist.
    static func realPath(of url: URL) -> String {
        let path = url.path(percentEncoded: false)
        guard let resolvedPath = realpath(path, nil) else { return path }
        defer { free(resolvedPath) }
        return String(cString: resolvedPath)
    }

    /// The running processes whose executable is named `executableName` and sits in an application bundle
    /// with `bundleIdentifier`, which tells this build's helper from the other configuration's.
    static func runningHelperProcesses(bundleIdentifier: String, executableName: String) -> [TextInputHelperProcess] {
        ProcessTable.allProcessIdentifiers().compactMap { processIdentifier in
            guard
                let executablePath = ProcessTable.executablePath(ofProcessIdentifier: processIdentifier),
                (executablePath as NSString).lastPathComponent == executableName,
                Self.bundleIdentifier(ofExecutableAt: executablePath) == bundleIdentifier,
                let launchDate = ProcessTable.launchDate(ofProcessIdentifier: processIdentifier)
            else { return nil }
            return TextInputHelperProcess(processIdentifier: processIdentifier, executablePath: executablePath, launchDate: launchDate)
        }
    }

    /// Read from the bundle's `Info.plist` each time rather than through `Bundle`, which caches.
    private static func bundleIdentifier(ofExecutableAt executablePath: String) -> String? {
        let contentsURL = URL(filePath: executablePath).deletingLastPathComponent().deletingLastPathComponent()
        guard
            let informationData = try? Data(contentsOf: contentsURL.appending(path: "Info.plist")),
            let information = try? PropertyListSerialization.propertyList(from: informationData, format: nil) as? [String: Any]
        else { return nil }
        return information["CFBundleIdentifier"] as? String
    }

    static func statusChangeDate(ofFileAt path: String) -> Date? {
        var fileStatus = stat()
        guard stat(path, &fileStatus) == 0 else { return nil }
        let changeTime = fileStatus.st_ctimespec
        return Date(timeIntervalSince1970: TimeInterval(changeTime.tv_sec) + TimeInterval(changeTime.tv_nsec) / 1_000_000_000)
    }
}
