import AgentSessionKit
import AgentSessionLive
import AppKit
import AuspexCore
import Foundation
import UserNotifications

/// Turns `auspex.notify` into a macOS notification.
///
/// This is the point of the whole surface. Everything else Auspex does is
/// something a person sees *when they look at the board*; this is the one path
/// that reaches somebody who is looking at something else. An agent that
/// stopped to ask a question used to be indistinguishable from an agent that
/// is thinking hard — that gap is what this closes.
///
/// ## What it will not do
///
/// - **Never in a demo.** Nothing on a fabricated board happened, and an alert
///   in Notification Centre outlives the window that explained itself. The
///   caller decides; this type is simply never asked.
/// - **Never a transcript.** The body is the agent's own sanitized sentence
///   and the session's title. No prompt text, no file contents, no path
///   beyond the project name already on the card.
/// - **Never louder than asked.** `urgency: high` becomes a time-sensitive
///   notification, which is as far as an unentitled app can go, and everything
///   else arrives at the ordinary level.
///
/// ## Why authorisation failure is not an error
///
/// A person who has denied Auspex notifications has said what they want. The
/// board still moves, the menu bar still counts, and the card still carries
/// the agent's words — the notification is the *extra* channel, not the state.
/// So a refusal is recorded once and never retried in a loop.
actor AgentNotifier {
    static let shared = AgentNotifier()

    /// Identifiers used for the two actions on a notification.
    enum Action {
        static let show = "auspex.show"
        static let copyResume = "auspex.copy-resume"
        static let category = "auspex.notice"
    }

    /// The session a notification is about, carried in `userInfo` so that a
    /// click can select the right card.
    static let sessionKeyInfoKey = "auspex.sessionKey"

    private var didRequestAuthorization = false
    private var isAuthorized = false

    /// Whether this process can talk to Notification Centre at all.
    ///
    /// `UNUserNotificationCenter.current()` does not fail politely outside an
    /// application bundle — it aborts the process, because it cannot find a
    /// bundle proxy to attribute the notification to. That is exactly the
    /// situation a `swift test` run is in, and one unguarded call would take
    /// the whole suite down with SIGABRT rather than a failure.
    ///
    /// So the presence of a bundle identifier is the gate. In the shipped
    /// `Auspex.app` it is `com.astroqore.auspex`; in a test binary there is
    /// none, and every entry point here becomes a no-op.
    nonisolated static let isAvailable: Bool = Bundle.main.bundleIdentifier != nil

    /// Posts one notice, if the person has allowed it.
    func post(_ notice: AgentNotice, title: String? = nil) async {
        guard Self.isAvailable, await ensureAuthorized() else { return }

        let content = UNMutableNotificationContent()
        content.title = title ?? Self.headline(for: notice)
        content.subtitle = notice.kind.label
        content.body = notice.message
        content.categoryIdentifier = Action.category
        content.userInfo = [Self.sessionKeyInfoKey: notice.session.description]
        content.interruptionLevel = notice.urgency == .high ? .timeSensitive : .active
        // One notification per session at a time: an agent that asks twice is
        // one agent still waiting, and the second alert should replace the
        // first rather than stack under it.
        content.threadIdentifier = notice.session.description

        let request = UNNotificationRequest(
            identifier: "auspex.notice.\(notice.session.description)",
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
    }

    /// Takes a session's notification back — the person answered, or dismissed
    /// it from the card.
    func withdraw(session: SessionKey) {
        guard Self.isAvailable else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(
            withIdentifiers: ["auspex.notice.\(session.description)"]
        )
    }

    /// The line above the agent's words: which harness, and what it is about.
    static func headline(for notice: AgentNotice) -> String {
        let harness = notice.session.harness.displayName
        switch notice.kind {
        case .needsInput: return "\(harness) is waiting on you"
        case .needsReview: return "\(harness) wants a review"
        case .blocked: return "\(harness) is blocked"
        case .done: return "\(harness) finished"
        }
    }

    /// Asks once, remembers the answer.
    private func ensureAuthorized() async -> Bool {
        if didRequestAuthorization { return isAuthorized }
        didRequestAuthorization = true
        let center = UNUserNotificationCenter.current()
        center.setNotificationCategories([Self.category()])
        isAuthorized = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        return isAuthorized
    }

    /// The two things a person wants from an alert: look at it, or get back
    /// into the terminal it came from.
    ///
    /// Built on demand rather than stored: `UNNotificationCategory` is not
    /// `Sendable`, and a shared instance of it would be a mutable global in a
    /// Swift 6 module for no gain — it is constructed once, at authorisation.
    private static func category() -> UNNotificationCategory {
        UNNotificationCategory(
            identifier: Action.category,
            actions: [
                UNNotificationAction(
                    identifier: Action.show,
                    title: "Show",
                    options: [.foreground]
                ),
                UNNotificationAction(
                    identifier: Action.copyResume,
                    title: "Copy resume command",
                    options: []
                )
            ],
            intentIdentifiers: [],
            options: []
        )
    }
}

/// Routes a click on a notification back into the window.
///
/// A delegate of its own rather than a closure on the app: the notification
/// centre hands its callbacks to whatever is set as the delegate at the moment
/// the person clicks, which may be long after the code that posted the
/// notification has gone.
@MainActor
final class AgentNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    /// Called with the session a person clicked through to.
    var onSelect: ((SessionKey) -> Void)?
    /// Called when they asked for the command to get back into the terminal.
    var onCopyResume: ((SessionKey) -> Void)?

    /// Show the banner even when Auspex is the frontmost app: the whole point
    /// is a session on a board the person may not be looking at, and the window
    /// being open is not the same as it being read.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        guard let raw = info[AgentNotifier.sessionKeyInfoKey] as? String,
              let key = SessionKey(string: raw)
        else { return }
        let action = response.actionIdentifier
        await MainActor.run {
            switch action {
            case AgentNotifier.Action.copyResume:
                self.onCopyResume?(key)
            default:
                NSApp.activate(ignoringOtherApps: true)
                self.onSelect?(key)
            }
        }
    }
}
