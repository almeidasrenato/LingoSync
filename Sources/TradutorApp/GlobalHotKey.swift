import AppKit
import Carbon.HIToolbox

/// Atalho global via Carbon.
///
/// O pacote KeyboardShortcuts seria mais confortavel, mas ele usa a macro
/// `#Preview`, que exige um plugin que so vem com o Xcode completo. Como aqui
/// so ha Command Line Tools, o caminho nativo sai mais barato que a dependencia:
/// `RegisterEventHotKey` e a mesma API que aquele pacote chama por baixo.
@MainActor
final class GlobalHotKey {

    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void

    /// Padrao: ⌥⌘T. Trocar aqui muda o atalho do app inteiro.
    static let defaultKeyCode = UInt32(kVK_ANSI_T)
    static let defaultModifiers = UInt32(optionKey | cmdKey)

    static let displayName = "⌥⌘T"

    private static var active: GlobalHotKey?

    init(
        keyCode: UInt32 = GlobalHotKey.defaultKeyCode,
        modifiers: UInt32 = GlobalHotKey.defaultModifiers,
        action: @escaping () -> Void
    ) {
        self.action = action
        Self.active = self

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, _ in
                Task { @MainActor in GlobalHotKey.active?.action() }
                return noErr
            },
            1,
            &eventType,
            nil,
            &handler
        )

        var hotKeyID = EventHotKeyID(signature: OSType(0x54524144), id: 1)  // 'TRAD'
        RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &reference
        )
    }

    deinit {
        if let reference { UnregisterEventHotKey(reference) }
        if let handler { RemoveEventHandler(handler) }
    }
}
