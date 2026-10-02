import AppKit

/// Per-context look customization (color + emoji), persisted in UserDefaults.
struct ContextAppearance: Equatable {
    var colorHex: String?
    var emoji: String?

    var color: NSColor? { colorHex.flatMap { NSColor(hexString: $0) } }
}

enum ContextAppearanceStore {
    private static let key = "ContextAppearance"

    /// Preset colors shown in the customizer.
    static let palette: [(name: String, hex: String)] = [
        ("Red", "FF3B30"), ("Orange", "FF9500"), ("Yellow", "FFCC00"),
        ("Green", "34C759"), ("Teal", "30B0C7"), ("Blue", "007AFF"),
        ("Indigo", "5856D6"), ("Purple", "AF52DE"), ("Pink", "FF2D55"),
        ("Gray", "8E8E93"),
    ]

    static func appearance(for context: String) -> ContextAppearance {
        let all = UserDefaults.standard.dictionary(forKey: key) as? [String: [String: String]] ?? [:]
        let entry = all[context] ?? [:]
        return ContextAppearance(colorHex: entry["color"], emoji: entry["emoji"])
    }

    static func set(_ appearance: ContextAppearance, for context: String) {
        var all = UserDefaults.standard.dictionary(forKey: key) as? [String: [String: String]] ?? [:]
        var entry: [String: String] = [:]
        if let c = appearance.colorHex, !c.isEmpty { entry["color"] = c }
        if let e = appearance.emoji, !e.isEmpty { entry["emoji"] = e }
        all[context] = entry.isEmpty ? nil : entry
        UserDefaults.standard.set(all, forKey: key)
    }
}

/// Which resource kinds the user wants in the sidebar. Disabled kinds are shown
/// dimmed and are never queried. Persisted in UserDefaults (stores the disabled set).
enum ResourceKindStore {
    private static let key = "DisabledResourceKinds"
    private static let orderKey = "ResourceKindOrder"
    private static let seededKey = "SidebarDefaultsSeededV1"

    /// Enabled by default — a developer-focused set: your app (pods/deployments),
    /// how it's reached (services/ingresses), its config (configmaps/secrets), and
    /// what's going wrong (events). Everything else is one right-click away.
    static let defaultEnabled: [ResourceKind] =
        [.pods, .deployments, .services, .ingresses, .configMaps, .secrets, .events]

    /// One-time on first launch: disable everything outside `defaultEnabled`. Guarded
    /// by `seededKey`, so later manual show/hide choices persist untouched.
    static func seedDefaultsIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: seededKey) else { return }
        let disabled = ResourceKind.allCases.filter { !defaultEnabled.contains($0) }.map(\.rawValue)
        UserDefaults.standard.set(disabled, forKey: key)
        UserDefaults.standard.set(true, forKey: seededKey)
    }

    static func isEnabled(_ kind: ResourceKind) -> Bool {
        !disabledRawValues.contains(kind.rawValue)
    }

    /// User-defined sidebar order (drag-and-drop). New/unknown kinds are appended
    /// in declaration order so the list always covers every kind.
    static var order: [ResourceKind] {
        let stored = (UserDefaults.standard.stringArray(forKey: orderKey) ?? [])
            .compactMap(ResourceKind.init(rawValue:))
        return stored + ResourceKind.allCases.filter { !stored.contains($0) }
    }

    static func setOrder(_ kinds: [ResourceKind]) {
        UserDefaults.standard.set(kinds.map(\.rawValue), forKey: orderKey)
    }

    static func setEnabled(_ kind: ResourceKind, _ enabled: Bool) {
        var disabled = Set(disabledRawValues)
        if enabled { disabled.remove(kind.rawValue) } else { disabled.insert(kind.rawValue) }
        UserDefaults.standard.set(Array(disabled), forKey: key)
    }

    static var enabledKinds: [ResourceKind] {
        ResourceKind.allCases.filter { isEnabled($0) }
    }

    private static var disabledRawValues: [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }
}

/// Per-context pinned namespaces (favorites), persisted in UserDefaults. A pinned
/// namespace is a bookmark: the toolbar bookmark toggle filters every table to
/// rows in these namespaces.
enum PinnedNamespaces {
    private static let key = "PinnedNamespaces"

    private static func all() -> [String: [String]] {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: [String]]) ?? [:]
    }

    static func namespaces(for context: String) -> Set<String> {
        Set(all()[context] ?? [])
    }

    static func isPinned(_ namespace: String, in context: String) -> Bool {
        !namespace.isEmpty && (all()[context] ?? []).contains(namespace)
    }

    /// Toggle a namespace pin; returns the new pinned state.
    @discardableResult
    static func toggle(_ namespace: String, in context: String) -> Bool {
        guard !namespace.isEmpty else { return false }
        var dict = all()
        var list = dict[context] ?? []
        let pinned: Bool
        if let i = list.firstIndex(of: namespace) { list.remove(at: i); pinned = false }
        else { list.append(namespace); pinned = true }
        dict[context] = list.isEmpty ? nil : list
        UserDefaults.standard.set(dict, forKey: key)
        return pinned
    }
}

extension NSColor {
    convenience init?(hexString: String) {
        var s = hexString
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = Int(s, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                  green: CGFloat((value >> 8) & 0xFF) / 255,
                  blue: CGFloat(value & 0xFF) / 255,
                  alpha: 1)
    }
}
