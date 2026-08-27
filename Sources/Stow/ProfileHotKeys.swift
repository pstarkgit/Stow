import Carbon.HIToolbox
import Foundation
import AppKit

private let profileHotKeySignature: OSType = 0x53545046 // STPF

private func profileHotKeyHandler(
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
    guard status == noErr, identifier.signature == profileHotKeySignature else {
        return OSStatus(eventNotHandledErr)
    }
    DispatchQueue.main.async {
        MainActor.assumeIsolated { ProfileHotKeys.shared.perform(id: identifier.id) }
    }
    return noErr
}

/// Process-wide Command-Shift-1…4 shortcuts for Stow's four named profiles.
@MainActor
final class ProfileHotKeys {
    static let shared = ProfileHotKeys()

    private var handler: EventHandlerRef?
    private var hotKeys: [EventHotKeyRef] = []
    private var actions: [UInt32: () -> Void] = [:]
    private(set) var registeredProfileIDs: Set<String> = []

    private init() {}

    @discardableResult
    func register(
        profiles: [Config.Profile],
        action: @escaping (Config.Profile) -> Void
    ) -> Int {
        unregisterHotKeys()
        guard installHandler() else { return 0 }

        let keyCodes: [UInt32] = [
            UInt32(kVK_ANSI_1), UInt32(kVK_ANSI_2),
            UInt32(kVK_ANSI_3), UInt32(kVK_ANSI_4),
        ]
        for (index, profile) in profiles.prefix(keyCodes.count).enumerated() {
            let id = UInt32(index + 1)
            var reference: EventHotKeyRef?
            let status = RegisterEventHotKey(
                keyCodes[index],
                UInt32(cmdKey | shiftKey),
                EventHotKeyID(signature: profileHotKeySignature, id: id),
                GetApplicationEventTarget(),
                0,
                &reference)
            guard status == noErr, let reference else { continue }
            hotKeys.append(reference)
            actions[id] = { action(profile) }
            registeredProfileIDs.insert(profile.id)
        }
        return registeredProfileIDs.count
    }

    var registeredCount: Int { registeredProfileIDs.count }

    nonisolated static func keyCode(at index: Int) -> UInt32? {
        let keyCodes: [UInt32] = [
            UInt32(kVK_ANSI_1), UInt32(kVK_ANSI_2),
            UInt32(kVK_ANSI_3), UInt32(kVK_ANSI_4),
        ]
        return keyCodes.indices.contains(index) ? keyCodes[index] : nil
    }

    private func installHandler() -> Bool {
        if handler != nil { return true }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed))
        return InstallEventHandler(
            GetApplicationEventTarget(),
            profileHotKeyHandler,
            1,
            &eventType,
            nil,
            &handler) == noErr
    }

    private func unregisterHotKeys() {
        hotKeys.forEach { UnregisterEventHotKey($0) }
        hotKeys.removeAll()
        actions.removeAll()
        registeredProfileIDs.removeAll()
    }

    fileprivate func perform(id: UInt32) {
        guard let action = actions[id] else { return }
        Task { @MainActor in
            // Carbon reports the hotkey while Command and Shift are still physically down.
            // ItemMover intentionally refuses synthetic drags with modifiers held, so wait for
            // the matching key-up before applying the profile rather than weakening that guard.
            for _ in 0..<20 {
                if NSEvent.modifierFlags
                    .intersection(.deviceIndependentFlagsMask).isEmpty { break }
                try? await Task.sleep(for: .milliseconds(25))
            }
            guard NSEvent.modifierFlags
                .intersection(.deviceIndependentFlagsMask).isEmpty else { return }
            action()
        }
    }
}
