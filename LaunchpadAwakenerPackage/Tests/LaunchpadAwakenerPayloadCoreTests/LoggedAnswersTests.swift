@testable import LaunchpadAwakenerPayloadCore
import Testing

/// Deciding whether an answer is worth a line in the log.
///
/// The level a line ends up at cannot be observed from a test — `os_log` keeps no record a process can
/// read back — so what is tested is the decision every log site makes with this: an answer that differs
/// from the one recorded before is news, a repeat is not.
@Suite("Logging an answer only when it changes")
struct LoggedAnswersTests {
    @Test("The first answer under a name is news")
    func firstAnswerIsNews() {
        let loggedAnswers = LoggedAnswers()

        #expect(loggedAnswers.updateAnswer("found in __DATA,__common, 1 slot(s)", forName: "DockBar") == nil)
    }

    @Test("The same answer again is not news")
    func repeatedAnswerIsNotNews() {
        let loggedAnswers = LoggedAnswers()
        let answer = "found in __DATA,__common, 1 slot(s)"
        loggedAnswers.updateAnswer(answer, forName: "DockBar")

        #expect(loggedAnswers.updateAnswer(answer, forName: "DockBar") == answer)
    }

    @Test("A changed answer is news, and hands back the answer it replaced")
    func changedAnswerIsNews() {
        let loggedAnswers = LoggedAnswers()
        loggedAnswers.updateAnswer("found in __DATA,__common, 1 slot(s)", forName: "DockBar")

        #expect(loggedAnswers.updateAnswer("not found", forName: "DockBar") == "found in __DATA,__common, 1 slot(s)")
    }

    @Test("Once an answer has changed, the new one is what the next answer is compared against")
    func changedAnswerIsTheOneComparedAgainstNext() {
        let loggedAnswers = LoggedAnswers()
        loggedAnswers.updateAnswer("found in __DATA,__common, 1 slot(s)", forName: "DockBar")
        loggedAnswers.updateAnswer("not found", forName: "DockBar")

        #expect(loggedAnswers.updateAnswer("not found", forName: "DockBar") == "not found")
    }

    @Test("Two names keep their answers apart")
    func namesKeepTheirAnswersApart() {
        let loggedAnswers = LoggedAnswers()
        loggedAnswers.updateAnswer("found in __DATA,__common, 1 slot(s)", forName: "DockBar")

        #expect(loggedAnswers.updateAnswer("found in __DATA,__common, 1 slot(s)", forName: "DockGlobals") == nil)
    }
}
