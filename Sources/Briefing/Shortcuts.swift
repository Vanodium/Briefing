import AppKit
import Carbon.HIToolbox
import SwiftUI

// MARK: - A key combination

/// One key plus modifiers. Stored as the physical key (key code), not the character,
/// so E stays E on any keyboard layout.
struct KeyCombo: Codable, Hashable {
    var keyCode: UInt16
    /// NSEvent.ModifierFlags raw value, only ⌘ ⌥ ⌃ ⇧.
    var modifiers: UInt

    static let relevant: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) {
        self.keyCode = Self.canonical(keyCode)
        self.modifiers = modifiers.intersection(Self.relevant).rawValue
    }

    init(event: NSEvent) {
        self.init(keyCode: event.keyCode, modifiers: event.modifierFlags)
    }

    /// The keypad Enter counts as Return.
    static func canonical(_ code: UInt16) -> UInt16 {
        code == UInt16(kVK_ANSI_KeypadEnter) ? UInt16(kVK_Return) : code
    }

    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers).intersection(Self.relevant) }

    /// ⌘, ⌥ or ⌃ — Shift alone does not make a key safe to grab system-wide.
    var hasModifier: Bool { !flags.intersection([.command, .option, .control]).isEmpty }

    var carbonModifiers: Int {
        var m = 0
        if flags.contains(.command) { m |= cmdKey }
        if flags.contains(.option) { m |= optionKey }
        if flags.contains(.control) { m |= controlKey }
        if flags.contains(.shift) { m |= shiftKey }
        return m
    }

    /// In the order macOS prints them: ⌃ ⌥ ⇧ ⌘.
    var modifierSymbols: String {
        var s = ""
        if flags.contains(.control) { s += "\u{2303}" }
        if flags.contains(.option) { s += "\u{2325}" }
        if flags.contains(.shift) { s += "\u{21E7}" }
        if flags.contains(.command) { s += "\u{2318}" }
        return s
    }

    var keyName: String { Self.name(for: keyCode) }

    /// "E", "Enter", "⌃⌥⌘M".
    var display: String { modifierSymbols + keyName }

    /// For an NSMenuItem: the character (lower case) and the modifier mask.
    var menuKeyEquivalent: String {
        if let named = Self.menuNames[Int(keyCode)] { return named }
        return Self.character(for: keyCode)?.lowercased() ?? ""
    }

    // MARK: Names

    private static let names: [Int: String] = [
        kVK_Return: "Enter", kVK_Space: "Space", kVK_Escape: "Esc", kVK_Tab: "Tab",
        kVK_Delete: "Delete", kVK_ForwardDelete: "\u{2326}",
        kVK_LeftArrow: "\u{2190}", kVK_RightArrow: "\u{2192}", kVK_DownArrow: "\u{2193}", kVK_UpArrow: "\u{2191}",
        kVK_Home: "Home", kVK_End: "End", kVK_PageUp: "Page Up", kVK_PageDown: "Page Down",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]

    private static let menuNames: [Int: String] = [
        kVK_Return: "\r", kVK_Space: " ", kVK_Escape: "\u{1B}", kVK_Tab: "\t",
    ]

    static func name(for code: UInt16) -> String {
        if let n = names[Int(code)] { return n }
        return character(for: code) ?? "Key \(code)"
    }

    /// The character a key types on the current Latin layout — so E reads "E", not "У", on a Russian keyboard.
    static func character(for code: UInt16) -> String? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let layoutData = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        var deadKeys: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let status: OSStatus = layoutData.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return OSStatus(-1) }
            let layout = base.assumingMemoryBound(to: UCKeyboardLayout.self)
            return UCKeyTranslate(layout, code, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKeys,
                                  4, &length, &chars)
        }
        guard status == noErr, length > 0 else { return nil }
        let s = String(utf16CodeUnits: chars, count: length).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s.uppercased()
    }
}

// MARK: - Actions

enum ShortcutAction: String, CaseIterable, Identifiable {
    case toggle, advance, close, amend, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .toggle: return "Show or hide Briefing"
        case .advance: return "Open the day, then sign & begin"
        case .close: return "Close"
        case .amend: return "Amend principles and challenges"
        case .settings: return "Open Settings"
        }
    }

    /// Hint labels on the dashboard.
    var hint: String {
        switch self {
        case .toggle: return "Show / hide"
        case .advance: return "Sign & begin"
        case .close: return "Close"
        case .amend: return "Amend"
        case .settings: return "Settings"
        }
    }

    var note: String? {
        switch self {
        case .toggle: return "Works everywhere, even when Briefing is closed."
        case .advance: return "The first press opens the day, the second one closes it."
        default: return nil
        }
    }

    var isGlobal: Bool { self == .toggle }

    /// How many keys an action can have: a main one and, for the dashboard keys, an alternative.
    var maxCombos: Int { (self == .toggle || self == .settings) ? 1 : 2 }

    /// The actions handled inside the dashboard.
    static let local: [ShortcutAction] = [.advance, .close, .amend, .settings]
}

enum Shortcuts {
    static let defaults: [String: [KeyCombo]] = [
        ShortcutAction.toggle.rawValue: [KeyCombo(keyCode: UInt16(kVK_ANSI_M), modifiers: [.control, .option, .command])],
        ShortcutAction.advance.rawValue: [KeyCombo(keyCode: UInt16(kVK_Return)), KeyCombo(keyCode: UInt16(kVK_Space))],
        ShortcutAction.close.rawValue: [KeyCombo(keyCode: UInt16(kVK_Escape))],
        ShortcutAction.amend.rawValue: [KeyCombo(keyCode: UInt16(kVK_ANSI_E))],
        ShortcutAction.settings.rawValue: [KeyCombo(keyCode: UInt16(kVK_ANSI_S))],
    ]

    /// Why a key cannot go to an action, or nil if it can.
    static func problem(with combo: KeyCombo, for action: ShortcutAction, slot: Int, in settings: Settings) -> String? {
        if action.isGlobal && !combo.hasModifier {
            return "Add \u{2318}, \u{2325} or \u{2303}: a shortcut that works everywhere needs one."
        }
        for other in ShortcutAction.allCases where other != action {
            if settings.combos(other).contains(combo) {
                return "\(combo.display) is already used for \u{201C}\(other.title)\u{201D}."
            }
        }
        let own = settings.combos(action)
        if own.indices.contains(1 - slot), own[1 - slot] == combo {
            return "\(combo.display) is already set for this action."
        }
        return nil
    }
}

// MARK: - Recorder

/// A field that records the next key combination pressed. Esc cancels, Delete clears.
struct ShortcutRecorder: NSViewRepresentable {
    let combo: KeyCombo?
    var placeholder = "Record Shortcut"
    let onRecord: (KeyCombo) -> Void
    var onClear: (() -> Void)? = nil

    func makeNSView(context: Context) -> RecorderView {
        let v = RecorderView()
        update(v)
        return v
    }

    func updateNSView(_ v: RecorderView, context: Context) { update(v) }

    private func update(_ v: RecorderView) {
        v.combo = combo
        v.placeholder = placeholder
        v.onRecord = onRecord
        v.onClear = onClear
        v.needsDisplay = true
    }
}

final class RecorderView: NSView {
    var combo: KeyCombo?
    var placeholder = "Record Shortcut"
    var onRecord: (KeyCombo) -> Void = { _ in }
    var onClear: (() -> Void)?

    private var recording = false {
        didSet {
            guard recording != oldValue else { return }
            needsDisplay = true
            // While a key is being recorded, the global shortcut must not fire.
            MainActor.assumeIsolated {
                if recording { HotKeyCenter.shared.suspend() } else { HotKeyCenter.shared.resume() }
            }
        }
    }

    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 150, height: 24) }

    override func mouseDown(with event: NSEvent) {
        if recording {
            stop()
        } else {
            window?.makeFirstResponder(self)
            recording = true
        }
    }

    override func resignFirstResponder() -> Bool {
        recording = false
        return true
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { recording = false }
        super.viewWillMove(toWindow: newWindow)
    }

    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }
        handle(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording, window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        handle(event)
        return true
    }

    private func handle(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(KeyCombo.relevant)
        if flags.isEmpty && event.keyCode == UInt16(kVK_Escape) { stop(); return }
        if flags.isEmpty && (event.keyCode == UInt16(kVK_Delete) || event.keyCode == UInt16(kVK_ForwardDelete)) {
            onClear?()
            stop()
            return
        }
        let combo = KeyCombo(event: event)
        stop()
        onRecord(combo)
    }

    private func stop() {
        recording = false
        if window?.firstResponder === self { window?.makeFirstResponder(nil) }
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6)
        NSColor.controlBackgroundColor.setFill()
        path.fill()
        if recording {
            NSColor.controlAccentColor.setStroke()
            path.lineWidth = 2
        } else {
            NSColor.separatorColor.setStroke()
            path.lineWidth = 1
        }
        path.stroke()

        let text: String
        let color: NSColor
        if recording {
            text = "Type shortcut\u{2026}"
            color = .secondaryLabelColor
        } else if let combo {
            text = combo.display
            color = .labelColor
        } else {
            text = placeholder
            color = .tertiaryLabelColor
        }
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: color,
            .paragraphStyle: style,
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        let rect = NSRect(x: r.minX + 6, y: r.midY - size.height / 2, width: r.width - 12, height: size.height)
        (text as NSString).draw(in: rect, withAttributes: attrs)
    }
}
