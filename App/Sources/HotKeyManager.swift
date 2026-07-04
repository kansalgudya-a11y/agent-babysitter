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

    func register() {
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
        RegisterEventHotKey(UInt32(kVK_ANSI_B),
                            UInt32(optionKey | cmdKey),
                            hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
        hotKeyRef = nil
        handlerRef = nil
    }
}
