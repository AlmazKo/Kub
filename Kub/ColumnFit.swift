import AppKit

/// Sizes table columns to the minimum width that still shows their content
/// (header title + widest cell value), so tables stay compact. Pure text
/// measurement — fast, and no cell-view instantiation.
@MainActor
enum ColumnFit {
    private static let headerFont = NSFont.systemFont(ofSize: 11)

    /// Minimal width to show `title` and every value in `texts`, measured in
    /// `font`, plus `padding` (cell insets + any icon/pill), clamped to
    /// [minWidth, maxWidth]. The header reserves room for a sort indicator.
    static func width(title: String, texts: [String], font: NSFont,
                      padding: CGFloat, minWidth: CGFloat, maxWidth: CGFloat) -> CGFloat {
        var w = ceil((title as NSString).size(withAttributes: [.font: headerFont]).width) + 22
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        for t in texts where !t.isEmpty {
            let tw = ceil((t as NSString).size(withAttributes: attrs).width) + padding
            if tw > w {
                w = tw
                if w >= maxWidth { return maxWidth }
            }
        }
        return max(minWidth, min(maxWidth, w))
    }
}
