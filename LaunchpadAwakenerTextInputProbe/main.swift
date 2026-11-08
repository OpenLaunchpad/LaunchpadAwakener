// Throwaway probe for the input method proposal (step 1); lives only on experiment/input-method-probe.
//
// Hosts one text field in the Dock tile's mini view window, which never goes on screen but can be key,
// the way macOS 15's com.apple.dock.ecti service did. Writes what the Dock needs to show the field to
// /tmp/claude-textinput-probe.json and every change of the field to /tmp/claude-textinput-probe.log.
//
// Build: xcrun swiftc -target arm64-apple-macos27.0 -framework AppKit main.swift -o <bundle>/Contents/MacOS/LaunchpadAwakenerTextInputProbe
// Run:   open <bundle> --args <left> <top>   (the field's top-left corner on screen, in points from the top left)
import AppKit

final class ProbeApplication: NSApplication {
    // The ecti helper answered both with 0, so AppKit takes its non-activating window for the key window
    // and itself for the active application.
    @objc(_stealKeyFocusWithOptions:)
    func probeStealKeyFocus(withOptions options: UInt32) -> Int32 {
        appendToLog("steal key focus \(options)")
        return 0
    }

    @objc(_releaseKeyFocus)
    func probeReleaseKeyFocus() -> Int32 {
        appendToLog("release key focus")
        return 0
    }
}

final class ProbeFieldDelegate: NSObject, NSTextFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        guard let textField = notification.object as? NSTextField else { return }
        let fieldEditor = textField.currentEditor() as? NSTextView
        let markedRange = fieldEditor?.markedRange() ?? NSRange(location: NSNotFound, length: 0)
        appendToLog("string=\(textField.stringValue) marked=\(markedRange.location == NSNotFound ? "none" : NSStringFromRange(markedRange))")
    }
}

func appendToLog(_ line: String) {
    let path = "/tmp/claude-textinput-probe.log"
    let data = Data((line + "\n").utf8)
    if let handle = FileHandle(forWritingAtPath: path) {
        handle.seekToEndOfFile()
        handle.write(data)
        try? handle.close()
    } else {
        FileManager.default.createFile(atPath: path, contents: data)
    }
}

let application = ProbeApplication.shared
application.setActivationPolicy(.accessory)

typealias RemoteViewActivationFunction = @convention(c) (UInt8) -> Void
typealias RemoteViewClientRegistrationFunction = @convention(c) (UInt32) -> Void
let processHandle = dlopen(nil, RTLD_NOW)
if let symbol = dlsym(processHandle, "_TSMSetRemoteViewActivation") {
    unsafeBitCast(symbol, to: RemoteViewActivationFunction.self)(1)
    appendToLog("remote view activation on")
}
if let symbol = dlsym(processHandle, "_TSMRegisterRemoteViewClient") {
    unsafeBitCast(symbol, to: RemoteViewClientRegistrationFunction.self)(1)
    appendToLog("remote view client registered")
}

let fieldSize = NSSize(width: 480, height: 24)
let containerView = NSView(frame: NSRect(origin: .zero, size: fieldSize))
let textField = NSTextField(frame: containerView.bounds)
textField.isBordered = false
textField.isBezeled = false
textField.drawsBackground = false
textField.focusRingType = .none
textField.font = .systemFont(ofSize: 15)
textField.textColor = .white
textField.stringValue = "probe"
let fieldDelegate = ProbeFieldDelegate()
textField.delegate = fieldDelegate
containerView.addSubview(textField)

application.dockTile.setValue(containerView, forKey: "miniView")
// The ecti service put the mini view window at Launchpad's level, 27.
typealias SetLevelFunction = @convention(c) (AnyObject, Selector, Int) -> Void
let setLevelSelector = NSSelectorFromString("_setMiniViewWindowLevel:")
if let setLevelMethod = class_getInstanceMethod(object_getClass(application.dockTile), setLevelSelector) {
    unsafeBitCast(method_getImplementation(setLevelMethod), to: SetLevelFunction.self)(application.dockTile, setLevelSelector, 27)
    appendToLog("mini view window level 27")
}
guard let window = containerView.window else {
    appendToLog("no mini view window")
    exit(1)
}
let arguments = CommandLine.arguments.dropFirst().compactMap { Double($0) }
if arguments.count == 2, let screenFrame = NSScreen.screens.first?.frame {
    // Candidate windows are placed from the window's screen position.
    window.setFrameOrigin(NSPoint(x: arguments[0], y: screenFrame.maxY - arguments[1] - fieldSize.height))
}
// The Dock used to tell AppKit the mini view was shown; 27.2's no longer does, so say it here.
typealias SetShownFunction = @convention(c) (AnyObject, Selector, Bool) -> Void
let setShownSelector = NSSelectorFromString("_setMiniViewShown:")
if let setShownMethod = class_getInstanceMethod(object_getClass(application.dockTile), setShownSelector) {
    unsafeBitCast(method_getImplementation(setShownMethod), to: SetShownFunction.self)(application.dockTile, setShownSelector, true)
    appendToLog("mini view shown")
}
window.makeKeyAndOrderFront(nil)
// With the focus overrides answering 0, this makes the window that never goes on screen the key window.
window.makeKey()
window.makeFirstResponder(textField)
textField.selectText(nil)
appendToLog("after makeKey: key=\(window.isKeyWindow) keyWindow=\(String(describing: application.keyWindow.map { type(of: $0) }))")

let context = window.value(forKey: "_contextForLayerHosting") as? NSObject
let contextIdentifier = (context?.value(forKey: "contextId") as? NSNumber)?.uint32Value ?? 0
let report: [String: Any] = [
    "pid": Int(ProcessInfo.processInfo.processIdentifier),
    "contextId": Int(contextIdentifier),
    "windowNumber": window.windowNumber,
]
if let reportData = try? JSONSerialization.data(withJSONObject: report) {
    FileManager.default.createFile(atPath: "/tmp/claude-textinput-probe.json", contents: reportData)
}
appendToLog("window=\(String(describing: type(of: window))) key=\(window.isKeyWindow) frame=\(NSStringFromRect(window.frame)) context=\(contextIdentifier)")
DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
    appendToLog("a second later: key=\(window.isKeyWindow) active=\(application.isActive) firstResponder=\(String(describing: window.firstResponder.map { type(of: $0) }))")
}
application.run()
