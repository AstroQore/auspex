import AgentSessionKit
import AgentSessionLive
import Foundation

/// An observed condition worth looking at, without claiming that an agent
/// asked for the person.
///
/// Attention is explicit and stays explicit. These are amber watch signals:
/// useful, explainable in one sentence, and allowed to be wrong without ever
/// becoming a notification or stopping a process on their own.
public struct WatchSignal: Identifiable, Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable, Codable, CaseIterable {
        case orphanedClaim = "orphaned_claim"
        case staleSession = "stale_session"
        case longTool = "long_tool"
        case contextPressure = "context_pressure"
        case sharedDirectory = "shared_directory"
        case sharedBranch = "shared_branch"
    }

    public enum Confidence: String, Sendable, Equatable, Codable, CaseIterable {
        case high
        case medium
    }

    public let id: String
    public let kind: Kind
    public let confidence: Confidence
    public let message: String
    public let unitIDs: [String]
    public let sessionKeys: [SessionKey]

    public init(
        id: String,
        kind: Kind,
        confidence: Confidence,
        message: String,
        unitIDs: [String],
        sessionKeys: [SessionKey]
    ) {
        self.id = id
        self.kind = kind
        self.confidence = confidence
        self.message = message
        self.unitIDs = unitIDs
        self.sessionKeys = sessionKeys
    }
}

/// Deterministic, low-cost collaboration diagnostics over one assembled frame.
public enum CollaborationSignals {
    /// A tool call this old is worth a glance. It is not declared stuck: long
    /// compiles and uploads are perfectly healthy, which is why the signal is
    /// medium-confidence and never enters Attention.
    public static let longToolAfter: TimeInterval = 5 * 60

    public static func derive(
        units: [TaskUnit],
        now: Date,
        longToolAfter: TimeInterval = Self.longToolAfter
    ) -> [WatchSignal] {
        var signals: [WatchSignal] = []
        signals.reserveCapacity(units.count)

        for unit in units {
            if unit.isClaimOrphaned {
                signals.append(WatchSignal(
                    id: "orphan:\(unit.id)",
                    kind: .orphanedClaim,
                    confidence: .high,
                    message: "The claiming session ended before the task was finished.",
                    unitIDs: [unit.id],
                    sessionKeys: unit.claim.map { [$0.session] } ?? []
                ))
            }
            for row in unit.members where !row.isEnded {
                if row.isStale {
                    signals.append(WatchSignal(
                        id: "stale:\(row.key.description)",
                        kind: .staleSession,
                        confidence: .high,
                        message: "\(row.title) is alive but has stopped producing fresh activity.",
                        unitIDs: [unit.id],
                        sessionKeys: [row.key]
                    ))
                }
                if case .toolCalling(let name) = row.state,
                   let since = row.elapsedSince,
                   now.timeIntervalSince(since) >= longToolAfter {
                    signals.append(WatchSignal(
                        id: "tool:\(row.key.description)",
                        kind: .longTool,
                        confidence: .medium,
                        message: "\(name) has been running for at least \(Int(longToolAfter / 60)) minutes.",
                        unitIDs: [unit.id],
                        sessionKeys: [row.key]
                    ))
                }
                if row.context?.level == .critical {
                    signals.append(WatchSignal(
                        id: "context:\(row.key.description)",
                        kind: .contextPressure,
                        confidence: .high,
                        message: "\(row.title)'s context window is at least 90% full.",
                        unitIDs: [unit.id],
                        sessionKeys: [row.key]
                    ))
                }
            }
        }

        signals.append(contentsOf: collisions(units: units, key: \.directory, kind: .sharedDirectory))
        signals.append(contentsOf: collisions(units: units, key: \.branch, kind: .sharedBranch))
        return signals.sorted { lhs, rhs in
            let left = signalRank(lhs.kind)
            let right = signalRank(rhs.kind)
            if left != right { return left < right }
            return lhs.id < rhs.id
        }
    }

    private static func collisions(
        units: [TaskUnit],
        key: KeyPath<BoardRow, String?>,
        kind: WatchSignal.Kind
    ) -> [WatchSignal] {
        struct Member {
            let unitID: String
            let row: BoardRow
        }
        var groups: [String: [Member]] = [:]
        for unit in units where unit.isOpen {
            for row in unit.members where !row.isEnded {
                guard let value = row[keyPath: key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !value.isEmpty else { continue }
                groups[value, default: []].append(Member(unitID: unit.id, row: row))
            }
        }

        return groups.compactMap { value, members in
            let unitIDs = Array(Set(members.map(\.unitID))).sorted()
            guard unitIDs.count > 1 else { return nil }
            let sessions = members.map(\.row.key).sorted { $0.description < $1.description }
            let noun = kind == .sharedDirectory ? "working directory" : "branch"
            return WatchSignal(
                id: "\(kind.rawValue):\(stableKey(value))",
                kind: kind,
                confidence: .high,
                message: "\(unitIDs.count) tasks share the same \(noun): \(value)",
                unitIDs: unitIDs,
                sessionKeys: sessions
            )
        }
    }

    private static func stableKey(_ value: String) -> String {
        // FNV-1a is deterministic across launches; Swift's Hasher is not.
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    private static func signalRank(_ kind: WatchSignal.Kind) -> Int {
        switch kind {
        case .sharedDirectory: 0
        case .sharedBranch: 1
        case .orphanedClaim: 2
        case .staleSession: 3
        case .longTool: 4
        case .contextPressure: 5
        }
    }
}
