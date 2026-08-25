import AgentSessionKit
import AgentSessionLive
import AuspexCore
import Foundation
import Testing

@testable import AuspexApp

@Suite("Flight event playback")
@MainActor
struct FlightPlaybackTests {
    @Test("history selects observed events and Jump to Live clears the playhead")
    func playheadLifecycle() async throws {
        let store = try AuspexStore(inMemory: true)
        let repository = SessionRepository(store: store)
        let key = SessionKey(harness: .codex, sessionID: "flight-playback")
        let identity = SessionIdentity(
            key: key,
            sourcePath: "/Users/example/.codex/sessions/flight.jsonl",
            cwd: "/Users/example/Code/auspex",
            title: "Build Flight playback"
        )
        try repository.upsert(snapshot: SessionStateReducer.initialSnapshot(identity: identity))
        try repository.insertEvents([
            AgentEvent(
                session: key, timestamp: Date(timeIntervalSince1970: 1),
                kind: .sessionStarted(identity: identity)),
            AgentEvent(session: key, timestamp: Date(timeIntervalSince1970: 2), kind: .thinking),
            AgentEvent(
                session: key,
                timestamp: Date(timeIntervalSince1970: 3),
                kind: .toolCallStarted(
                    id: "edit", name: "Edit", kind: .fileWrite, target: "/Users/example/a")
            ),
            AgentEvent(
                session: key, timestamp: Date(timeIntervalSince1970: 4),
                kind: .toolCallFinished(id: "edit", isError: false)),
        ])

        let model = TrajectoryModel()
        model.open(key: key, repository: repository, isAlive: true)
        for _ in 0..<30 where model.events.count < 4 {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(model.events.count == 4)
        for _ in 0..<30 where model.graphFrame == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.presentation == .graph)
        #expect(model.graphFrame?.nodes.map(\.key) == [key])
        model.selectGraphAgent(key)
        model.presentation = .trace
        #expect(model.selectedID != nil)
        model.presentation = .graph
        #expect(model.selectedAgentKey == key)
        model.updateGraphViewport(pan: CGSize(width: 20, height: 10), zoom: 1.2)
        #expect(model.graphCamera == .manual)

        model.enterHistory(at: 2)
        for _ in 0..<30 where model.playbackMoment == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.isHistory)
        #expect(model.scale == .events)
        #expect(model.historyIndex == 2)
        #expect(
            model.playbackMoment?.state.sessions[key]?.state
                == .writingFile(path: "/Users/example/a"))
        #expect(model.playheadStepID != nil)
        model.jumpToLive()
        #expect(!model.isHistory)
        #expect(model.playheadStepID == nil)
    }

    @Test("live tool completions aggregate into a bounded afterglow")
    func afterglowLifecycle() async throws {
        let store = try AuspexStore(inMemory: true)
        let repository = SessionRepository(store: store)
        let key = SessionKey(harness: .codex, sessionID: "flight-afterglow")
        let identity = SessionIdentity(
            key: key,
            sourcePath: "/Users/example/.codex/sessions/afterglow.jsonl",
            title: "Afterglow"
        )
        try repository.upsert(snapshot: SessionStateReducer.initialSnapshot(identity: identity))
        try repository.insertEvents([
            AgentEvent(
                session: key, timestamp: Date(timeIntervalSince1970: 1),
                kind: .sessionStarted(identity: identity))
        ])
        let model = TrajectoryModel()
        model.open(key: key, repository: repository, isAlive: true)
        for _ in 0..<30 where model.events.count < 1 {
            try await Task.sleep(for: .milliseconds(20))
        }

        try repository.insertEvents([
            AgentEvent(
                session: key, timestamp: Date(timeIntervalSince1970: 2),
                kind: .toolCallStarted(id: "a", name: "Grep", kind: .search, target: nil)),
            AgentEvent(
                session: key, timestamp: Date(timeIntervalSince1970: 3),
                kind: .toolCallFinished(id: "a", isError: false)),
            AgentEvent(
                session: key, timestamp: Date(timeIntervalSince1970: 3.5),
                kind: .toolCallStarted(id: "b", name: "Grep", kind: .search, target: nil)),
            AgentEvent(
                session: key, timestamp: Date(timeIntervalSince1970: 4),
                kind: .toolCallFinished(id: "b", isError: true)),
        ])
        model.refresh(isAlive: true)
        for _ in 0..<40 where model.events.count < 5 {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(model.graphAfterglows.count == 1)
        #expect(model.graphAfterglows.first?.count == 2)
        #expect(model.graphAfterglows.first?.isError == true)
        #expect(model.activeGraphAfterglows(at: Date()).count == 1)

        model.enterHistory(at: 2)
        #expect(model.graphAfterglows.isEmpty)
    }

    @Test("task playback shares one source-time order across graph trace and reducer")
    func taskPlaybackUsesOneCanonicalOrder() async throws {
        let store = try AuspexStore(inMemory: true)
        let repository = SessionRepository(store: store)
        let parent = SessionKey(harness: .claudeCode, sessionID: "parent")
        let child = SessionKey(harness: .codex, sessionID: "child")
        let parentIdentity = SessionIdentity(
            key: parent,
            sourcePath: "/Users/example/.claude/projects/parent.jsonl",
            title: "Parent"
        )
        let childIdentity = SessionIdentity(
            key: child,
            sourcePath: "/Users/example/.codex/sessions/child.jsonl",
            parent: parent,
            title: "Child"
        )
        try repository.upsert(snapshots: [
            SessionStateReducer.initialSnapshot(identity: parentIdentity),
            SessionStateReducer.initialSnapshot(identity: childIdentity),
        ])

        // Persisted in deliberately different order from source time: a late
        // child flush gets larger row ids but belongs earlier in the Flight.
        try repository.insertEvents([
            AgentEvent(
                session: parent, timestamp: Date(timeIntervalSince1970: 10),
                sequence: 2, kind: .sessionStarted(identity: parentIdentity)),
            AgentEvent(
                session: child, timestamp: Date(timeIntervalSince1970: 5),
                sequence: 1, kind: .sessionStarted(identity: childIdentity)),
            AgentEvent(
                session: parent, timestamp: Date(timeIntervalSince1970: 20),
                sequence: 4, kind: .assistantText(preview: "Parent later")),
            AgentEvent(
                session: child, timestamp: Date(timeIntervalSince1970: 15),
                sequence: 3, kind: .thinking),
        ])

        let model = TrajectoryModel()
        model.open(
            key: parent,
            members: [parent, child],
            repository: repository,
            isAlive: true
        )
        model.scope = .task
        for _ in 0..<60 where model.events.count < 4 {
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(model.events.map(\.session) == [child, parent, child, parent])
        #expect(model.events.map(\.timestamp) == model.events.map(\.timestamp).sorted())

        model.enterHistory(at: 0)
        for _ in 0..<60 where model.playbackMoment == nil || model.graphFrame == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        for index in model.events.indices {
            model.seek(to: index)
            guard case .session(let reducedEvent) = model.playbackMoment?.event else {
                Issue.record("event \(index) was not the shared session event")
                continue
            }
            #expect(reducedEvent.id == model.events[index].id)
            #expect(model.graphFrame?.index == index)
            #expect(model.graphFrame?.timestamp == model.events[index].timestamp)
            let expectedStep = model.steps.last { step in
                (model.events.firstIndex { $0.id == step.id } ?? .max) <= index
            }?.id
            #expect(model.playheadStepID == expectedStep)
        }

        let retainedID = model.events[model.historyIndex].id
        try repository.insertEvents([
            AgentEvent(
                session: child,
                timestamp: Date(timeIntervalSince1970: 7),
                sequence: 1,
                kind: .assistantText(preview: "Late child history")
            )
        ])
        model.refresh(isAlive: true)
        for _ in 0..<80
        where model.events.count < 5 || model.events[model.historyIndex].id != retainedID {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(model.events[model.historyIndex].id == retainedID)
    }
}
