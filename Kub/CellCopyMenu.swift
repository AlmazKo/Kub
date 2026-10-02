import AppKit

/// Right-click "Copy" for the exact clicked cell, shared across every table.
/// Reads the live cell view's text (the full value — display truncation is only
/// visual), so it needs no per-column wiring.
enum CellCopy {
    /// Full text of the cell at (row, column), or nil if the cell shows none.
    @MainActor
    static func cellText(_ table: NSTableView, row: Int, column: Int) -> String? {
        guard row >= 0, column >= 0,
              let view = table.view(atColumn: column, row: row, makeIfNecessary: false) else { return nil }
        let raw = (view as? NSTableCellView)?.textField?.stringValue ?? firstTextField(in: view)?.stringValue
        guard let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty, text != "—" else { return nil }
        return text
    }

    /// A "Copy <Column>" item for the clicked cell — the title uses the column
    /// header (e.g. "Copy Reason"), while the full cell value is what's copied.
    /// nil if the cell has no text.
    @MainActor
    static func menuItem(_ table: NSTableView, row: Int, column: Int) -> NSMenuItem? {
        guard let value = cellText(table, row: row, column: column) else { return nil }
        let item = NSMenuItem(title: columnTitle(table, column).map { "Copy \($0)" } ?? "Copy Cell",
                              action: #selector(CellCopyResponder.copyCell(_:)), keyEquivalent: "")
        item.target = CellCopyResponder.shared
        item.representedObject = value
        return item
    }

    @MainActor
    private static func columnTitle(_ table: NSTableView, _ column: Int) -> String? {
        guard column >= 0, column < table.tableColumns.count else { return nil }
        let title = table.tableColumns[column].title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }

    @MainActor
    private static func firstTextField(in view: NSView) -> NSTextField? {
        if let tf = view as? NSTextField { return tf }
        for sub in view.subviews { if let tf = firstTextField(in: sub) { return tf } }
        return nil
    }
}

/// Retained target for copy menu items — menus are transient, so the item's target
/// must outlive them.
@MainActor
final class CellCopyResponder: NSObject {
    static let shared = CellCopyResponder()
    @objc func copyCell(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Installs a right-click "Copy <cell>" menu on a table that has none of its own
/// (metrics / node-pods / namespace-inventory). Retain the instance (store it) —
/// `NSMenu.delegate` is weak.
@MainActor
final class CellCopyMenu: NSObject, NSMenuDelegate {
    private weak var table: NSTableView?

    func attach(to table: NSTableView) {
        self.table = table
        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let table,
              let item = CellCopy.menuItem(table, row: table.clickedRow, column: table.clickedColumn) else { return }
        menu.addItem(item)
    }
}
