import Carbon.HIToolbox
import Foundation

private let stowHotKeySignature: OSType = 0x53544F57 // STOW
private let stowHotKeyIdentifier: UInt32 = 1

private func stowEmergencyHotKeyHandler(
    _: EventHandlerCallRef?,
    event: EventRef?,
    _: UnsafeMutableRawPointer?
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
        &identifier)
    guard status == noErr,
          identifier.signature == stowHotKeySignature,
          identifier.id == stowHotKeyIdentifier else {
        return OSStatus(eventNotHandledErr)
    }
    DispatchQueue.main.async {
        MainActor.assumeIsolated { EmergencyHotKey.shared.perform() }
    }
    return noErr
}

/// A process-wide, native global shortcut that always restores the visible menu bar.
///
/// Carbon hotkeys do not require a focused window or an event monitor, so this remains
/// available when Stow's own panel and icon are unreachable.
@MainActor
final class EmergencyHotKey {
    static let shared = EmergencyHotKey()

    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var action: (() -> Void)?

    private init() {}

    @discardableResult
    func register(action: @escaping () -> Void) -> Bool {
        self.action = action
        if hotKey != nil { return true }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed))
        guard InstallEventHandler(
            GetApplicationEventTarget(),
            stowEmergencyHotKeyHandler,
            1,
            &eventType,
            nil,
            &handler) == noErr else { return false }

        let identifier = EventHotKeyID(
            signature: stowHotKeySignature,
            id: stowHotKeyIdentifier)
        let modifiers = UInt32(cmdKey | shiftKey)
        guard RegisterEventHotKey(
            UInt32(kVK_Escape),
            modifiers,
            identifier,
            GetApplicationEventTarget(),
            0,
            &hotKey) == noErr else {
            if let handler { RemoveEventHandler(handler) }
            handler = nil
            return false
        }
        return true
    }

    var isRegistered: Bool { hotKey != nil }

    fileprivate func perform() {
        action?()
    }
}
