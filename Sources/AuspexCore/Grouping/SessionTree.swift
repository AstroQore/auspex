import AgentSessionKit
import AgentSessionLive
import Foundation

/// The delegation forest: who spawned whom, across every harness at once.
///
/// A "tree" only in the sense that each node has one parent. What a board
/// actually holds is a forest — several independent roots — and the type is
/// named for the thing a person points at, which is one root and its children.
///
/// Built by ``SessionTreeBuilder`` and then read-only. Every lookup it offers
/// is precomputed, because a board asks `rootKey(for:)` once per row per frame.
public struct SessionTree: Sendable, Equatable {
    /// One session and everything it spawned, transitively.
    public struct Node: Sendable, Equatable, Identifiable {
        /// The session this node is.
        public let key: SessionKey
        /// How far below its root it sits. `0` for a root.
        public let depth: Int
        /// Children in the order they arrived in the input, so a caller that
        /// passed board-sorted sessions gets a board-sorted tree.
        public let children: [Node]

        public var id: SessionKey { key }

        public init(key: SessionKey, depth: Int, children: [Node] = []) {
            self.key = key
            self.depth = depth
            self.children = children
        }

        /// This node and every node below it, depth first.
        public var flattened: [Node] {
            [self] + children.flatMap(\.flattened)
        }
    }

    /// The sessions that have no parent among the sessions given, in input
    /// order.
    public let roots: [Node]

    private let rootBySession: [SessionKey: SessionKey]
    private let descendantsBySession: [SessionKey: [SessionKey]]
    private let nodeBySession: [SessionKey: Node]

    init(
        roots: [Node],
        rootBySession: [SessionKey: SessionKey],
        descendantsBySession: [SessionKey: [SessionKey]],
        nodeBySession: [SessionKey: Node]
    ) {
        self.roots = roots
        self.rootBySession = rootBySession
        self.descendantsBySession = descendantsBySession
        self.nodeBySession = nodeBySession
    }

    /// An empty forest.
    public static let empty = SessionTree(
        roots: [], rootBySession: [:], descendantsBySession: [:], nodeBySession: [:]
    )

    /// The top of the delegation chain `key` belongs to, or `nil` when the
    /// tree has never heard of it.
    ///
    /// A root is its own root, which is what makes this the value
    /// `sessions.root_key` stores for every row.
    public func rootKey(for key: SessionKey) -> SessionKey? {
        rootBySession[key]
    }

    /// Every session below `key`, depth first, excluding `key` itself.
    public func descendants(of key: SessionKey) -> [SessionKey] {
        descendantsBySession[key] ?? []
    }

    /// The node for one session.
    public func node(for key: SessionKey) -> Node? {
        nodeBySession[key]
    }

    /// The root key of every session in the tree — what a store writes into
    /// `sessions.root_key` in one pass.
    public var rootKeys: [SessionKey: SessionKey] { rootBySession }

    /// How many sessions the tree covers.
    public var count: Int { nodeBySession.count }

    /// `true` when there is nothing in it.
    public var isEmpty: Bool { roots.isEmpty }
}

/// Builds a ``SessionTree`` out of what each session's identity claims its
/// parent is.
///
/// Pure and total. The input is whatever the board is holding, which is
/// routinely incomplete and occasionally contradictory:
///
/// - **Orphans are roots.** A subagent whose parent has aged out of the board,
///   or a `codex exec` linked to a Claude session on another set, has a parent
///   that is not here. It becomes a root rather than disappearing — a row that
///   vanishes because its parent did is worse than a row shown at the top.
/// - **Cycles are broken, not followed.** Nothing should produce one — the
///   linker refuses to — but a stored parent from an older build plus a fresh
///   one can still meet in the same set, and a builder that trusted them would
///   hang. A session whose ancestry loops is treated as a root.
/// - **A session is never its own parent.** Self-parents are dropped on the
///   way in.
public enum SessionTreeBuilder {
    /// Builds the forest for a set of board rows.
    public static func build(_ sessions: [SessionSnapshot]) -> SessionTree {
        build(identities: sessions.map(\.identity))
    }

    /// Builds the forest from identities alone, for a caller that has not
    /// reduced them into snapshots.
    public static func build(identities: [SessionIdentity]) -> SessionTree {
        let order = identities.map(\.key)
        let present = Set(order)

        var parents: [SessionKey: SessionKey] = [:]
        for identity in identities {
            guard let parent = identity.parent,
                  parent != identity.key,
                  present.contains(parent)
            else { continue }
            parents[identity.key] = parent
        }

        // Anything whose ancestry does not terminate is unrooted, and treating
        // it as a root is what keeps the walk below finite.
        var rootBySession: [SessionKey: SessionKey] = [:]
        for key in order {
            rootBySession[key] = resolveRoot(of: key, parents: parents)
            if rootBySession[key] == nil {
                parents[key] = nil
                rootBySession[key] = key
            }
        }

        var childrenByParent: [SessionKey: [SessionKey]] = [:]
        for key in order {
            guard let parent = parents[key] else { continue }
            childrenByParent[parent, default: []].append(key)
        }

        var nodeBySession: [SessionKey: Node] = [:]
        var descendantsBySession: [SessionKey: [SessionKey]] = [:]
        var roots: [Node] = []
        for key in order where parents[key] == nil {
            let node = makeNode(
                key: key,
                depth: 0,
                childrenByParent: childrenByParent,
                nodes: &nodeBySession,
                descendants: &descendantsBySession
            )
            roots.append(node)
        }

        return SessionTree(
            roots: roots,
            rootBySession: rootBySession,
            descendantsBySession: descendantsBySession,
            nodeBySession: nodeBySession
        )
    }

    private typealias Node = SessionTree.Node

    /// The root of `key`'s chain, or `nil` when the chain loops.
    private static func resolveRoot(
        of key: SessionKey,
        parents: [SessionKey: SessionKey]
    ) -> SessionKey? {
        var seen: Set<SessionKey> = [key]
        var current = key
        while let parent = parents[current] {
            guard seen.insert(parent).inserted else { return nil }
            current = parent
        }
        return current
    }

    /// Builds one subtree, recording its node and its descendants on the way
    /// back up so neither has to be recomputed per query.
    private static func makeNode(
        key: SessionKey,
        depth: Int,
        childrenByParent: [SessionKey: [SessionKey]],
        nodes: inout [SessionKey: Node],
        descendants: inout [SessionKey: [SessionKey]]
    ) -> Node {
        var children: [Node] = []
        var below: [SessionKey] = []
        for child in childrenByParent[key] ?? [] {
            let node = makeNode(
                key: child,
                depth: depth + 1,
                childrenByParent: childrenByParent,
                nodes: &nodes,
                descendants: &descendants
            )
            children.append(node)
            below.append(child)
            below.append(contentsOf: descendants[child] ?? [])
        }
        let node = Node(key: key, depth: depth, children: children)
        nodes[key] = node
        descendants[key] = below
        return node
    }
}
