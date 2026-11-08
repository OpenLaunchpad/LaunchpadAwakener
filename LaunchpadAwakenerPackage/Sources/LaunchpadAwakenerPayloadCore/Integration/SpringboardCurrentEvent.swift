import CoreGraphics

/// The event the springboard is handling, as it came, for the text input helper: the keys and clicks
/// that go to a hosted field are posted to it unchanged. The event hook sets it around each call into the
/// springboard, on the main thread only.
enum SpringboardCurrentEvent {
    nonisolated(unsafe) static var event: CGEvent?
}
