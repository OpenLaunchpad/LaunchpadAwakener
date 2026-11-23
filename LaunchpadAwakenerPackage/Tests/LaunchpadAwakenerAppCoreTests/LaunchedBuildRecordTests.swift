import Foundation
@testable import LaunchpadAwakenerAppCore
import Testing

/// The first launch of a new build: after Sparkle installed an update, or a newer copy was put in place.
@Suite("The first launch of a new build")
struct LaunchedBuildRecordTests {
    private static func makeRecord() throws -> LaunchedBuildRecord {
        LaunchedBuildRecord(defaults: try #require(UserDefaults(suiteName: "LaunchedBuildRecordTests.\(UUID().uuidString)")))
    }

    @Test("a launch with none recorded before counts as a new build, as after updating from a version that kept no record")
    func firstRecordedLaunchCountsAsNewBuild() throws {
        let record = try Self.makeRecord()
        #expect(record.recordLaunch(ofBuild: "4"))
    }

    @Test("launching the same build again is not a new build")
    func sameBuildIsNotNew() throws {
        let record = try Self.makeRecord()
        record.recordLaunch(ofBuild: "4")
        #expect(!record.recordLaunch(ofBuild: "4"))
    }

    @Test("launching another build is a new build, once")
    func differentBuildIsNew() throws {
        let record = try Self.makeRecord()
        record.recordLaunch(ofBuild: "3")
        #expect(record.recordLaunch(ofBuild: "4"))
        #expect(!record.recordLaunch(ofBuild: "4"))
    }
}
