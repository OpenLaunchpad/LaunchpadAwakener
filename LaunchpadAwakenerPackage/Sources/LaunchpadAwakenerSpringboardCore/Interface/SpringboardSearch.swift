import Foundation

/// macOS 15.5's search rule, `-[Springboard _wordFromTitle:matchesTerm:]` (`0x1000978E8`) and the
/// helpers it calls: every comparison ignores case and diacritics and must match from the start —
/// of the title, of a word, or of a word's initial. Never an arbitrary substring.
package enum SpringboardSearch {
    private static let comparisonOptions: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .anchored]

    /// Applications matching `term`, in layout order — page by page, a folder's applications in its
    /// place. An application matches by its title or, failing that, by its file name when that differs.
    package static func applications(
        matching term: String,
        in layout: LaunchpadLayout,
        fileNameOf fileName: (LaunchpadApplication) -> String?
    ) -> [LaunchpadApplication] {
        guard !term.isEmpty else { return [] }
        return layout.applications.filter { application in
            if title(application.title, matches: term) {
                return true
            }
            guard let applicationFileName = fileName(application), applicationFileName != application.title else { return false }
            return title(applicationFileName, matches: term)
        }
    }

    package static func title(_ title: String, matches term: String) -> Bool {
        matchesExactly(title: title, term: term) || matchesExactly(title: title.lowercased(), term: term)
    }

    private static func matchesExactly(title: String, term: String) -> Bool {
        let termWithoutSpaces = term.replacingOccurrences(of: " ", with: "")
        guard !termWithoutSpaces.isEmpty else { return false }

        if hasPrefix(title, term) {
            return true
        }
        let titleWords = words(of: title)
        if titleWords.contains(where: { hasPrefix($0, term) }) {
            return true
        }
        let termCharacters = Array(termWithoutSpaces)
        if termCharacters.count >= 2, termCharacters.count <= titleWords.count,
           termCharacters.indices.allSatisfy({ hasPrefix(titleWords[$0], String(termCharacters[$0])) })
        {
            return true
        }
        if hasPrefix(title, termWithoutSpaces) {
            return true
        }
        return hasPrefix(title.replacingOccurrences(of: " ", with: ""), termWithoutSpaces)
    }

    /// The title's words: split as the system splits words, then camel case taken apart (`iMovie` is
    /// `i` and `Movie`), then runs of single capital letters joined again (`A B C` is `ABC`).
    package static func words(of title: String) -> [String] {
        var systemWords: [String] = []
        title.enumerateSubstrings(in: title.startIndex..., options: [.byWords, .localized]) { substring, _, _, _ in
            if let substring {
                systemWords.append(substring)
            }
        }
        let camelCaseWords = systemWords.flatMap { word in
            word.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
                .split(separator: " ")
                .map(String.init)
        }

        var joinedWords: [String] = []
        var isJoiningCapitals = false
        for word in camelCaseWords {
            let isSingleCapital = word.count == 1 && word.unicodeScalars.allSatisfy(CharacterSet.uppercaseLetters.contains)
            if isSingleCapital, isJoiningCapitals, let lastIndex = joinedWords.indices.last {
                joinedWords[lastIndex] += word
            } else {
                joinedWords.append(word)
            }
            isJoiningCapitals = isSingleCapital
        }
        return joinedWords
    }

    private static func hasPrefix(_ string: String, _ prefix: String) -> Bool {
        string.range(of: prefix, options: comparisonOptions) != nil
    }
}
