import Foundation
@testable import LaunchpadAwakenerUpdating
import Testing

/// The note an app leaves before Sparkle relaunches it, so that the next launch knows it finishes an
/// update rather than being the user opening the app.
@Suite("The record of a relaunch that finishes an update")
struct UpdateRelaunchRecordTests {
    private static func makeDefaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "UpdateRelaunchRecordTests.\(UUID().uuidString)"))
    }

    @Test("the launch after a relaunch for an update reads the note, and the one after it does not")
    func relaunchNoteIsReadOnce() throws {
        let record = UpdateRelaunchRecord(defaults: try Self.makeDefaults())
        record.noteRelaunch()
        #expect(record.takeRelaunchNote())
        #expect(!record.takeRelaunchNote())
    }

    @Test("a launch with no relaunch before it finds no note")
    func launchWithoutRelaunchFindsNoNote() throws {
        let record = UpdateRelaunchRecord(defaults: try Self.makeDefaults())
        #expect(!record.takeRelaunchNote())
    }
}
