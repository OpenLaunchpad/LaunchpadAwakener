import CoreGraphics

extension SpringboardInputEvent {
    /// Copies what the springboard needs out of an event the Dock received.
    ///
    /// `eventType` is the `CGEventType` the Dock passes alongside the event in
    /// `-[DockAppEventHandler handleDockBarEvent:type:]`.
    init(event: CGEvent, eventType: UInt32) {
        location = event.location
        modifierFlags = event.flags
        timestamp = event.timestamp
        switch CGEventType(rawValue: eventType) {
        case .keyDown?:
            var characterCount = 0
            var characterBuffer = [UniChar](repeating: 0, count: 8)
            event.keyboardGetUnicodeString(
                maxStringLength: characterBuffer.count,
                actualStringLength: &characterCount,
                unicodeString: &characterBuffer
            )
            kind = .keyDown(
                keyCode: event.getIntegerValueField(.keyboardEventKeycode),
                characters: String(utf16CodeUnits: characterBuffer, count: characterCount),
                isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            )
        case .keyUp?:
            kind = .keyUp(keyCode: event.getIntegerValueField(.keyboardEventKeycode))
        case .flagsChanged?:
            kind = .modifiersChanged
        case .leftMouseDown?:
            kind = .mouseDown(.left, clickCount: event.getIntegerValueField(.mouseEventClickState))
        case .rightMouseDown?:
            kind = .mouseDown(.right, clickCount: event.getIntegerValueField(.mouseEventClickState))
        case .otherMouseDown?:
            kind = .mouseDown(.other, clickCount: event.getIntegerValueField(.mouseEventClickState))
        case .leftMouseUp?:
            kind = .mouseUp(.left)
        case .rightMouseUp?:
            kind = .mouseUp(.right)
        case .otherMouseUp?:
            kind = .mouseUp(.other)
        case .leftMouseDragged?:
            kind = .mouseDragged(.left)
        case .rightMouseDragged?:
            kind = .mouseDragged(.right)
        case .otherMouseDragged?:
            kind = .mouseDragged(.other)
        case .mouseMoved?:
            kind = .mouseMoved
        case .scrollWheel?:
            kind = .scrollWheel(
                ScrollWheel(
                    horizontalDelta: event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2),
                    verticalDelta: event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1),
                    horizontalLineDelta: event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2),
                    verticalLineDelta: event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1),
                    isContinuous: event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0,
                    scrollPhase: event.getIntegerValueField(.scrollWheelEventScrollPhase),
                    momentumPhase: event.getIntegerValueField(.scrollWheelEventMomentumPhase)
                )
            )
        default:
            kind = .other(eventType: eventType)
        }
    }
}
