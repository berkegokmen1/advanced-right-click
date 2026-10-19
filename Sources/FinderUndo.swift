import AppKit
import ApplicationServices

/// A narrow, opt-in bridge: only the very next Finder interaction may be ⌘Z.
/// Any click, other key, scroll, app switch, timeout or in-flight action disarms it.
/// This does not register entries in Finder's private native undo stack.
final class FinderUndoBridge {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var deadline: Date?
    private var action: (() -> Void)?
    private var observer: NSObjectProtocol?
    var available: Bool { tap != nil }
    func enable(prompt: Bool) -> Bool {
        if tap != nil { return true }
        if !AXIsProcessTrusted() {
            if prompt { _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary) }
            return false
        }
        let mask = [CGEventType.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel].reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let bridge = Unmanaged<FinderUndoBridge>.fromOpaque(context).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput { bridge.disarm(); if let tap = bridge.tap { CGEvent.tapEnable(tap: tap, enable: true) }; return Unmanaged.passUnretained(event) }
            guard let deadline = bridge.deadline, Date() < deadline, NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder" else { bridge.disarm(); return Unmanaged.passUnretained(event) }
            let flags = event.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])
            let undo = type == .keyDown && event.getIntegerValueField(.keyboardEventKeycode) == 6 && flags == .maskCommand
            let action = bridge.action; bridge.disarm()
            if undo { DispatchQueue.main.async { action?() }; return nil }
            return Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap else { return false }
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes); CGEvent.tapEnable(tap: tap, enable: true)
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in self?.disarm() }
        return true
    }
    func arm(_ action: @escaping () -> Void) {
        guard available, NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder" else { return }
        self.action = action; deadline = Date().addingTimeInterval(30)
    }
    func disarm() { deadline = nil; action = nil }
    func disable() {
        disarm()
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        source = nil; tap = nil; observer = nil
    }
    deinit { disable() }
}
