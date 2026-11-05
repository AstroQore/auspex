import Synchronization

/// A value and the revision it was published under, equal when the revisions
/// are.
///
/// ## Why the main actor compares a number instead of the value
///
/// `@Observable` compares an `Equatable` value against the one it replaces and
/// stays quiet when they match — which is what keeps the window affordable,
/// and which also means *every assignment is a comparison*, on the main actor.
/// For `[TaskUnit]` that comparison is a walk over every unit on the board and
/// every member row inside each one; a `sample` of the Tasks page had
/// `TaskUnit.__derived_struct_equals` and `initializeWithCopy for TaskUnit`
/// beside `LiveBoardModel.adopt` on every frame a single session moved.
///
/// The assembler already compares each frame's units against the last on its
/// own executor — see ``AssembledBoardFrame/sharing(_:boardRevision:)`` — so
/// the answer to "did they move" exists before the frame reaches the main
/// actor. This type is how it travels: the revision is bumped exactly when the
/// value moved, and `==` asks only the revision.
///
/// The price is the obvious one. Two boxes holding equal values under
/// different revisions compare unequal, so a value must only ever be boxed by
/// the code that decided whether it moved.
public struct Revisioned<Value: Sendable>: Sendable, Equatable {
    public let revision: UInt64
    public let value: Value

    public init(revision: UInt64, value: Value) {
        self.revision = revision
        self.value = value
    }

    public static func == (lhs: Revisioned, rhs: Revisioned) -> Bool {
        lhs.revision == rhs.revision
    }
}

/// Fresh revisions, unique within the process.
///
/// A frame derived without a previous one to reconcile against — the first
/// frame, or one a test builds by hand — has no revision to inherit, and
/// starting every such frame at `1` would make two different hand-built
/// frames look like the same one. Drawing from one process-wide counter makes
/// a fresh derivation always count as new, which is the safe answer.
public enum RevisionCounter {
    private static let counter = Atomic<UInt64>(0)

    /// The next revision. Never zero, never repeated.
    public static func next() -> UInt64 {
        counter.wrappingAdd(1, ordering: .relaxed).newValue
    }
}
