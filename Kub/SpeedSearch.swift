import AppKit

/// A printable keystroke that should start/extend a speed-search (letters, digits,
/// punctuation, space) — not a navigation/command key. nil → let the view handle it.
private func speedSearchChar(_ event: NSEvent) -> String? {
    guard !event.modifierFlags.contains(.command), !event.modifierFlags.contains(.control) else { return nil }
    guard let s = event.characters, let u = s.unicodeScalars.first,
          u.value >= 0x20, u.value != 0x7F, u.value < 0xF700 else { return nil }   // no delete / arrows / F-keys
    return s
}

private let escKeyCode: UInt16 = 53

/// NSTableView that forwards a printable keystroke to a search field instead of
/// doing type-select — IDEA-style "just start typing" search on a focused table.
class SpeedSearchTableView: NSTableView {
    var onTypeSearch: ((String) -> Void)?
    var onEscape: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == escKeyCode, let esc = onEscape { esc(); return }
        if let ch = speedSearchChar(event), let type = onTypeSearch { type(ch); return }
        super.keyDown(with: event)
    }
}

/// Read-only NSTextView that forwards a printable keystroke to a search field, so a
/// focused describe/overview pane searches as you type.
final class SpeedSearchTextView: NSTextView {
    var onTypeSearch: ((String) -> Void)?
    var onEscape: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == escKeyCode, let esc = onEscape { esc(); return }
        if !isEditable, let ch = speedSearchChar(event), let type = onTypeSearch { type(ch); return }
        super.keyDown(with: event)
    }
}
