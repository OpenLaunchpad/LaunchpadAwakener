@preconcurrency import Foundation
import HelperService
import HelperServer
@preconcurrency import LaunchpadAwakenerShim
import LaunchpadAwakenerCommunication
import Dynamic
import os

@MainActor
@objc
public final class LaunchpadAwakenerServer: NSObject {
    @objc(mainServer)
    public static let main = LaunchpadAwakenerServer()

    private let logger = Logger(subsystem: "com.MxIris.LaunchpadAwakenerServer", category: "LaunchpadAwakenerServer")

    private var helperServer: HelperServer?

    @objc
    public func run(springboard: NSObject) {
        Task {
            do {
                let helperServer = try await HelperServer(serverType: .plain(name: "LaunchpadAwakenerServer", identifier: "com.MxIris.LaunchpadAwakenerServer"), services: [LaunchpadAwakenerService(springboard: springboard)])
                await helperServer.activate()
                try await helperServer.connectToTool(machServiceName: "com.MxIris.launchpadawakenerd", isPrivilegedHelperTool: true)
                self.helperServer = helperServer
                logger.log("\("LaunchpadAwakenerServer running.", privacy: .public)")
            } catch {
                logger.error("\(error, privacy: .public)")
            }
        }
    }
}

@objc protocol LPSpringboardProtocol {
    func activate()
    func start()
    func setVisible(_ visible: Bool, reason: String)
    func debugDump() -> String
}

actor LaunchpadAwakenerService: HelperService {
    let springboard: NSObject

    init(springboard: NSObject) {
        self.springboard = springboard
    }

    private let logger = Logger(subsystem: "com.MxIris.LaunchpadAwakenerServer", category: "LaunchpadAwakenerService")

    func setupHandler(_ handler: some HelperHandler) async {
        handler.setMessageHandler { [weak self] (request: SetVisibleRequest) in
            guard let self else { return .empty }
            await springboard.perform(#selector(LPSpringboardProtocol.activate))
            await springboard.perform(#selector(LPSpringboardProtocol.start))
            await springboard.perform(#selector(LPSpringboardProtocol.setVisible(_:reason:)), with: NSNumber(booleanLiteral: true), with: "Test")
            let string = await springboard.perform(#selector(LPSpringboardProtocol.debugDump)).takeUnretainedValue() as? NSString ?? ""
            logger.log("\(string, privacy: .public)")
            logger.log("\("LaunchpadAwakenerService set visible.", privacy: .public)")
            return .empty
        }
    }

    func run() async throws {}
}
