import Foundation
import Darwin

/// What the kernel's process table says about the processes of this machine: which exist, which
/// executable each runs, and when each started. Unprivileged, so it sees everyone's processes but only
/// what `proc_pidinfo` tells any user.
enum ProcessTable {
    static func allProcessIdentifiers() -> [pid_t] {
        let requiredByteCount = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard requiredByteCount > 0 else { return [] }

        // proc_listpids reports a byte count, not an element count. Round up by one element so a
        // process that spawns between the sizing call and the fetching call still fits.
        let capacity = Int(requiredByteCount) / MemoryLayout<pid_t>.size + 1
        var identifiers = [pid_t](repeating: 0, count: capacity)
        let writtenByteCount = proc_listpids(
            UInt32(PROC_ALL_PIDS),
            0,
            &identifiers,
            Int32(capacity * MemoryLayout<pid_t>.size)
        )
        guard writtenByteCount > 0 else { return [] }

        let writtenElementCount = Int(writtenByteCount) / MemoryLayout<pid_t>.size
        // The kernel zero-fills unused slots; a zero identifier is never a real process.
        return identifiers.prefix(writtenElementCount).filter { $0 != 0 }
    }

    static func executablePath(ofProcessIdentifier processIdentifier: pid_t) -> String? {
        // PROC_PIDPATHINFO_MAXSIZE is a C macro, so it does not cross into Swift. Its definition is
        // 4 * MAXPATHLEN, and proc_pidpath rejects anything smaller.
        var pathBuffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let pathLength = proc_pidpath(processIdentifier, &pathBuffer, UInt32(pathBuffer.count))
        guard pathLength > 0 else { return nil }
        // proc_pidpath returns the byte count it wrote, excluding the terminator, so decoding
        // exactly that many bytes avoids both the deprecated array overload of String(cString:) and
        // any dependence on the terminator being where we expect.
        let pathBytes = pathBuffer.prefix(Int(pathLength)).map { UInt8(bitPattern: $0) }
        return String(decoding: pathBytes, as: UTF8.self)
    }

    /// When the process started, to the microsecond, from `PROC_PIDTBSDINFO`.
    static func launchDate(ofProcessIdentifier processIdentifier: pid_t) -> Date? {
        var information = proc_bsdinfo()
        let informationSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(processIdentifier, PROC_PIDTBSDINFO, 0, &information, informationSize) == informationSize else {
            return nil
        }
        let secondsSince1970 = TimeInterval(information.pbi_start_tvsec) + TimeInterval(information.pbi_start_tvusec) / 1_000_000
        return Date(timeIntervalSince1970: secondsSince1970)
    }
}
