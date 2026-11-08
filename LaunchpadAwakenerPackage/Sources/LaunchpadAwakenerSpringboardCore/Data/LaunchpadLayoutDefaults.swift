import Foundation

/// Which discovered applications never get a place in the layout; macOS 15's `LPLayoutExcludeList`.
///
/// The data is `launchpad.exclude` of macOS 15.5's `LaunchPadLayout.plist` (version 5), kept verbatim:
/// a list matched against bundle identifiers and names alike, plus three rules. A test checks it against
/// the copy of that file in the test resources.
package struct ApplicationExclusionList: Sendable, Equatable {
    package enum Rule: Sendable, Equatable {
        /// The name equals this, ignoring case.
        case nameMatches(String)
        /// The name contains this, ignoring case.
        case nameContains(String)
        /// The bundle identifier starts with this.
        case bundleIdentifierHasPrefix(String)
    }

    package var excludedIdentifiers: Set<String>
    package var rules: [Rule]

    package init(excludedIdentifiers: Set<String>, rules: [Rule]) {
        self.excludedIdentifiers = excludedIdentifiers
        self.rules = rules
    }

    package func excludes(bundleIdentifier: String, name: String) -> Bool {
        if excludedIdentifiers.contains(bundleIdentifier) || excludedIdentifiers.contains(name) {
            return true
        }
        return rules.contains { rule in
            switch rule {
            case .nameMatches(let ruleName):
                name.caseInsensitiveCompare(ruleName) == .orderedSame
            case .nameContains(let ruleName):
                name.localizedCaseInsensitiveContains(ruleName)
            case .bundleIdentifierHasPrefix(let prefix):
                bundleIdentifier.hasPrefix(prefix)
            }
        }
    }

    /// macOS 27's own launcher, which opens the system's Apps — macOS 15 likewise excluded its
    /// `com.apple.launchpad.launcher`.
    package static let appsLauncherBundleIdentifier = "com.apple.apps.launcher"

    /// The standalone Launchpad, debug and release builds alike: a Launchpad does not list a Launchpad,
    /// as macOS 15's did not list its own launcher.
    package static let standaloneLaunchpadBundleIdentifierPrefix = "com.MxIris.LaunchpadAwakener.Launchpad"

    /// macOS 15.5's list, plus macOS 27's Apps launcher and the standalone Launchpad.
    package static let standard: ApplicationExclusionList = {
        var exclusionList = macOS15
        exclusionList.excludedIdentifiers.insert(appsLauncherBundleIdentifier)
        exclusionList.rules.append(.bundleIdentifierHasPrefix(standaloneLaunchpadBundleIdentifierPrefix))
        return exclusionList
    }()

    /// Whether the application is a way into Launchpad or Apps itself — macOS 27's Apps launcher or the
    /// standalone Launchpad. These leave a layout even when they are already in it. The rest of the
    /// list only keeps applications from being added: macOS 15 left in place what a user had put in a
    /// layout itself, an uninstaller included, and so does this.
    package static func isLaunchpadLauncher(bundleIdentifier: String) -> Bool {
        bundleIdentifier == appsLauncherBundleIdentifier || bundleIdentifier.hasPrefix(standaloneLaunchpadBundleIdentifierPrefix)
    }

    /// `launchpad.exclude` of macOS 15.5's `LaunchPadLayout.plist`, unchanged.
    package static let macOS15 = ApplicationExclusionList(
        excludedIdentifiers: macOS15ExcludedIdentifiers,
        rules: [
            .nameMatches("setup"),
            .bundleIdentifierHasPrefix("com.adobe.estoolkit"),
            .nameContains("uninstall"),
        ]
    )

    private static let macOS15ExcludedIdentifiers: Set<String> = [
        "\"com.Adobe.ESD.AdobeUpdaterApplication\"",
        "APP_ID",
        "Adobe Flash Builder 4.6 Plug-in Utility",
        "Analyze Documents",
        "Contact Sheets",
        "Export Flash Animation",
        "Make Calendar",
        "Microsoft Query",
        "SimController",
        "Web Gallery",
        "chc.4875E02D9FB21EE389F73B8D1702B320485DF8CE.1",
        "com.Adobe.Uninstall",
        "com.Adobe.Uninstall Product",
        "com.adobe.Acrobat.Uninstaller",
        "com.adobe.ContributeFirefoxPlugin",
        "com.adobe.ExtensionManager",
        "com.adobe.Installers.Redirector",
        "com.adobe.Installers.Setup",
        "com.adobe.PDApp",
        "com.adobe.PDApp.AAMRegistrationNotifier",
        "com.adobe.PDApp.AAMUpdatesNotifier",
        "com.adobe.PDApp.adobe_asm",
        "com.adobe.PXBToolkit",
        "com.adobe.adobe_licutil",
        "com.adobe.air.ApplicationInstaller",
        "com.adobe.air.Installer",
        "com.adobe.contribute.cs4.ffextn",
        "com.adobe.drive.ConnectUI",
        "com.adobe.estoolkit-3.5",
        "com.adobe.estoolkit-3.6",
        "com.adobe.headlights.LogTransport2App",
        "com.apple.ASApplication",
        "com.apple.launchpad.launcher",
        "com.apple.keychainaccess",
        "com.adobe.flashplayer.installmanager",
        "com.blizzard.BNUpdate",
        "com.blizzard.blizzarderror",
        "com.blizzard.downloader",
        "com.blizzard.errorreporter",
        "com.blizzard.starcraft2.repair",
        "com.blizzard.starcraft2switcher",
        "com.blizzard.worldofwarcraft.repair",
        "com.filemaker.client.runtime",
        "com.filemaker.wc9",
        "com.imagineersystems.mocha4ae_adobe",
        "com.leadertech.powerReg",
        "com.macromedia.Flash Player Debugger.app",
        "com.macromedia.Flash Player.app",
        "com.microsoft.AlertsDaemon",
        "com.microsoft.ClipGallery",
        "com.microsoft.EquationEditor",
        "com.microsoft.Graph",
        "com.microsoft.MicrosoftCertManager",
        "com.microsoft.OrgChart",
        "com.microsoft.SyncServicesAgent",
        "com.microsoft.alerts.daemon",
        "Microsoft/com.microsoft.AlertsDaemon",
        "com.microsoft.entourage.database_daemon",
        "com.microsoft.entourage.database_utility",
        "com.microsoft.entourage.office_reminders",
        "com.microsoft.entourage.syncservices12",
        "com.microsoft.language_register",
        "com.microsoft.myday",
        "com.microsoft.office.setupassistant",
        "com.microsoft.office.uploadcenter",
        "com.microsoft.office_pg",
        "com.microsoft.openxml.chart.app",
        "com.microsoft.openxml.excel.app",
        "com.microsoft.outlook.database_daemon",
        "com.microsoft.outlook.database_utility",
        "com.microsoft.outlook.office_reminders",
        "com.microsoft.removeoffice",
        "com.microsoft.setupassistant",
        "com.symantec.uninstaller",
        "com.synthetic-ap.SA Color Finesse 3 UI",
    ]
}

/// The first page macOS 15 laid out for a new user; `launchpad.layout.mainPage` of macOS 15.5's
/// `LaunchPadLayout.plist` (layout version 8). Used only when there is no macOS 15 layout to import.
package enum DefaultLaunchpadLayout {
    package enum Entry: Sendable, Equatable {
        case application(bundleIdentifier: String)
        case folder(title: String, applicationBundleIdentifiers: [String])
    }

    package static let mainPage: [Entry] = [
        .application(bundleIdentifier: "com.apple.Server.v3"),
        .application(bundleIdentifier: "com.apple.AppStore"),
        .application(bundleIdentifier: "com.apple.Safari"),
        .application(bundleIdentifier: "com.apple.mail"),
        .application(bundleIdentifier: "com.apple.AddressBook"),
        .application(bundleIdentifier: "com.apple.iCal"),
        .application(bundleIdentifier: "com.apple.reminders"),
        .application(bundleIdentifier: "com.apple.Notes"),
        .application(bundleIdentifier: "com.apple.FaceTime"),
        .application(bundleIdentifier: "com.apple.MobileSMS"),
        .application(bundleIdentifier: "com.apple.Maps"),
        .application(bundleIdentifier: "com.apple.findmy"),
        .application(bundleIdentifier: "com.apple.PhotoBooth"),
        .application(bundleIdentifier: "com.apple.GenerativePlaygroundApp"),
        .application(bundleIdentifier: "com.apple.Photos"),
        .application(bundleIdentifier: "com.apple.Music"),
        .application(bundleIdentifier: "com.apple.podcasts"),
        .application(bundleIdentifier: "com.apple.TV"),
        .application(bundleIdentifier: "com.apple.VoiceMemos"),
        .application(bundleIdentifier: "com.apple.garageband10"),
        .application(bundleIdentifier: "com.apple.iMovieApp"),
        .application(bundleIdentifier: "com.apple.iWork.Keynote"),
        .application(bundleIdentifier: "com.apple.iWork.Numbers"),
        .application(bundleIdentifier: "com.apple.iWork.Pages"),
        .application(bundleIdentifier: "com.apple.weather"),
        .application(bundleIdentifier: "com.apple.news"),
        .application(bundleIdentifier: "com.apple.stocks"),
        .application(bundleIdentifier: "com.apple.iBooksX"),
        .application(bundleIdentifier: "com.apple.clock"),
        .application(bundleIdentifier: "com.apple.calculator"),
        .application(bundleIdentifier: "com.apple.freeform"),
        .application(bundleIdentifier: "com.apple.Home"),
        .application(bundleIdentifier: "com.apple.siri.launcher"),
        .application(bundleIdentifier: "com.apple.ScreenContinuity"),
        .application(bundleIdentifier: "com.apple.Passwords"),
        .application(bundleIdentifier: "com.apple.systempreferences"),
        .folder(title: "Other", applicationBundleIdentifiers: [
            "com.apple.shortcuts",
            "com.apple.QuickTimePlayerX",
            "com.apple.Dictionary",
            "com.apple.TextEdit",
            "com.apple.FontBook",
            "com.apple.ScreenSharing",
            "com.apple.exposelauncher",
            "com.apple.backup.launcher",
            "com.apple.Preview",
            "com.apple.screenshot.launcher",
            "com.apple.Image_Capture",
            "com.apple.DigitalColorMeter",
            "com.apple.ColorSyncUtility",
            "com.apple.Stickies",
            "com.apple.grapher",
            "com.apple.VoiceOverUtility",
            "com.apple.printcenter",
            "com.apple.Automator",
            "com.apple.ScriptEditor2",
            "com.apple.audio.AudioMIDISetup",
            "com.apple.BluetoothFileExchange",
            "com.apple.DiskUtility",
            "com.apple.SystemProfiler",
            "com.apple.ActivityMonitor",
            "com.apple.Console",
            "com.apple.Terminal",
            "com.apple.airport.airportutility",
            "com.apple.MigrateAssistant",
            "com.apple.helpviewer",
        ]),
    ]
}
