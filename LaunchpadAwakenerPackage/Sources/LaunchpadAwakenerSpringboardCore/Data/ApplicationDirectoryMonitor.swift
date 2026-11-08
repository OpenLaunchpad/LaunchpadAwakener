import CoreServices
import Foundation

/// Calls back when anything changes inside the application directories; the watching half of
/// macOS 15's `LPAppSource`, which followed its `app_sources` with FSEvents the same way.
///
/// Changes are coalesced over `latency`, so installing an application — many file events — produces
/// one callback. The callback runs on a private queue.
package final class ApplicationDirectoryMonitor: @unchecked Sendable {
    // Mutable state is touched only on `queue`.
    private let directories: [URL]
    private let latency: TimeInterval
    private let changeHandler: @Sendable () -> Void
    private let queue = DispatchQueue(label: "com.MxIris.LaunchpadAwakener.ApplicationDirectoryMonitor")
    private var eventStream: FSEventStreamRef?

    package init(directories: [URL], latency: TimeInterval = 2, changeHandler: @escaping @Sendable () -> Void) {
        // The read-only system volume never changes; watching it would only cost a stream.
        self.directories = directories.filter { directory in
            !directory.path.hasPrefix("/System/") && FileManager.default.fileExists(atPath: directory.path)
        }
        self.latency = latency
        self.changeHandler = changeHandler
    }

    deinit {
        if let eventStream {
            FSEventStreamStop(eventStream)
            FSEventStreamInvalidate(eventStream)
            FSEventStreamRelease(eventStream)
        }
    }

    package func start() {
        queue.sync {
            guard eventStream == nil, !directories.isEmpty else { return }
            var streamContext = FSEventStreamContext(
                version: 0,
                info: Unmanaged.passUnretained(self).toOpaque(),
                retain: nil,
                release: nil,
                copyDescription: nil
            )
            let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
                guard let info else { return }
                Unmanaged<ApplicationDirectoryMonitor>.fromOpaque(info).takeUnretainedValue().changeHandler()
            }
            guard let newEventStream = FSEventStreamCreate(
                kCFAllocatorDefault,
                callback,
                &streamContext,
                directories.map(\.path) as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                latency,
                FSEventStreamCreateFlags(kFSEventStreamCreateFlagNone)
            ) else { return }
            FSEventStreamSetDispatchQueue(newEventStream, queue)
            FSEventStreamStart(newEventStream)
            eventStream = newEventStream
        }
    }

    package func stop() {
        queue.sync {
            guard let eventStream else { return }
            FSEventStreamStop(eventStream)
            FSEventStreamInvalidate(eventStream)
            FSEventStreamRelease(eventStream)
            self.eventStream = nil
        }
    }
}
