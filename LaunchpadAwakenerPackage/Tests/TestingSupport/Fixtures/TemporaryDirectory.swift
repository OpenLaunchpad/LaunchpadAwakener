import Foundation

/// Runs `body` with a fresh empty directory that is deleted afterwards.
package func withTemporaryDirectory<Result>(_ body: (URL) throws -> Result) throws -> Result {
    let directoryURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("LaunchpadAwakenerTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directoryURL) }
    return try body(directoryURL)
}

/// Runs `body` with a fresh empty directory that is deleted afterwards.
package func withTemporaryDirectory<Result>(_ body: (URL) async throws -> Result) async throws -> Result {
    let directoryURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("LaunchpadAwakenerTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directoryURL) }
    return try await body(directoryURL)
}
