import Foundation
import Testing

@testable import AuspexCore

@Suite("TaskBrief and title normalization")
struct TaskBriefTests {
    @Test("the structured fields are composed in one fixed order, blanks dropped")
    func composesInOrder() {
        let brief = TaskBrief(
            objective: "  Retire the old endpoint. ",
            acceptance: ["CartTests pass", "   ", "docs/cart.md exists"],
            deliverable: nil,
            scope: "Sources/Cart",
            outOfScope: "",
            notes: "Ask before touching the mobile client."
        )
        #expect(brief.isStructured)
        #expect(brief.composed == """
            Objective: Retire the old endpoint.

            Acceptance:
            - CartTests pass
            - docs/cart.md exists

            Scope: Sources/Cart

            Notes:
            Ask before touching the mobile client.
            """)
    }

    @Test("a body on its own is stored exactly as before; nothing at all is nil")
    func plainBodyIsUnchanged() {
        #expect(TaskBrief(notes: "Just the detail.").composed == "Just the detail.")
        #expect(!TaskBrief(notes: "Just the detail.").isStructured)
        #expect(TaskBrief().composed == nil)
    }

    @Test("titles that differ only in case, spacing and punctuation normalize alike")
    func titleNormalization() {
        #expect(TaskTitle.normalized("Fix the login redirect.") == TaskTitle.normalized("  fix the Login-Redirect "))
        #expect(TaskTitle.normalized("Fix the login redirect") != TaskTitle.normalized("Fix the logout redirect"))
        #expect(TaskTitle.normalized("修复登录跳转。") == TaskTitle.normalized("修复 登录跳转"))
        #expect(TaskTitle.normalized("修复登录跳转") != TaskTitle.normalized("修复登出跳转"))
        #expect(TaskTitle.normalized("!!! ...") == "")
    }

    @Test("a title that normalizes to nothing is never a duplicate")
    func emptyTitlesDoNotDeduplicate() throws {
        let store = try AuspexStore(inMemory: true)
        let ledger = TaskRepository(store: store)
        let first = try ledger.fileTask(title: "???", projectKey: "/Users/example/Code/a", deduplicate: true)
        let second = try ledger.fileTask(title: "!!!", projectKey: "/Users/example/Code/a", deduplicate: true)
        #expect(!first.deduplicated)
        #expect(!second.deduplicated)
        #expect(first.task.id != second.task.id)
    }
}
