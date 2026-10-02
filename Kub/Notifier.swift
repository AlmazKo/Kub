import AppKit
import UserNotifications

/// Local user-notifications for long-running diagnostics (heap dump / profile):
/// a completion banner whose click reveals the artifact in Finder.
///
/// `UNUserNotificationCenter.current()` traps without a bundle identifier (e.g. a
/// bare `swift run` binary), so everything is gated on `isAvailable`; when we can't
/// post, the caller falls back to the in-app popover. Stateless → `@unchecked Sendable`.
final class Notifier: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = Notifier()

    /// userInfo key carrying the file path to reveal in Finder on click.
    private static let revealKey = "revealPath"

    /// Only true for a bundled, code-signed app (has a bundle identifier).
    var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    /// True only if a posted banner would *actually* appear: the app is bundled
    /// AND notifications are currently authorized. A bundle id alone is not enough —
    /// if the user denied (or hasn't yet answered) the prompt, `add()` silently drops
    /// the request, so callers must fall back to their own UI when this is false.
    func canDeliver() async -> Bool {
        guard isAvailable else { return false }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional: return true
        default: return false
        }
    }

    /// Register as delegate and ask for permission once, at launch.
    @MainActor func configure() {
        guard isAvailable else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Post a completion banner. `revealPath`, if set, is opened in Finder on click.
    @MainActor func post(title: String, body: String, revealPath: String?) {
        guard isAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let revealPath { content.userInfo = [Self.revealKey: revealPath] }
        // nil trigger → deliver immediately; unique id so banners don't coalesce.
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Show the banner even when Kub is frontmost.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    /// Click → bring Kub forward and reveal the artifact in Finder.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let path = response.notification.request.content.userInfo[Self.revealKey] as? String
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier, let path {
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
        }
        completionHandler()
    }
}
