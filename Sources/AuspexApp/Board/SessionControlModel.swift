import AgentSessionKit
import AgentSessionLive
import AuspexCore
import Foundation
import Observation
import SwiftUI

/// The one object in Auspex that stops observing and acts.
///
/// It owns three things and nothing else: the process table the guard is
/// answered against, the confirmation a destructive step is waiting on, and
/// the note that goes into the session's own trace afterwards. The deciding is
/// ``SessionControl``'s, in Core, where it is tested; this is the wiring.
///
/// ## Nothing happens without a click, and every click is re-checked
///
/// A menu item is enabled from a table read at most one liveness tick ago,
/// which is fine for deciding whether an item is live and is not fine for
/// deciding where a signal goes. So every path that can reach `kill(2)`
/// refreshes the table first, and ``SessionControl/send(_:to:table:ownUID:tolerance:)``
/// re-verifies `(pid, startTime)` in the instant before the syscall. A
/// confirmation dialog can sit open for a minute; a pid is not a stable name
/// for anything over a minute.
///
/// ## Why the table is shared
///
/// It is the same ``ProcessTable`` the liveness loop and the grouping pass
/// tick against, which caches for three seconds. A context menu built from it
/// therefore costs nothing — it reads the snapshot the last liveness tick
/// already paid for — and a wall of four hundred cards cannot turn "is this
/// item enabled" into four hundred `sysctl` sweeps.
@MainActor
@Observable
final class SessionControlModel {
    /// The destructive step waiting on a person, or `nil`.
    private(set) var prompt: ControlPrompt?

    /// Where a note about what Auspex did goes: into the same event stream the
    /// tailers feed, so it reaches the registry, the store, and the trace by
    /// the route every other event takes.
    @ObservationIgnored var onEvent: ((AgentEvent) -> Void)?

    /// Where a refusal a person could not have predicted goes.
    @ObservationIgnored var onNotice: ((String) -> Void)?

    @ObservationIgnored private var table: (any ProcessTableReading)?

    /// How long a terminated process is given to go before Auspex offers to
    /// force it. Long enough for a harness to write its transcript and remove
    /// its own lock files; short enough that a person is still looking at the
    /// screen.
    nonisolated static let forceGrace = Duration.seconds(3)

    /// Binds the model to the table the rest of the pipeline is already
    /// reading. Until this is called, every session answers "not running".
    func start(table: any ProcessTableReading) {
        self.table = table
    }

    // MARK: - Asking

    /// Whether this session's process can be signalled, and which one it is.
    ///
    /// Cheap by construction: it reads the shared table's cached snapshot, so
    /// building a context menu costs no syscalls of its own.
    func availability(for identity: SessionIdentity) -> SessionControl.Availability {
        guard let table else {
            return .unavailable(reason: "Auspex is not watching processes yet.")
        }
        return SessionControl.availability(for: identity, table: table)
    }

    // MARK: - Acting

    /// Sends `SIGINT`, having re-checked that the pid is still the process the
    /// session recorded.
    ///
    /// No confirmation. An interrupt is the recoverable one — every harness
    /// that takes it writes its transcript first, and the session is resumable
    /// afterwards — and a dialog in front of it would make the destructive one
    /// beside it look equally routine.
    func interrupt(_ identity: SessionIdentity) {
        guard let target = refreshedTarget(for: identity) else { return }
        deliver(.interrupt, to: target, session: identity.key)
    }

    /// Opens the confirmation that stands in front of a kill.
    ///
    /// Nothing is sent here. The dialog names the session and the pid, and the
    /// send happens in ``confirm(_:)``.
    func requestKill(_ identity: SessionIdentity) {
        guard let target = refreshedTarget(for: identity) else { return }
        prompt = ControlPrompt(
            step: .terminate,
            key: identity.key,
            title: Self.title(of: identity),
            target: target,
            isResumable: SessionHandoff.resume(for: identity).isAvailable
        )
    }

    /// Carries out the step a person just agreed to.
    func confirm(_ prompt: ControlPrompt) {
        self.prompt = nil
        switch prompt.step {
        case .terminate:
            guard deliver(.terminate, to: prompt.target, session: prompt.key) else { return }
            offerForce(after: prompt)
        case .force:
            deliver(.forceKill, to: prompt.target, session: prompt.key)
        }
    }

    /// Closes the dialog without doing anything.
    func dismiss() {
        prompt = nil
    }

    // MARK: - Machinery

    /// The verified target for a session, from a table refreshed right now, or
    /// `nil` with the reason surfaced as a notice.
    ///
    /// A refusal here is worth a notice rather than silence: the item a person
    /// clicked was enabled a moment ago, so "nothing happened" is a thing they
    /// would otherwise have to guess at.
    private func refreshedTarget(for identity: SessionIdentity) -> SessionControl.Target? {
        guard let table else { return nil }
        refresh(table)
        let availability = SessionControl.availability(for: identity, table: table)
        switch availability {
        case let .available(target):
            return target
        case let .unavailable(reason):
            onNotice?("Auspex did not signal this session: \(reason)")
            return nil
        }
    }

    /// Sends one signal and writes what happened into the session's trace.
    @discardableResult
    private func deliver(
        _ signal: SessionControl.Signal,
        to target: SessionControl.Target,
        session: SessionKey
    ) -> Bool {
        guard let table else { return false }
        refresh(table)
        let outcome = SessionControl.send(signal, to: target, table: table)
        switch outcome {
        case .sent:
            note(SessionControl.note(signal, target: target), for: session)
            return true
        case let .refused(reason), let .failed(reason):
            note(
                SessionControl.failureNote(signal, pid: target.pid, reason: reason),
                for: session
            )
            onNotice?("Auspex did not signal pid \(target.pid): \(reason)")
            return false
        }
    }

    /// Checks, after a grace period, whether a terminated process is still
    /// there — and if it is, offers the uncatchable signal.
    ///
    /// The escalation is a second click on a second dialog, never an automatic
    /// follow-up. `SIGKILL` gives a harness no chance to finish writing its
    /// transcript, and a person who asked for a polite stop has not asked for
    /// that.
    private func offerForce(after prompt: ControlPrompt) {
        Task { [weak self] in
            try? await Task.sleep(for: Self.forceGrace)
            guard let self, let table = self.table else { return }
            refresh(table)
            guard SessionControl.stillMatches(prompt.target, table: table) else { return }
            // Only if the person has not moved on to something else. A dialog
            // that appears over an unrelated confirmation is worse than one
            // that never appears.
            guard self.prompt == nil else { return }
            self.prompt = ControlPrompt(
                step: .force,
                key: prompt.key,
                title: prompt.title,
                target: prompt.target,
                isResumable: prompt.isResumable
            )
        }
    }

    /// Forces a new process-table snapshot before a decision that will reach
    /// `kill(2)`.
    ///
    /// The cast is the honest shape of the thing: `ProcessTableReading` is a
    /// read-only protocol with no notion of freshness, deliberately, so that
    /// a fixed array can stand in for the kernel in a test. Only the real
    /// table has a cache to invalidate, and only the real table is ever handed
    /// a pid that a signal is about to go to.
    private func refresh(_ table: any ProcessTableReading) {
        (table as? ProcessTable)?.refresh()
    }

    /// Puts a line in the session's own trace.
    ///
    /// Through the event stream rather than straight into the database, so the
    /// registry folds it, the store writes it in the same transaction as
    /// everything else, and the trace pane reloads for the same reason it
    /// reloads for a tailer's event. A second write path would be a second
    /// thing to keep consistent.
    private func note(_ text: String, for key: SessionKey) {
        onEvent?(AgentEvent(session: key, timestamp: Date(), kind: .note(text)))
    }

    /// What to call a session in a dialog.
    private static func title(of identity: SessionIdentity) -> String {
        if let title = identity.title, !title.isEmpty { return title }
        return String(identity.key.sessionID.prefix(8))
    }
}

/// The dialog that stands between a menu item and a signal.
///
/// At the window's root and not on the control that raised it: the same "Kill…"
/// exists on every card and in the trace header, and a dialog attached to each
/// of them would be one dialog per card — several hundred of them, all able to
/// be open at once. One here, keyed off the one prompt the model can hold.
///
/// An alert rather than a sheet because it is a question with two answers, and
/// because `role: .destructive` is what makes the button red without anybody
/// choosing a colour.
struct KillConfirmation: ViewModifier {
    let control: SessionControlModel

    func body(content: Content) -> some View {
        content.alert(
            control.prompt?.headline ?? "",
            isPresented: Binding(
                get: { control.prompt != nil },
                set: { if !$0 { control.dismiss() } }
            ),
            presenting: control.prompt
        ) { prompt in
            Button(prompt.confirmTitle, role: .destructive) { control.confirm(prompt) }
            Button("Cancel", role: .cancel) { control.dismiss() }
        } message: { prompt in
            Text(prompt.message)
        }
    }
}

/// A destructive step waiting on a person.
///
/// Two steps in one type rather than two properties, because only one of them
/// can be on screen and a pair of optionals would let both be.
struct ControlPrompt: Identifiable, Equatable {
    enum Step: Equatable {
        /// `SIGTERM`, the first ask.
        case terminate
        /// `SIGKILL`, offered only after the first did not take.
        case force
    }

    let id = UUID()
    let step: Step
    let key: SessionKey
    let title: String
    let target: SessionControl.Target
    /// Whether the session can be reopened afterwards, so the dialog can say
    /// what is actually lost.
    let isResumable: Bool

    /// The dialog's headline.
    var headline: String {
        switch step {
        case .terminate: SessionControl.killPrompt(title: title, target: target)
        case .force: "Force \(title) to stop?"
        }
    }

    /// The dialog's body.
    var message: String {
        switch step {
        case .terminate:
            SessionControl.killMessage(target: target, isResumable: isResumable)
        case .force:
            "\(target.processName) (pid \(target.pid)) is still running "
                + "\(Int(SessionControlModel.forceGrace.components.seconds))s after SIGTERM. "
                + "SIGKILL cannot be caught, so it will not get to finish writing anything."
        }
    }

    /// What the destructive button says.
    /// What the destructive button says. No ellipsis on either: the ellipsis
    /// in the menu item is the promise that a question is coming, and this is
    /// the question.
    var confirmTitle: String {
        switch step {
        case .terminate: "Kill"
        case .force: SessionControl.Signal.forceKill.menuTitle
        }
    }
}
