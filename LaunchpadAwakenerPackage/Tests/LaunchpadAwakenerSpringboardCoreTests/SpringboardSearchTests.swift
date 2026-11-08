import Foundation
import LaunchpadAwakenerSpringboardCore
import Testing

/// Cases follow the rule in section 4.5 of the macOS 15.5 specification: a match must start the title,
/// start a word, or spell the words' initials — never sit in the middle of a word.
@Suite("Searching by macOS 15's rule")
struct SpringboardSearchTests {
    @Test(
        "matches",
        arguments: [
            ("Safari", "saf"),
            ("Visual Studio Code", "stu"),
            ("Visual Studio Code", "vsc"),
            ("GarageBand", "gb"),
            ("GarageBand", "band"),
            ("iMovie", "mov"),
            ("Font Book", "font b"),
            ("Font Book", "fontb"),
            ("Café", "cafe"),
            ("A B C Tool", "at"),
        ]
    )
    func titleMatches(title: String, term: String) {
        #expect(SpringboardSearch.title(title, matches: term))
    }

    @Test(
        "does not match",
        arguments: [
            ("Safari", "fari"),
            ("Visual Studio Code", "tudio"),
            ("Visual Studio Code", "vcs"),
            ("Gmail", "mail"),
            ("Safari", " "),
        ]
    )
    func titleDoesNotMatch(title: String, term: String) {
        #expect(!SpringboardSearch.title(title, matches: term))
    }

    @Test("words split camel case and join runs of single capitals")
    func words() {
        #expect(SpringboardSearch.words(of: "iMovie") == ["i", "Movie"])
        #expect(SpringboardSearch.words(of: "A B C Tool") == ["ABC", "Tool"])
    }

    @Test("results come in layout order, folders opened in place, and fall back to the file name")
    func resultsFollowLayoutOrder() {
        func application(_ rowIdentifier: Int64, _ title: String) -> LaunchpadApplication {
            LaunchpadApplication(
                identifier: LaunchpadItemIdentifier(rowIdentifier: rowIdentifier),
                title: title,
                bundleIdentifier: "com.example.\(rowIdentifier)",
                bookmarkData: nil,
                legacyIconPNGData: nil
            )
        }
        let layout = LaunchpadLayout(pages: [
            LaunchpadPage(identifier: LaunchpadItemIdentifier(rowIdentifier: 1), items: [
                .application(application(10, "Calendar")),
                .folder(LaunchpadFolder(
                    identifier: LaunchpadItemIdentifier(rowIdentifier: 11),
                    title: "Tools",
                    pages: [LaunchpadFolderPage(identifier: LaunchpadItemIdentifier(rowIdentifier: 12), applications: [application(13, "Calculator")])]
                )),
            ]),
            LaunchpadPage(identifier: LaunchpadItemIdentifier(rowIdentifier: 2), items: [
                .application(application(20, "代码")),
                .application(application(21, "Camera")),
            ]),
        ])
        let fileNames = [LaunchpadItemIdentifier(rowIdentifier: 20): "Code Editor"]

        let results = SpringboardSearch.applications(matching: "ca", in: layout) { fileNames[$0.identifier] }
        let codeResults = SpringboardSearch.applications(matching: "code", in: layout) { fileNames[$0.identifier] }

        #expect(results.map(\.title) == ["Calendar", "Calculator", "Camera"])
        #expect(codeResults.map(\.title) == ["代码"])
    }
}
