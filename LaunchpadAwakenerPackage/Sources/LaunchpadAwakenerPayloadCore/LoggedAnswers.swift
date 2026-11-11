import Synchronization

/// The answer logged last time under each name, so that logging the same answer again can be quieter.
///
/// Some answers are worked out over and over: the control panel asks the payload for its status every
/// few seconds for as long as it is open, and every ask scans the host's data sections afresh. Logging
/// each of those answers where it persists would bury everything else in the log, while logging none of
/// them would leave no record of the moment an answer changed. So the first answer under a name, and
/// every change after it, is logged as news; the repeats go to the debug level, which `log show --debug`
/// still shows when the question is whether the work happened at all.
///
/// Answers are kept per name rather than one to an instance so that a single caller can keep several
/// apart — one per class it looks for.
final class LoggedAnswers: Sendable {
    private let answers = Mutex<[String: String]>([:])

    init() {}

    /// Records `answer` under `name` and returns the answer it replaced, which is nil the first time.
    ///
    /// Shaped after `Dictionary.updateValue(_:forKey:)`: the caller compares what comes back with what it
    /// is about to log, and treats the two differing as news.
    @discardableResult
    func updateAnswer(_ answer: String, forName name: String) -> String? {
        answers.withLock { answers in
            answers.updateValue(answer, forKey: name)
        }
    }
}
