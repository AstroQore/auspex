import AgentSessionKit
import AgentSessionLive
import Foundation
import Testing

@testable import AuspexCore

@Suite("SessionTree")
struct SessionTreeTests {
    private func snapshot(
        _ key: SessionKey,
        parent: SessionKey? = nil,
        cwd: String? = "/Users/example/Code/widget",
        gitRoot: String? = nil,
        lastEventAt: TimeInterval = 0
    ) -> SessionSnapshot {
        var identity = Fixtures.identity(key: key, cwd: cwd, gitRoot: gitRoot)
        identity.parent = parent
        identity.parentLink = parent == nil ? nil : .subagent(toolUseID: nil)
        var snapshot = SessionStateReducer.initialSnapshot(identity: identity)
        snapshot.lastEventAt = Fixtures.date(lastEventAt)
        return snapshot
    }

    private let root = Fixtures.key(.claudeCode, "root")
    private let child = Fixtures.key(.codex, "child")
    private let grandchild = Fixtures.key(.grokBuild, "grandchild")
    private let sibling = Fixtures.key(.cursor, "sibling")

    @Test("a chain of three becomes one root with a grandchild under it")
    func chain() {
        let tree = SessionTreeBuilder.build([
            snapshot(root),
            snapshot(child, parent: root),
            snapshot(grandchild, parent: child),
        ])

        #expect(tree.roots.map(\.key) == [root])
        #expect(tree.roots[0].children.map(\.key) == [child])
        #expect(tree.roots[0].children[0].children.map(\.key) == [grandchild])
        #expect(tree.node(for: grandchild)?.depth == 2)
        #expect(tree.count == 3)
    }

    @Test("every session's root is the top of its chain, and a root is its own")
    func rootKeys() {
        let tree = SessionTreeBuilder.build([
            snapshot(root),
            snapshot(child, parent: root),
            snapshot(grandchild, parent: child),
        ])
        #expect(tree.rootKey(for: root) == root)
        #expect(tree.rootKey(for: child) == root)
        // The grandchild's root is the root, not its parent.
        #expect(tree.rootKey(for: grandchild) == root)
        #expect(tree.rootKey(for: Fixtures.key(.cursor, "unknown")) == nil)
        #expect(tree.rootKeys.count == 3)
    }

    @Test("descendants are transitive and exclude the session itself")
    func descendants() {
        let tree = SessionTreeBuilder.build([
            snapshot(root),
            snapshot(child, parent: root),
            snapshot(grandchild, parent: child),
            snapshot(sibling, parent: root),
        ])
        #expect(Set(tree.descendants(of: root)) == [child, grandchild, sibling])
        #expect(tree.descendants(of: child) == [grandchild])
        #expect(tree.descendants(of: grandchild).isEmpty)
    }

    @Test("an orphan whose parent is not on the board is a root of its own")
    func orphansAreRoots() {
        let tree = SessionTreeBuilder.build([
            snapshot(child, parent: root),
            snapshot(sibling),
        ])
        #expect(Set(tree.roots.map(\.key)) == [child, sibling])
        #expect(tree.rootKey(for: child) == child)
    }

    @Test("a session that claims itself as parent is a root")
    func selfParentIsIgnored() {
        let tree = SessionTreeBuilder.build([snapshot(root, parent: root)])
        #expect(tree.roots.map(\.key) == [root])
        #expect(tree.roots[0].children.isEmpty)
    }

    @Test("a cycle does not hang, and its members become roots")
    func cyclesAreBroken() {
        // Two stored parents that contradict each other. Nothing should
        // produce this; the builder must survive it anyway.
        let tree = SessionTreeBuilder.build([
            snapshot(root, parent: child),
            snapshot(child, parent: root),
            snapshot(sibling),
        ])
        #expect(tree.count == 3)
        #expect(tree.rootKey(for: sibling) == sibling)
        for key in [root, child] {
            #expect(tree.rootKey(for: key) != nil)
        }
    }

    @Test("siblings keep the order they arrived in")
    func siblingOrder() {
        let first = Fixtures.key(.codex, "aaa")
        let second = Fixtures.key(.codex, "bbb")
        let tree = SessionTreeBuilder.build([
            snapshot(root),
            snapshot(second, parent: root),
            snapshot(first, parent: root),
        ])
        #expect(tree.roots[0].children.map(\.key) == [second, first])
    }

    @Test("an empty board is an empty forest")
    func emptyBoard() {
        let tree = SessionTreeBuilder.build([])
        #expect(tree.isEmpty)
        #expect(tree.count == 0)
        #expect(SessionTree.empty.isEmpty)
    }

    @Test("flattening a node walks it depth first")
    func flattening() {
        let tree = SessionTreeBuilder.build([
            snapshot(root),
            snapshot(child, parent: root),
            snapshot(grandchild, parent: child),
            snapshot(sibling, parent: root),
        ])
        #expect(tree.roots[0].flattened.map(\.key) == [root, child, grandchild, sibling])
    }

    // MARK: - The board

    @Test("a board carries the tree it was built from")
    func boardCarriesTheTree() {
        let board = BoardSnapshot(generatedAt: Fixtures.date(0), sessions: [
            snapshot(root, lastEventAt: 10),
            snapshot(child, parent: root, lastEventAt: 20),
        ])
        #expect(board.tree.roots.map(\.key) == [root])
        #expect(board.tree.rootKey(for: child) == root)
    }

    @Test("a child with no directory of its own groups under its root's project")
    func childInheritsItsRootsProject() {
        let board = BoardSnapshot(generatedAt: Fixtures.date(0), sessions: [
            snapshot(root, cwd: "/Users/example/Code/widget"),
            // A subagent: no process, no cwd line, no idea where it is.
            snapshot(child, parent: root, cwd: nil),
            snapshot(grandchild, parent: child, cwd: nil),
        ])
        #expect(board.byProject["/Users/example/Code/widget"]?.count == 3)
        #expect(board.ungroupedSessions.isEmpty)
    }

    @Test("a chain with no directory anywhere in it stays ungrouped")
    func ungroupedChain() {
        let board = BoardSnapshot(generatedAt: Fixtures.date(0), sessions: [
            snapshot(root, cwd: nil),
            snapshot(child, parent: root, cwd: nil),
        ])
        #expect(board.byProject.isEmpty)
        #expect(Set(board.ungroupedSessions.map(\.key)) == [root, child])
    }

    @Test("a child with its own directory keeps it")
    func childKeepsItsOwnDirectory() {
        let board = BoardSnapshot(generatedAt: Fixtures.date(0), sessions: [
            snapshot(root, cwd: "/Users/example/Code/widget"),
            snapshot(child, parent: root, cwd: "/Users/example/Code/other"),
        ])
        #expect(board.byProject["/Users/example/Code/other"]?.map(\.key) == [child])
        #expect(board.byProject["/Users/example/Code/widget"]?.map(\.key) == [root])
    }

    @Test("an orphan child does not follow a parent that is not there")
    func orphanIsNotGrouped() {
        let board = BoardSnapshot(generatedAt: Fixtures.date(0), sessions: [
            snapshot(child, parent: root, cwd: nil)
        ])
        #expect(board.ungroupedSessions.map(\.key) == [child])
    }
}
