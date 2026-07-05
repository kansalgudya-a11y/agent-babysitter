import AppKit
import Carbon.HIToolbox
import AgentBabysitterCore

/// One global hotkey — ⌥⌘B — that jumps straight to the session that most
/// needs you (waiting > stalled > working > done). Registered via Carbon's
/// RegisterEventHotKey: zero dependencies, works without accessibility
/// permission, and only fires on the exact chord.
@MainActor
final class HotKeyManager {

    /// Returns the neediest row to focus, or nil to do nothing.
    var target: (@MainActor () -> SessionRow?)?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    /// The offered chords; a full key-recorder can come later.
    static let combos: [(id: String, label: String, keyCode: UInt32, modifiers: UInt32)] = [
        ("opt-cmd-b", "⌥⌘B", UInt32(kVK_ANSI_B), UInt32(optionKey | cmdKey)),
        ("ctrl-opt-cmd-b", "⌃⌥⌘B", UInt32(kVK_ANSI_B), UInt32(controlKey | optionKey | cmdKey)),
        ("opt-cmd-j", "⌥⌘J", UInt32(kVK_ANSI_J), UInt32(optionKey | cmdKey)),
    ]

    func register(comboID: String = "opt-cmd-b") {
        unregister()
        let combo = Self.combos.first { $0.id == comboID } ?? Self.combos[0]
        registerChord(keyCode: combo.keyCode, modifiers: combo.modifiers)
    }

    private func registerChord(keyCode: UInt32, modifiers: UInt32) {
        guard hotKeyRef == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
            Task { @MainActor in
                if let row = manager.target?() {
                    TerminalFocuser.focusSession(row)
                }
            }
            return noErr
        }, 1, &eventType, selfPointer, &handlerRef)

        let hotKeyID = EventHotKeyID(signature: OSType(0x4142_5359),  // "ABSY"
                                     id: 1)
        RegisterEventHotKey(keyCode, modifiers,
                            hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
        hotKeyRef = nil
        handlerRef = nil
    }
}
