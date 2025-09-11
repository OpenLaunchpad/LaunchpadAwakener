import Cocoa
import os
import HelperService
import HelperCommunication
import HelperClient
import LaunchpadAwakenerCommunication
import InjectionService

@main
class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        MainWindowController.shared.showWindow(nil)
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        // Insert code here to tear down your application
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }
}

final class MainViewController: NSHostingController<MainView> {
    init() {
        super.init(rootView: .init())
        sizingOptions = .preferredContentSize
    }

    @available(*, unavailable)
    @MainActor @preconcurrency dynamic required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

final class MainWindowController: NSWindowController, NSWindowDelegate {
    static let shared = MainWindowController()

    lazy var mainViewController = MainViewController()

    override var windowNibName: NSNib.Name? { "" }

    init() {
        super.init(window: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadWindow() {
        window = NSWindow(contentViewController: mainViewController)
    }

    override func windowDidLoad() {
        super.windowDidLoad()
        window?.center()
        window?.styleMask.remove(.resizable)
        window?.titlebarAppearsTransparent = true
        window?.setFrameAutosaveName("Main Window")
        window?.delegate = self
    }

    func windowWillClose(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
    }
}

@Observable
final class MainViewModel {
    private static let logger = Logger(subsystem: "com.JH.HopperMCPApp", category: "ViewModel")

    public private(set) var isHelperConnected: Bool = false

    public private(set) var isHopperRunning: Bool = false

    public private(set) var isPluginInstalled: Bool = false

    private let helperClient = HelperClient()

    private var logger: Logger { Self.logger }

    public init() {
        Task {
            do {
                try await connectToHelper()
            } catch {
                print(error)
            }
        }
    }

    public func setVisible() async throws {
        guard let server = try await helperClient.availableServerInfos().first else { return }
        try await helperClient.connectToServer(info: server)
        try await helperClient.sendToServer(request: SetVisibleRequest(isVisible: true, reason: "Test"), for: server)
    }
    
    public func installHelper() async throws {
        try await helperClient.installTool(name: LaunchpadAwakenerDaemonBundleIdentifier)
        try await connectToHelper()
    }

    public func connectToHelper() async throws {
        try await helperClient.connectToTool(machServiceName: LaunchpadAwakenerDaemonBundleIdentifier, isPrivilegedHelperTool: true)
        isHelperConnected = await helperClient.isConnectedToTool
    }

    public func injectDock() async throws {
        guard let pid = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.dock" })?.processIdentifier else {
            logger.error("Failed to get process identifier")
            return
        }
        guard let dylib = Bundle.main.url(forResource: "DockInjection", withExtension: "framework") else {
            logger.error("Failed to get dylib URL")
            return
        }
        guard let dylibURL = Bundle(url: dylib)?.executableURL else {
            logger.error("Failed to get dylib executable URL")
            return
        }

        try await helperClient.sendToTool(request: InjectApplicationRequest(pid: pid, dylibURL: dylibURL))
    }
}

import AppKit
import SwiftUI

struct MainView: View {
    var viewModel: MainViewModel = .init()

    @State
    var error: String?

    @State
    var isPresentedError: Bool = false

    var body: some View {
        Image(nsImage: NSApplication.shared.applicationIconImage)
            .resizable()
            .frame(width: 100, height: 100)

        Form {
            Section {
                HStack {
                    Text("Install Helper")

                    Spacer()

                    Button {
                        Task {
                            do {
                                try await viewModel.installHelper()
                            } catch {
                                print(error)
                                self.error = "\(error)"
                                self.isPresentedError = true
                            }
                        }
                    } label: {
                        if viewModel.isHelperConnected {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                                .font(.title2)
                        } else {
                            Image(systemName: "arrow.down.circle.fill")
                                .foregroundColor(.blue)
                                .font(.title2)
                        }
                    }
                }
                .buttonStyle(PlainButtonStyle())
                
                HStack {
                    Text("Inject Dock")

                    Spacer()

                    Button {
                        Task {
                            do {
                                try await viewModel.injectDock()
                            } catch {
                                print(error)
                                self.error = "\(error)"
                                self.isPresentedError = true
                            }
                        }
                    } label: {
                        if viewModel.isHelperConnected {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                                .font(.title2)
                        } else {
                            Image(systemName: "arrow.down.circle.fill")
                                .foregroundColor(.blue)
                                .font(.title2)
                        }
                    }
                }
                .buttonStyle(PlainButtonStyle())
                
                HStack {
                    Text("Set Visible")

                    Spacer()

                    Button {
                        Task {
                            do {
                                try await viewModel.setVisible()
                            } catch {
                                print(error)
                                self.error = "\(error)"
                                self.isPresentedError = true
                            }
                        }
                    } label: {
                        if viewModel.isHelperConnected {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                                .font(.title2)
                        } else {
                            Image(systemName: "arrow.down.circle.fill")
                                .foregroundColor(.blue)
                                .font(.title2)
                        }
                    }
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .formStyle(.grouped)
        .alert("Error", isPresented: $isPresentedError, presenting: error) { _ in
            Text("OK")
        } message: { error in
            Text("\(error)")
        }
        .frame(minWidth: 300)
    }
}

@available(macOS 14.0, *)
#Preview {
    MainView()
}
