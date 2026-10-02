import AppKit

/// Popover content: pick a color and an emoji for the active context. Changes
/// are saved immediately and reported via `onChange`.
final class ContextCustomizeViewController: NSViewController, NSTextFieldDelegate {
    private let context: String
    private let displayName: String
    private var appearance: ContextAppearance
    private var swatches: [(button: NSButton, hex: String?)] = []
    private let emojiField = NSTextField()

    var onChange: (() -> Void)?

    init(context: String, displayName: String) {
        self.context = context
        self.displayName = displayName
        self.appearance = ContextAppearanceStore.appearance(for: context)
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("not implemented") }

    override func loadView() {
        let title = NSTextField(labelWithString: "Customize  \(displayName)")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail

        let colorCaption = caption("Color")
        let colorRow = NSStackView()
        colorRow.orientation = .horizontal
        colorRow.spacing = 5
        for (_, hex) in ContextAppearanceStore.palette {
            colorRow.addArrangedSubview(makeSwatch(hex: hex))
        }
        colorRow.addArrangedSubview(makeSwatch(hex: nil))   // "none"

        let emojiCaption = caption("Emoji")
        emojiField.translatesAutoresizingMaskIntoConstraints = false
        emojiField.stringValue = appearance.emoji ?? ""
        emojiField.placeholderString = "🙂"
        emojiField.alignment = .center
        emojiField.font = .systemFont(ofSize: 16)
        emojiField.delegate = self
        emojiField.widthAnchor.constraint(equalToConstant: 46).isActive = true

        let pick = NSButton(title: "Pick…", target: self, action: #selector(pickEmoji))
        pick.bezelStyle = .rounded
        pick.controlSize = .small
        let clear = NSButton(title: "Clear", target: self, action: #selector(clearEmoji))
        clear.bezelStyle = .rounded
        clear.controlSize = .small

        let emojiRow = NSStackView(views: [emojiField, pick, clear])
        emojiRow.orientation = .horizontal
        emojiRow.spacing = 8
        emojiRow.alignment = .centerY

        let stack = NSStackView(views: [title, colorCaption, colorRow, emojiCaption, emojiRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        view = container
        preferredContentSize = NSSize(width: 320, height: 150)
    }

    private func caption(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text.uppercased())
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }

    // MARK: - Color swatches

    private func makeSwatch(hex: String?) -> NSButton {
        let button = NSButton()
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.imagePosition = .imageOnly
        button.target = self
        button.action = #selector(selectColor(_:))
        button.image = swatchImage(hex: hex, selected: appearance.colorHex == hex)
        button.toolTip = hex == nil ? "None" : nil
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 24).isActive = true
        button.heightAnchor.constraint(equalToConstant: 24).isActive = true
        swatches.append((button, hex))
        return button
    }

    private func swatchImage(hex: String?, selected: Bool) -> NSImage {
        let d: CGFloat = 22
        let image = NSImage(size: NSSize(width: d, height: d))
        image.lockFocus()
        let rect = NSRect(x: 2, y: 2, width: d - 4, height: d - 4)
        if let hex, let color = NSColor(hexString: hex) {
            color.setFill()
            NSBezierPath(ovalIn: rect).fill()
        } else {
            NSColor.tertiaryLabelColor.setStroke()
            let circle = NSBezierPath(ovalIn: rect)
            circle.lineWidth = 1.5
            circle.stroke()
            let slash = NSBezierPath()
            slash.move(to: NSPoint(x: rect.minX + 3, y: rect.maxY - 3))
            slash.line(to: NSPoint(x: rect.maxX - 3, y: rect.minY + 3))
            slash.lineWidth = 1.5
            slash.stroke()
        }
        if selected {
            NSColor.labelColor.setStroke()
            let ring = NSBezierPath(ovalIn: NSRect(x: 1, y: 1, width: d - 2, height: d - 2))
            ring.lineWidth = 2
            ring.stroke()
        }
        image.unlockFocus()
        return image
    }

    private func refreshSwatches() {
        for (button, hex) in swatches {
            button.image = swatchImage(hex: hex, selected: appearance.colorHex == hex)
        }
    }

    @objc private func selectColor(_ sender: NSButton) {
        guard let hex = swatches.first(where: { $0.button == sender })?.hex else {
            appearance.colorHex = nil
            commit()
            return
        }
        appearance.colorHex = (appearance.colorHex == hex) ? nil : hex   // click again to clear
        commit()
        refreshSwatches()
    }

    // MARK: - Emoji

    func controlTextDidChange(_ obj: Notification) {
        let first = emojiField.stringValue.first.map(String.init) ?? ""
        emojiField.stringValue = first
        appearance.emoji = first.isEmpty ? nil : first
        commit()
    }

    @objc private func pickEmoji() {
        view.window?.makeFirstResponder(emojiField)
        NSApp.orderFrontCharacterPalette(nil)
    }

    @objc private func clearEmoji() {
        emojiField.stringValue = ""
        appearance.emoji = nil
        commit()
    }

    private func commit() {
        ContextAppearanceStore.set(appearance, for: context)
        onChange?()
    }
}
