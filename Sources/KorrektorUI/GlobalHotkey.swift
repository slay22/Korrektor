import AppKit
import Carbon.HIToolbox
import KorrektorCore

private let korrektorHotKeySignature: OSType = 0x4B4F5252 // 'KORR'

/// System-wide shortcut registration through Carbon's `RegisterEventHotKey`.
///
/// Carbon is old, but it is still the only API that registers a shortcut which
/// works in every app, swallows the key press, and needs no Accessibility
/// permission of its own.
@MainActor
final class HotkeyRegistrar {
    static let shared = HotkeyRegistrar()

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var action: (() -> Void)?

    /// Registers the shortcut, replacing any previous one.
    ///
    /// Returns false when the combination is already taken by macOS or another
    /// app, so the caller can say so instead of failing silently.
    @discardableResult
    func register(_ hotkey: Hotkey, action: @escaping () -> Void) -> Bool {
        unregister()
        guard hotkey.isValid else { return false }

        self.action = action
        installHandlerIfNeeded()

        var ref: EventHotKeyRef?
        let identifier = EventHotKeyID(signature: korrektorHotKeySignature, id: 1)
        let status = RegisterEventHotKey(
            UInt32(hotkey.keyCode),
            carbonModifiers(for: hotkey.modifiers),
            identifier,
            GetApplicationEventTarget(),
            0,
            &ref
        )

        guard status == noErr, let ref else {
            self.action = nil
            return false
        }
        hotKeyRef = ref
        return true
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        hotKeyRef = nil
        action = nil
    }

    fileprivate func fire() {
        action?()
    }

    private func carbonModifiers(for modifiers: Hotkey.Modifiers) -> UInt32 {
        var value: UInt32 = 0
        if modifiers.contains(.command) { value |= UInt32(cmdKey) }
        if modifiers.contains(.option) { value |= UInt32(optionKey) }
        if modifiers.contains(.control) { value |= UInt32(controlKey) }
        if modifiers.contains(.shift) { value |= UInt32(shiftKey) }
        return value
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        InstallEventHandler(
            GetApplicationEventTarget(),
            korrektorHotkeyCallback,
            1,
            &eventType,
            nil,
            &handlerRef
        )
    }
}

/// Carbon calls this on the main thread, but a C callback cannot be isolated to
/// the main actor, so it hops over explicitly.
private func korrektorHotkeyCallback(
    _ callRef: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event else { return OSStatus(eventNotHandledErr) }

    var identifier = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &identifier
    )
    guard status == noErr, identifier.signature == korrektorHotKeySignature else {
        return OSStatus(eventNotHandledErr)
    }

    DispatchQueue.main.async {
        MainActor.assumeIsolated {
            HotkeyRegistrar.shared.fire()
        }
    }
    return noErr
}
