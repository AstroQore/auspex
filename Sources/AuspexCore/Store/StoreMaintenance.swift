import Foundation
import GRDB

/// The store's housekeeping, on a schedule: the one-time liveness purge, then
/// retention, then retention again every few hours.
///
/// A value with no state, so a pass can be run from a test with a fixed clock
/// as readily as from the app's background task. Every pass reads the stored
/// ``RetentionPolicy`` afresh, so a policy changed while the app is running is
/// the one the next pass applies.
public struct StoreMaintenance: Sendable {
    /// How long after launch the first pass waits.
    ///
    /// Long enough that bootstrap, the first discovery sweep and the brief
    /// backfill have finished with the writer, so trimming history never
    /// competes with the board filling in.
    public static let defaultInitialDelay = Duration.seconds(60)

    /// How long between passes after the first. Retention is measured in days;
    /// checking four times a day keeps the store within a few hours of its
    /// policy at the cost of one indexed range read per pass when there is
    /// nothing to do.
    public static let defaultInterval = Duration.seconds(6 * 3_600)

    /// What one pass did.
    public struct Pass: Sendable, Equatable {
        /// Heartbeats removed by the one-time purge, or `nil` when it had
        /// already run on this store.
        public var livenessEventsPurged: Int?
        /// What retention removed.
        public var retention: RetentionReport

        /// Rows removed by either half.
        public var totalDeleted: Int {
            (livenessEventsPurged ?? 0) + retention.totalDeleted
        }
    }

    public let store: AuspexStore
    public let initialDelay: Duration
    public let interval: Duration

    public init(
        store: AuspexStore,
        initialDelay: Duration = defaultInitialDelay,
        interval: Duration = defaultInterval
    ) {
        self.store = store
        self.initialDelay = initialDelay
        self.interval = interval
    }

    /// One pass: the purge if this store still needs it, then retention under
    /// the stored policy.
    public func runPass(now: Date = Date()) async throws -> Pass {
        let purged = try await LivenessEventPurge(store: store).runIfNeeded(now: now)
        let policy = (try? store.retentionPolicy()) ?? .default
        let retention = try await RetentionJob(store: store, policy: policy).runBatched(now: now)
        return Pass(livenessEventsPurged: purged, retention: retention)
    }

    /// Waits ``initialDelay``, then runs a pass every ``interval`` until the
    /// surrounding task is cancelled.
    ///
    /// A failed pass is reported and the schedule carries on: the next pass
    /// repeats whatever the failed one did not finish, because every rule is
    /// idempotent.
    public func run(
        onPass: @escaping @Sendable (Result<Pass, any Error>) async -> Void
    ) async {
        do { try await Task.sleep(for: initialDelay) } catch { return }
        while !Task.isCancelled {
            do {
                await onPass(.success(try await runPass()))
            } catch is CancellationError {
                return
            } catch {
                await onPass(.failure(error))
            }
            do { try await Task.sleep(for: interval) } catch { return }
        }
    }
}
