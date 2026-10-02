import Foundation

extension Notification.Name {
    /// Posted when `Settings.wrapDetailText` changes, so detail views re-flow live.
    static let kubWrapDetailTextChanged = Notification.Name("KubWrapDetailTextChanged")
}

/// App-wide settings, persisted in UserDefaults.
enum Settings {
    private static let jdkKey = "JDKIntegrationEnabled"
    private static let wrapKey = "WrapDetailText"
    private static let heapDumpsKey = "HeapDumpsDirectory"

    /// Where heap dumps are saved (a `<namespace>/` subfolder per dump). Defaults to
    /// ~/Downloads/Kub; macOS asks once before an app writes to Downloads, while a
    /// folder the user picks in the Settings open panel needs no extra consent.
    static var heapDumpsDirectory: String {
        get { UserDefaults.standard.string(forKey: heapDumpsKey) ?? defaultHeapDumpsDirectory }
        set { UserDefaults.standard.set(newValue, forKey: heapDumpsKey) }
    }
    static var defaultHeapDumpsDirectory: String { NSHomeDirectory() + "/Downloads/Kub" }

    /// The JDK/JVM diagnostics integration — heap dumps (jcmd) and async-profiler
    /// flame graphs on a process, from a pod's Top tab. Enabled by default.
    static var jdkIntegrationEnabled: Bool {
        get { UserDefaults.standard.object(forKey: jdkKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: jdkKey) }
    }

    /// Soft-wrap long lines in the plain-text detail views (Overview / Why /
    /// Containers / History / Mounts). Off by default → no wrap, with a
    /// horizontal scroller. (The Logs tab has its own in-place Wrap toggle.)
    static var wrapDetailText: Bool {
        get { UserDefaults.standard.bool(forKey: wrapKey) }   // default: false (no wrap)
        set {
            UserDefaults.standard.set(newValue, forKey: wrapKey)
            NotificationCenter.default.post(name: .kubWrapDetailTextChanged, object: nil)
        }
    }
}
