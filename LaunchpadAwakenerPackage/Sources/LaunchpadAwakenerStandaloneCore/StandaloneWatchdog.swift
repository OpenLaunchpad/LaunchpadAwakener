import Darwin
import Foundation
import LaunchpadAwakenerSpringboardCore
import os
import OSToolbox

/// Takes the springboard's window off screen if the main thread stops answering for longer than
/// ``hangThreshold``: a full-screen window above everything that no longer takes events would leave the
/// whole Mac unusable, which is what happened once on macOS 26 with an earlier attempt.
///
/// It works from its own thread and through the window server directly (`SLSOrderWindow`), since a hung
/// main thread cannot run AppKit. It only acts once per showing, and only while a window is watched.
@Loggable(subsystem: "com.MxIris.LaunchpadAwakener", category: "StandaloneWatchdog")
final class StandaloneWatchdog: Sendable {
    static let shared = StandaloneWatchdog()

    static let hangThreshold: Duration = .seconds(3)
    private static let checkInterval: TimeInterval = 1

    private struct State {
        var watchedWindowNumber: Int?
        var lastHeartbeat = ContinuousClock.now
        var hasTakenWindowAway = false
        var isRunning = false
    }

    private typealias OrderWindowFunction = @convention(c) (UInt32, UInt32, Int32, UInt32) -> Int32

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Starts the watching thread; later calls do nothing.
    func start() {
        let isFirstStart = state.withLock { currentState -> Bool in
            guard !currentState.isRunning else { return false }
            currentState.isRunning = true
            return true
        }
        guard isFirstStart else { return }
        let watchingThread = Thread { [self] in
            while true {
                Thread.sleep(forTimeInterval: Self.checkInterval)
                DispatchQueue.main.async { [self] in
                    state.withLock { $0.lastHeartbeat = .now }
                }
                checkMainThread()
            }
        }
        watchingThread.name = "com.MxIris.LaunchpadAwakener.StandaloneWatchdog"
        watchingThread.start()
    }

    func watch(windowNumber: Int) {
        state.withLock { currentState in
            currentState.watchedWindowNumber = windowNumber
            currentState.lastHeartbeat = .now
            currentState.hasTakenWindowAway = false
        }
    }

    func stopWatching(windowNumber: Int) {
        state.withLock { currentState in
            guard currentState.watchedWindowNumber == windowNumber else { return }
            currentState.watchedWindowNumber = nil
        }
    }

    private func checkMainThread() {
        let hungWindowNumber = state.withLock { currentState -> Int? in
            guard
                let watchedWindowNumber = currentState.watchedWindowNumber,
                !currentState.hasTakenWindowAway,
                ContinuousClock.now - currentState.lastHeartbeat > Self.hangThreshold
            else { return nil }
            currentState.hasTakenWindowAway = true
            return watchedWindowNumber
        }
        guard let hungWindowNumber else { return }
        let orderResult = Self.orderOut(windowNumber: hungWindowNumber)
        #log(.fault, "The main thread has not answered for over \(Self.hangThreshold, privacy: .public); took window \(hungWindowNumber, privacy: .public) off screen (result \(orderResult ?? -1, privacy: .public))")
    }

    /// `SLSOrderWindow(connection, window, kCGSOrderOut, 0)`; nil when SkyLight is out of reach.
    private static func orderOut(windowNumber: Int) -> Int32? {
        guard
            let connectionIdentifier = SkyLightBridge.mainConnectionIdentifier,
            let orderWindowSymbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "SLSOrderWindow")
        else { return nil }
        let orderWindow = unsafeBitCast(orderWindowSymbol, to: OrderWindowFunction.self)
        return orderWindow(connectionIdentifier, UInt32(windowNumber), 0, 0)
    }
}
