import Foundation
import Testing
import TestingSupport

@Suite("Fixture helpers")
struct FixtureHelperTests {
    @Test("a bundle fixture reads back as a bundle with its identifier")
    func bundleFixtureIsABundle() throws {
        try withTemporaryDirectory { directoryURL in
            let bundleURL = try ApplicationBundleFixture(name: "Alpha", bundleIdentifier: "com.example.alpha").write(in: directoryURL)

            #expect(Bundle(url: bundleURL)?.bundleIdentifier == "com.example.alpha")
        }
    }

    @Test("the temporary directory is gone once the body returns")
    func temporaryDirectoryIsRemoved() throws {
        let directoryURL = try withTemporaryDirectory { directoryURL in directoryURL }

        #expect(!FileManager.default.fileExists(atPath: directoryURL.path))
    }
}
