// MacGlass - global hotkeys (Processing > Global Hotkeys), via Carbon RegisterEventHotKey.
// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Carbon.HIToolbox

enum HotkeyAction: String, CaseIterable {
    case fullscreen, screenshot, active, cursor, pause, showMenu, clickThrough

    /// Menu title (as in ShaderGlass, plus Click-through for macOS).
    var title: String {
        switch self {
        case .fullscreen: return "Fullscreen..."
        case .screenshot: return "Screenshot..."
        case .active: return "Shader Active..."
        case .cursor: return "Capture Cursor..."
        case .pause: return "Start/Stop..."
        case .showMenu: return "Toggle Menu..."
        case .clickThrough: return "Click-through..."
        }
    }

    var name: String {
        switch self {
        case .fullscreen: return "Fullscreen Key"
        case .screenshot: return "Screenshot Key"
        case .active: return "Active Key"
        case .cursor: return "Cursor Key"
        case .pause: return "Pause Key"
        case .showMenu: return "Menu Key"
        case .clickThrough: return "Click-through Key"
        }
    }

    /// Defaults: Ctrl+Shift+G / Ctrl+Shift+S like ShaderGlass, Ctrl+Shift+T for Click-through.
    var defaultKey: Hotkey? {
        switch self {
        case .fullscreen: return Hotkey(keyCode: UInt32(kVK_ANSI_G), modifiers: [.control, .shift])
        case .screenshot: return Hotkey(keyCode: UInt32(kVK_ANSI_S), modifiers: [.control, .shift])
        case .clickThrough: return Hotkey(keyCode: UInt32(kVK_ANSI_T), modifiers: [.control, .shift])
        default: return nil
        }
    }
}

struct Hotkey: Equatable {
    var keyCode: UInt32
    var modifiers: NSEvent.ModifierFlags

    var carbonModifiers: UInt32 {
        var m: UInt32 = 0
        if modifiers.contains(.command) { m |= UInt32(cmdKey) }
        if modifiers.contains(.option) { m |= UInt32(optionKey) }
        if modifiers.contains(.control) { m |= UInt32(controlKey) }
        if modifiers.contains(.shift) { m |= UInt32(shiftKey) }
        return m
    }

    var display: String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        return s + Hotkey.keyName(keyCode)
    }

    var storage: String { "\(keyCode):\(modifiers.intersection([.command, .option, .control, .shift]).rawValue)" }

    init(keyCode: UInt32, modifiers: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.modifiers = modifiers.intersection([.command, .option, .control, .shift])
    }

    init?(storage: String) {
        let parts = storage.split(separator: ":")
        guard parts.count == 2, let k = UInt32(parts[0]), let m = UInt(parts[1]) else { return nil }
        self.init(keyCode: k, modifiers: NSEvent.ModifierFlags(rawValue: m))
    }

    static func keyName(_ code: UInt32) -> String {
        let special: [Int: String] = [kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Escape: "⎋",
                                      kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5",
                                      kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10",
                                      kVK_F11: "F11", kVK_F12: "F12", kVK_LeftArrow: "←", kVK_RightArrow: "→",
                                      kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_Delete: "⌫", kVK_Home: "↖", kVK_End: "↘"]
        if let s = special[Int(code)] { return s }
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return "#\(code)" }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        var deadKeys: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let result = data.withUnsafeBytes { raw -> OSStatus in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return -1 }
            return UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, 4, &length, &chars)
        }
        guard result == noErr, length > 0 else { return "#\(code)" }
        return String(utf16CodeUnits: chars, count: length).uppercased()
    }
}

final class HotkeyManager {
    static let shared = HotkeyManager()

    var handler: ((HotkeyAction) -> Void)?
    private var refs: [EventHotKeyRef] = []
    private var actionsByID: [UInt32: HotkeyAction] = [:]
    private var eventHandler: EventHandlerRef?

    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "Hotkeys Enabled") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "Hotkeys Enabled")
            register()
        }
    }

    func key(for action: HotkeyAction) -> Hotkey? {
        if let s = UserDefaults.standard.string(forKey: "Hotkey \(action.rawValue)") {
            return s.isEmpty ? nil : Hotkey(storage: s)
        }
        return action.defaultKey
    }

    func setKey(_ key: Hotkey?, for action: HotkeyAction) {
        UserDefaults.standard.set(key?.storage ?? "", forKey: "Hotkey \(action.rawValue)")
        register()
    }

    func register() {
        for r in refs { UnregisterEventHotKey(r) }
        refs.removeAll()
        actionsByID.removeAll()
        installHandlerIfNeeded()
        guard enabled else { return }
        var id: UInt32 = 1
        for action in HotkeyAction.allCases {
            guard let key = key(for: action) else { continue }
            var ref: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: OSType(0x4D47_4C53), id: id) // 'MGLS'
            if RegisterEventHotKey(key.keyCode, key.carbonModifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref) == noErr,
               let ref {
                refs.append(ref)
                actionsByID[id] = action
            }
            id += 1
        }
    }

    private func installHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let manager = HotkeyManager.shared
            if let action = manager.actionsByID[hotKeyID.id] {
                DispatchQueue.main.async { manager.handler?(action) }
            }
            return noErr
        }, 1, &spec, nil, &eventHandler)
    }
}

/// Small dialog that records a key combination.
final class HotkeyRecorderView: NSView {
    var hotkey: Hotkey? { didSet { needsDisplay = true } }
    var onChange: ((Hotkey?) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if mods.isEmpty && (event.keyCode == UInt16(kVK_Delete) || event.keyCode == UInt16(kVK_ForwardDelete)) {
            hotkey = nil
        } else if mods.isEmpty && event.keyCode == UInt16(kVK_Escape) {
            window?.makeFirstResponder(nil)
            return
        } else {
            hotkey = Hotkey(keyCode: UInt32(event.keyCode), modifiers: mods)
        }
        onChange?(hotkey)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, event.type == .keyDown else { return false }
        keyDown(with: event)
        return true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return true }

    override func draw(_ dirtyRect: NSRect) {
        let focused = window?.firstResponder === self
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5)
        NSColor.textBackgroundColor.setFill()
        path.fill()
        (focused ? NSColor.keyboardFocusIndicatorColor : NSColor.separatorColor).setStroke()
        path.lineWidth = focused ? 2 : 1
        path.stroke()
        let text = hotkey?.display ?? (focused ? "Press keys..." : "None")
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14),
                                                     .foregroundColor: hotkey == nil ? NSColor.secondaryLabelColor : NSColor.labelColor]
        let size = text.size(withAttributes: attrs)
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attrs)
    }

    enum DialogResult {
        case set(Hotkey?)
        case reset
        case cancel
    }

    static func runDialog(title: String, current: Hotkey?) -> DialogResult {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "Click the field and press the new key combination (use Control, Option or Command). Press Delete to clear it."
        let recorder = HotkeyRecorderView(frame: NSRect(x: 0, y: 0, width: 240, height: 30))
        recorder.hotkey = current
        alert.accessoryView = recorder
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Default")
        alert.window.initialFirstResponder = recorder
        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn: return .set(recorder.hotkey)
        case .alertThirdButtonReturn: return .reset
        default: return .cancel
        }
    }
}
