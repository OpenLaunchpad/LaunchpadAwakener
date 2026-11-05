import Foundation
import LaunchpadAwakenerPayloadCore
import Testing
import TestingSupport

@Suite("Legacy database fixture")
struct LegacyLaunchpadDatabaseFixtureTests {
    @Test("the holding page is the root's first page, as macOS 15 left it")
    func holdingPageComesFirst() throws {
        try withTemporaryDirectory { directoryURL in
            let databaseURL = directoryURL.appendingPathComponent("legacy.db")
            try LegacyLaunchpadDatabaseFixture(pages: [[.application(title: "Alpha", bundleIdentifier: "com.example.alpha")]])
                .write(to: databaseURL)

            let database = try SQLiteDatabase(path: databaseURL.path, mode: .readOnly)
            let rootPageUUIDs = try database.rows(
                """
                SELECT uuid FROM items
                WHERE type = 3 AND parent_id = (SELECT value FROM dbinfo WHERE key = 'launchpad_root')
                ORDER BY ordering
                """
            ).compactMap { $0.first?.textValue }
            #expect(rootPageUUIDs.count == 2)
            #expect(rootPageUUIDs.first == "HOLDINGPAGE")
        }
    }

    @Test("the ordering triggers are switched back on once written")
    func triggersAreEnabledAfterWriting() throws {
        try withTemporaryDirectory { directoryURL in
            let databaseURL = directoryURL.appendingPathComponent("legacy.db")
            try LegacyLaunchpadDatabaseFixture(pages: []).write(to: databaseURL)

            let database = try SQLiteDatabase(path: databaseURL.path, mode: .readOnly)
            let triggerSwitch = try database.rows("SELECT value FROM dbinfo WHERE key = 'ignore_items_update_triggers'").first?.first
            #expect(triggerSwitch?.integerValue == 0)
        }
    }
}
