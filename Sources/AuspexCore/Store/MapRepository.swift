import Foundation
import GRDB

/// Durable user-owned Map state.
///
/// Every mutating method writes the current projection and its history row in
/// one transaction. Reads are synchronous values over the shared GRDB writer,
/// matching the other repositories in this target; app models call them away
/// from the main actor.
public struct MapRepository: Sendable {
    public let dbWriter: any DatabaseWriter

    public init(dbWriter: any DatabaseWriter) {
        self.dbWriter = dbWriter
    }

    public init(store: AuspexStore) {
        self.dbWriter = store.dbWriter
    }

    // MARK: Boards

    public func boards(includingDeleted: Bool = false) throws -> [MapBoard] {
        try dbWriter.read { db in
            var sql = "SELECT * FROM map_boards"
            if !includingDeleted { sql += " WHERE deleted_at IS NULL" }
            sql += " ORDER BY sort_order ASC, created_at ASC, id ASC"
            return try Row.fetchAll(db, sql: sql).compactMap(Self.board(row:))
        }
    }

    public func board(id: String) throws -> MapBoard? {
        try dbWriter.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM map_boards WHERE id = ?", arguments: [id])
                .flatMap(Self.board(row:))
        }
    }

    @discardableResult
    public func createBoard(
        name: String,
        rule: MapRule? = nil,
        rulesPaused: Bool = false,
        parentBoardID: String? = nil,
        forkEventID: Int64? = nil,
        now: Date = Date()
    ) throws -> MapBoard {
        let title = try Self.validatedName(name)
        try rule?.validate()
        return try dbWriter.write { db in
            if let parentBoardID {
                guard try Self.board(id: parentBoardID, in: db) != nil else {
                    throw MapRepositoryError.boardNotFound(parentBoardID)
                }
            }
            let order = try Int.fetchOne(
                db,
                sql: "SELECT COALESCE(MAX(sort_order), 0) + 1 FROM map_boards"
            ) ?? 1
            let board = MapBoard(
                id: UUID().uuidString.lowercased(),
                name: title,
                kind: .custom,
                rule: rule,
                rulesPaused: rulesPaused,
                sortOrder: order,
                createdAt: now,
                updatedAt: now,
                parentBoardID: parentBoardID,
                forkEventID: forkEventID,
                mergeBaseEventID: forkEventID
            )
            try Self.insert(board, in: db)
            try Self.appendHistory(
                kind: .boardCreated,
                boardID: board.id,
                payload: board,
                at: now,
                in: db
            )
            return board
        }
    }

    @discardableResult
    public func renameBoard(id: String, name: String, now: Date = Date()) throws -> MapBoard {
        let title = try Self.validatedName(name)
        return try updateBoard(id: id, now: now) { board in
            board.name = title
        }
    }

    @discardableResult
    public func setRule(
        boardID: String,
        rule: MapRule?,
        now: Date = Date()
    ) throws -> MapBoard {
        try rule?.validate()
        return try updateBoard(id: boardID, historyKind: .rulesChanged, now: now) { board in
            guard !board.isProtected else { throw MapRepositoryError.protectedBoard }
            board.rule = rule
        }
    }

    @discardableResult
    public func setRulesPaused(
        boardID: String,
        paused: Bool,
        now: Date = Date()
    ) throws -> MapBoard {
        try updateBoard(
            id: boardID,
            historyKind: paused ? .rulesPaused : .rulesResumed,
            now: now
        ) { board in
            guard !board.isProtected else { throw MapRepositoryError.protectedBoard }
            board.rulesPaused = paused
        }
    }

    @discardableResult
    public func deleteBoard(id: String, now: Date = Date()) throws -> MapBoard {
        try updateBoard(id: id, historyKind: .boardDeleted, now: now) { board in
            guard !board.isProtected else { throw MapRepositoryError.protectedBoard }
            board.deletedAt = board.deletedAt ?? now
        }
    }

    @discardableResult
    public func restoreBoard(id: String, now: Date = Date()) throws -> MapBoard {
        try updateBoard(id: id, historyKind: .boardRestored, now: now) { board in
            guard !board.isProtected else { throw MapRepositoryError.protectedBoard }
            board.deletedAt = nil
        }
    }

    private func updateBoard(
        id: String,
        historyKind: MapHistoryKind = .boardUpdated,
        now: Date,
        mutate: (inout MapBoard) throws -> Void
    ) throws -> MapBoard {
        try dbWriter.write { db in
            guard var board = try Self.board(id: id, in: db) else {
                throw MapRepositoryError.boardNotFound(id)
            }
            let previous = board
            try mutate(&board)
            guard board != previous else { return board }
            board.updatedAt = now
            try Self.update(board, in: db)
            try Self.appendHistory(
                kind: historyKind,
                boardID: board.id,
                payload: board,
                at: now,
                in: db
            )
            return board
        }
    }

    // MARK: Current workspace

    /// Reconciles one board with the current task-shaped frame.
    ///
    /// This never moves an existing placement. A missing placement receives
    /// one deterministic empty grid cell and owns it from then on.
    public func synchronize(
        boardID: String,
        descriptors: [MapNodeDescriptor],
        now: Date = Date()
    ) throws -> MapWorkspaceSnapshot {
        try dbWriter.write { db in
            guard let board = try Self.board(id: boardID, in: db), !board.isDeleted else {
                throw MapRepositoryError.boardNotFound(boardID)
            }

            var existing = try Self.placedNodes(boardID: boardID, in: db)
            var synchronized: [MapSynchronizedNode] = []
            synchronized.reserveCapacity(descriptors.count)
            var seen: Set<String> = []

            for descriptor in descriptors {
                let node = try Self.resolveNode(descriptor, at: now, in: db)
                seen.insert(node.id)
                let previousMembership = try Self.membership(
                    boardID: boardID,
                    nodeID: node.id,
                    in: db
                )
                let matches: Bool
                if board.kind == .all {
                    matches = true
                } else if board.rulesPaused {
                    matches = previousMembership?.ruleMatches ?? false
                } else {
                    matches = board.rule?.matches(descriptor.candidate(nodeID: node.id)) ?? false
                }
                let membership = MapMembership(
                    boardID: boardID,
                    nodeID: node.id,
                    ruleMatches: matches,
                    override: previousMembership?.override,
                    updatedAt: now
                )
                if membership != previousMembership {
                    try Self.upsert(membership, in: db)
                    try Self.appendHistory(
                        kind: .membershipChanged,
                        boardID: boardID,
                        nodeID: node.id,
                        taskID: node.taskID,
                        payload: membership,
                        at: now,
                        in: db
                    )
                }

                var placement = try Self.placement(boardID: boardID, nodeID: node.id, in: db)
                if placement == nil, membership.isVisible {
                    let point = MapPlacementPlanner.next(
                        projectKey: node.projectKey,
                        existing: existing.map {
                            .init(point: $0.placement.point, projectKey: $0.node.projectKey)
                        }
                    )
                    let next = MapPlacement(
                        boardID: boardID,
                        nodeID: node.id,
                        x: point.x,
                        y: point.y,
                        zIndex: (existing.map(\.placement.zIndex).max() ?? -1) + 1,
                        isDormant: !membership.isVisible,
                        createdAt: now,
                        updatedAt: now
                    )
                    try Self.upsert(next, in: db)
                    try Self.appendHistory(
                        kind: .placementChanged,
                        boardID: boardID,
                        nodeID: node.id,
                        taskID: node.taskID,
                        payload: next,
                        at: now,
                        in: db
                    )
                    placement = next
                    existing.append((node, next))
                } else if var current = placement, current.isDormant == membership.isVisible {
                    current.isDormant = !membership.isVisible
                    current.updatedAt = now
                    try Self.upsert(current, in: db)
                    placement = current
                }

                if var current = placement, membership.isVisible, current.isDormant {
                    current.isDormant = false
                    current.updatedAt = now
                    try Self.upsert(current, in: db)
                    placement = current
                }
                synchronized.append(
                    MapSynchronizedNode(
                        sourceID: descriptor.sourceID,
                        node: node,
                        membership: membership,
                        placement: placement
                    )
                )
            }

            // A current frame no longer carries these nodes. Their placements
            // remain; they simply stop being active on this board.
            let stale = try Self.memberships(boardID: boardID, in: db)
                .filter { !seen.contains($0.nodeID) && $0.ruleMatches }
            for var membership in stale {
                membership.ruleMatches = false
                membership.updatedAt = now
                try Self.upsert(membership, in: db)
                if var placement = try Self.placement(
                    boardID: boardID,
                    nodeID: membership.nodeID,
                    in: db
                ) {
                    placement.isDormant = true
                    placement.updatedAt = now
                    try Self.upsert(placement, in: db)
                }
                try Self.appendHistory(
                    kind: .membershipChanged,
                    boardID: boardID,
                    nodeID: membership.nodeID,
                    payload: membership,
                    at: now,
                    in: db
                )
            }

            synchronized.sort {
                let left = $0.placement?.zIndex ?? Int64.max
                let right = $1.placement?.zIndex ?? Int64.max
                if left != right {
                    return left < right
                }
                return $0.node.id < $1.node.id
            }
            return MapWorkspaceSnapshot(board: board, nodes: synchronized)
        }
    }

    @discardableResult
    public func setMembershipOverride(
        boardID: String,
        nodeID: String,
        override: MapMembershipOverride?,
        now: Date = Date()
    ) throws -> MapMembership {
        try dbWriter.write { db in
            guard let board = try Self.board(id: boardID, in: db), !board.isDeleted else {
                throw MapRepositoryError.boardNotFound(boardID)
            }
            guard !board.isProtected else { throw MapRepositoryError.protectedBoard }
            guard var membership = try Self.membership(boardID: boardID, nodeID: nodeID, in: db) else {
                throw MapRepositoryError.nodeNotFound(nodeID)
            }
            guard membership.override != override else { return membership }
            membership.override = override
            membership.updatedAt = now
            try Self.upsert(membership, in: db)
            if var placement = try Self.placement(boardID: boardID, nodeID: nodeID, in: db) {
                placement.isDormant = !membership.isVisible
                placement.updatedAt = now
                try Self.upsert(placement, in: db)
            }
            try Self.appendHistory(
                kind: .membershipChanged,
                boardID: boardID,
                nodeID: nodeID,
                payload: membership,
                at: now,
                in: db
            )
            return membership
        }
    }

    @discardableResult
    public func move(
        boardID: String,
        nodeID: String,
        to point: CGPoint,
        now: Date = Date()
    ) throws -> MapPlacement {
        try dbWriter.write { db in
            guard var placement = try Self.placement(boardID: boardID, nodeID: nodeID, in: db) else {
                throw MapRepositoryError.nodeNotFound(nodeID)
            }
            let snapped = MapPlacementPlanner.snapped(point)
            guard placement.point != snapped else { return placement }
            placement.x = snapped.x
            placement.y = snapped.y
            placement.zIndex = (try Int64.fetchOne(
                db,
                sql: "SELECT COALESCE(MAX(z_index), 0) + 1 FROM map_placements WHERE board_id = ?",
                arguments: [boardID]
            )) ?? placement.zIndex
            placement.updatedAt = now
            try Self.upsert(placement, in: db)
            try Self.appendHistory(
                kind: .placementChanged,
                boardID: boardID,
                nodeID: nodeID,
                payload: placement,
                at: now,
                in: db
            )
            return placement
        }
    }

    public func viewport(boardID: String) throws -> MapViewport? {
        try dbWriter.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT * FROM map_viewports WHERE board_id = ?",
                arguments: [boardID]
            ).flatMap(Self.viewport(row:))
        }
    }

    public func save(viewport: MapViewport) throws {
        var value = viewport
        value.zoom = min(4, max(0.25, value.zoom))
        try dbWriter.write { db in
            try db.execute(
                sql: """
                    INSERT INTO map_viewports
                        (board_id, center_x, center_y, zoom, updated_at)
                    VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(board_id) DO UPDATE SET
                        center_x = excluded.center_x,
                        center_y = excluded.center_y,
                        zoom = excluded.zoom,
                        updated_at = excluded.updated_at
                    """,
                arguments: [
                    value.boardID, value.centerX, value.centerY, value.zoom,
                    value.updatedAt.timeIntervalSince1970
                ]
            )
        }
    }

    public func history(
        boardID: String? = nil,
        after id: Int64 = 0,
        limit: Int = 100_000
    ) throws -> [MapHistoryEntry] {
        guard limit > 0 else { return [] }
        return try dbWriter.read { db in
            var sql = "SELECT * FROM board_history WHERE id > ?"
            var arguments: StatementArguments = [id]
            if let boardID {
                sql += " AND (board_id = ? OR board_id IS NULL)"
                arguments += [boardID]
            }
            sql += " ORDER BY id ASC LIMIT ?"
            arguments += [limit]
            return try Row.fetchAll(db, sql: sql, arguments: arguments)
                .compactMap(Self.history(row:))
        }
    }

    // MARK: Rows and statements

    static func appendHistory(
        kind: MapHistoryKind,
        boardID: String? = nil,
        nodeID: String? = nil,
        taskID: Int64? = nil,
        sessionKey: String? = nil,
        payload: some Encodable,
        at date: Date,
        in db: Database
    ) throws {
        let json = try StoreJSON.encodeToString(payload, using: StoreJSON.makeEncoder())
        try db.execute(
            sql: """
                INSERT INTO board_history
                    (ts, kind, board_id, node_id, task_id, session_key, payload_json)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                date.timeIntervalSince1970, kind.rawValue, boardID, nodeID,
                taskID, sessionKey, json
            ]
        )
    }

    private static func resolveNode(
        _ descriptor: MapNodeDescriptor,
        at now: Date,
        in db: Database
    ) throws -> MapNode {
        let byRoot = try descriptor.rootSessionKey.flatMap { root in
            try Row.fetchOne(
                db,
                sql: "SELECT * FROM map_nodes WHERE root_session_key = ?",
                arguments: [root]
            ).flatMap(node(row:))
        }
        let byTask = try descriptor.taskID.flatMap { task in
            try Row.fetchOne(
                db,
                sql: "SELECT * FROM map_nodes WHERE task_id = ?",
                arguments: [task]
            ).flatMap(node(row:))
        }

        var value: MapNode
        if let byRoot, let byTask, byRoot.id != byTask.id {
            value = byRoot.createdAt <= byTask.createdAt ? byRoot : byTask
            let duplicate = value.id == byRoot.id ? byTask : byRoot
            try merge(primary: value.id, duplicate: duplicate.id, in: db)
            try appendHistory(
                kind: .nodeMerged,
                nodeID: value.id,
                taskID: descriptor.taskID,
                payload: ["primary": value.id, "duplicate": duplicate.id],
                at: now,
                in: db
            )
        } else if let existing = byRoot ?? byTask {
            value = existing
        } else {
            value = MapNode(
                id: UUID().uuidString.lowercased(),
                taskID: descriptor.taskID,
                rootSessionKey: descriptor.rootSessionKey,
                projectKey: descriptor.projectKey,
                createdAt: now,
                updatedAt: now
            )
            try insert(value, in: db)
            try appendHistory(
                kind: .nodeBound,
                nodeID: value.id,
                taskID: value.taskID,
                payload: value,
                at: now,
                in: db
            )
            return value
        }

        let previous = value
        if value.taskID == nil { value.taskID = descriptor.taskID }
        if value.rootSessionKey == nil { value.rootSessionKey = descriptor.rootSessionKey }
        value.projectKey = descriptor.projectKey
        if value != previous {
            value.updatedAt = now
            try update(value, in: db)
            try appendHistory(
                kind: .nodeBound,
                nodeID: value.id,
                taskID: value.taskID,
                payload: value,
                at: now,
                in: db
            )
        }
        return value
    }

    private static func merge(primary: String, duplicate: String, in db: Database) throws {
        let memberships = try Row.fetchAll(
            db,
            sql: "SELECT * FROM map_memberships WHERE node_id = ?",
            arguments: [duplicate]
        ).compactMap(membership(row:))
        for item in memberships {
            let existing = try membership(boardID: item.boardID, nodeID: primary, in: db)
            let merged = MapMembership(
                boardID: item.boardID,
                nodeID: primary,
                ruleMatches: (existing?.ruleMatches ?? false) || item.ruleMatches,
                override: existing?.override ?? item.override,
                updatedAt: max(existing?.updatedAt ?? .distantPast, item.updatedAt)
            )
            try upsert(merged, in: db)
        }
        let placements = try Row.fetchAll(
            db,
            sql: "SELECT * FROM map_placements WHERE node_id = ?",
            arguments: [duplicate]
        ).compactMap(placement(row:))
        for item in placements {
            let existing = try placement(boardID: item.boardID, nodeID: primary, in: db)
            var merged = item
            if let existing, existing.updatedAt >= item.updatedAt { merged = existing }
            merged = MapPlacement(
                boardID: merged.boardID,
                nodeID: primary,
                x: merged.x,
                y: merged.y,
                zIndex: merged.zIndex,
                isDormant: merged.isDormant,
                createdAt: merged.createdAt,
                updatedAt: merged.updatedAt
            )
            try upsert(merged, in: db)
        }
        try db.execute(sql: "DELETE FROM map_nodes WHERE id = ?", arguments: [duplicate])
    }

    private static func board(id: String, in db: Database) throws -> MapBoard? {
        try Row.fetchOne(db, sql: "SELECT * FROM map_boards WHERE id = ?", arguments: [id])
            .flatMap(board(row:))
    }

    private static func insert(_ board: MapBoard, in db: Database) throws {
        let rule = try board.rule.map {
            try StoreJSON.encodeToString($0, using: StoreJSON.makeEncoder())
        }
        try db.execute(
            sql: """
                INSERT INTO map_boards
                    (id, name, kind, rule_json, rules_paused, sort_order,
                     created_at, updated_at, deleted_at, parent_board_id,
                     fork_event_id, merge_base_event_id)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                board.id, board.name, board.kind.rawValue, rule, board.rulesPaused,
                board.sortOrder, board.createdAt.timeIntervalSince1970,
                board.updatedAt.timeIntervalSince1970,
                board.deletedAt?.timeIntervalSince1970, board.parentBoardID,
                board.forkEventID, board.mergeBaseEventID
            ]
        )
    }

    private static func update(_ board: MapBoard, in db: Database) throws {
        let rule = try board.rule.map {
            try StoreJSON.encodeToString($0, using: StoreJSON.makeEncoder())
        }
        try db.execute(
            sql: """
                UPDATE map_boards SET
                    name = ?, rule_json = ?, rules_paused = ?, sort_order = ?,
                    updated_at = ?, deleted_at = ?, parent_board_id = ?,
                    fork_event_id = ?, merge_base_event_id = ?
                WHERE id = ?
                """,
            arguments: [
                board.name, rule, board.rulesPaused, board.sortOrder,
                board.updatedAt.timeIntervalSince1970,
                board.deletedAt?.timeIntervalSince1970, board.parentBoardID,
                board.forkEventID, board.mergeBaseEventID, board.id
            ]
        )
    }

    private static func insert(_ node: MapNode, in db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO map_nodes
                    (id, task_id, root_session_key, project_key, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                node.id, node.taskID, node.rootSessionKey, node.projectKey,
                node.createdAt.timeIntervalSince1970, node.updatedAt.timeIntervalSince1970
            ]
        )
    }

    private static func update(_ node: MapNode, in db: Database) throws {
        try db.execute(
            sql: """
                UPDATE map_nodes SET task_id = ?, root_session_key = ?,
                    project_key = ?, updated_at = ? WHERE id = ?
                """,
            arguments: [
                node.taskID, node.rootSessionKey, node.projectKey,
                node.updatedAt.timeIntervalSince1970, node.id
            ]
        )
    }

    private static func upsert(_ membership: MapMembership, in db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO map_memberships
                    (board_id, node_id, rule_matches, override, updated_at)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(board_id, node_id) DO UPDATE SET
                    rule_matches = excluded.rule_matches,
                    override = excluded.override,
                    updated_at = excluded.updated_at
                """,
            arguments: [
                membership.boardID, membership.nodeID, membership.ruleMatches,
                membership.override?.rawValue, membership.updatedAt.timeIntervalSince1970
            ]
        )
    }

    private static func upsert(_ placement: MapPlacement, in db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO map_placements
                    (board_id, node_id, x, y, z_index, is_dormant, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(board_id, node_id) DO UPDATE SET
                    x = excluded.x, y = excluded.y, z_index = excluded.z_index,
                    is_dormant = excluded.is_dormant, updated_at = excluded.updated_at
                """,
            arguments: [
                placement.boardID, placement.nodeID, placement.x, placement.y,
                placement.zIndex, placement.isDormant,
                placement.createdAt.timeIntervalSince1970,
                placement.updatedAt.timeIntervalSince1970
            ]
        )
    }

    private static func membership(
        boardID: String,
        nodeID: String,
        in db: Database
    ) throws -> MapMembership? {
        try Row.fetchOne(
            db,
            sql: "SELECT * FROM map_memberships WHERE board_id = ? AND node_id = ?",
            arguments: [boardID, nodeID]
        ).flatMap(membership(row:))
    }

    private static func memberships(boardID: String, in db: Database) throws -> [MapMembership] {
        try Row.fetchAll(
            db,
            sql: "SELECT * FROM map_memberships WHERE board_id = ?",
            arguments: [boardID]
        ).compactMap(membership(row:))
    }

    private static func placement(
        boardID: String,
        nodeID: String,
        in db: Database
    ) throws -> MapPlacement? {
        try Row.fetchOne(
            db,
            sql: "SELECT * FROM map_placements WHERE board_id = ? AND node_id = ?",
            arguments: [boardID, nodeID]
        ).flatMap(placement(row:))
    }

    private static func placedNodes(
        boardID: String,
        in db: Database
    ) throws -> [(node: MapNode, placement: MapPlacement)] {
        try Row.fetchAll(
            db,
            sql: """
                SELECT n.*, p.board_id AS p_board_id, p.node_id AS p_node_id,
                       p.x AS p_x, p.y AS p_y, p.z_index AS p_z_index,
                       p.is_dormant AS p_is_dormant,
                       p.created_at AS p_created_at, p.updated_at AS p_updated_at
                  FROM map_placements p JOIN map_nodes n ON n.id = p.node_id
                 WHERE p.board_id = ?
                """,
            arguments: [boardID]
        ).compactMap { row in
            guard let node = node(row: row),
                  let boardID = row["p_board_id"] as String?,
                  let nodeID = row["p_node_id"] as String?,
                  let x = row["p_x"] as Double?,
                  let y = row["p_y"] as Double?,
                  let z = row["p_z_index"] as Int64?,
                  let created = row["p_created_at"] as Double?,
                  let updated = row["p_updated_at"] as Double?
            else { return nil }
            return (
                node,
                MapPlacement(
                    boardID: boardID,
                    nodeID: nodeID,
                    x: x,
                    y: y,
                    zIndex: z,
                    isDormant: row["p_is_dormant"] as Bool? ?? false,
                    createdAt: Date(timeIntervalSince1970: created),
                    updatedAt: Date(timeIntervalSince1970: updated)
                )
            )
        }
    }

    private static func board(row: Row) -> MapBoard? {
        guard let id = row["id"] as String?,
              let name = row["name"] as String?,
              let kindRaw = row["kind"] as String?,
              let kind = MapBoard.Kind(rawValue: kindRaw),
              let created = row["created_at"] as Double?,
              let updated = row["updated_at"] as Double?
        else { return nil }
        let rule: MapRule? = (row["rule_json"] as String?).flatMap {
            try? StoreJSON.decode(MapRule.self, from: $0, using: StoreJSON.makeDecoder())
        }
        return MapBoard(
            id: id,
            name: name,
            kind: kind,
            rule: rule,
            rulesPaused: row["rules_paused"] as Bool? ?? false,
            sortOrder: row["sort_order"] as Int? ?? 0,
            createdAt: Date(timeIntervalSince1970: created),
            updatedAt: Date(timeIntervalSince1970: updated),
            deletedAt: (row["deleted_at"] as Double?).map(Date.init(timeIntervalSince1970:)),
            parentBoardID: row["parent_board_id"],
            forkEventID: row["fork_event_id"],
            mergeBaseEventID: row["merge_base_event_id"]
        )
    }

    private static func node(row: Row) -> MapNode? {
        guard let id = row["id"] as String?,
              let created = row["created_at"] as Double?,
              let updated = row["updated_at"] as Double?
        else { return nil }
        return MapNode(
            id: id,
            taskID: row["task_id"],
            rootSessionKey: row["root_session_key"],
            projectKey: row["project_key"],
            createdAt: Date(timeIntervalSince1970: created),
            updatedAt: Date(timeIntervalSince1970: updated)
        )
    }

    private static func membership(row: Row) -> MapMembership? {
        guard let boardID = row["board_id"] as String?,
              let nodeID = row["node_id"] as String?,
              let updated = row["updated_at"] as Double?
        else { return nil }
        return MapMembership(
            boardID: boardID,
            nodeID: nodeID,
            ruleMatches: row["rule_matches"] as Bool? ?? false,
            override: (row["override"] as String?).flatMap(MapMembershipOverride.init(rawValue:)),
            updatedAt: Date(timeIntervalSince1970: updated)
        )
    }

    private static func placement(row: Row) -> MapPlacement? {
        guard let boardID = row["board_id"] as String?,
              let nodeID = row["node_id"] as String?,
              let x = row["x"] as Double?,
              let y = row["y"] as Double?,
              let z = row["z_index"] as Int64?,
              let created = row["created_at"] as Double?,
              let updated = row["updated_at"] as Double?
        else { return nil }
        return MapPlacement(
            boardID: boardID,
            nodeID: nodeID,
            x: x,
            y: y,
            zIndex: z,
            isDormant: row["is_dormant"] as Bool? ?? false,
            createdAt: Date(timeIntervalSince1970: created),
            updatedAt: Date(timeIntervalSince1970: updated)
        )
    }

    private static func viewport(row: Row) -> MapViewport? {
        guard let boardID = row["board_id"] as String?,
              let x = row["center_x"] as Double?,
              let y = row["center_y"] as Double?,
              let zoom = row["zoom"] as Double?,
              let updated = row["updated_at"] as Double?
        else { return nil }
        return MapViewport(
            boardID: boardID,
            centerX: x,
            centerY: y,
            zoom: zoom,
            updatedAt: Date(timeIntervalSince1970: updated)
        )
    }

    private static func history(row: Row) -> MapHistoryEntry? {
        guard let id = row["id"] as Int64?,
              let timestamp = row["ts"] as Double?,
              let kindRaw = row["kind"] as String?,
              let kind = MapHistoryKind(rawValue: kindRaw),
              let payload = row["payload_json"] as String?
        else { return nil }
        return MapHistoryEntry(
            id: id,
            timestamp: Date(timeIntervalSince1970: timestamp),
            kind: kind,
            boardID: row["board_id"],
            nodeID: row["node_id"],
            taskID: row["task_id"],
            sessionKey: row["session_key"],
            payloadJSON: payload
        )
    }

    private static func validatedName(_ raw: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80 else { throw MapRepositoryError.invalidName }
        return name
    }
}

public enum MapRepositoryError: Error, Equatable, LocalizedError, Sendable {
    case boardNotFound(String)
    case nodeNotFound(String)
    case protectedBoard
    case invalidName

    public var errorDescription: String? {
        switch self {
        case .boardNotFound(let id): "Map board \(id) was not found."
        case .nodeNotFound(let id): "Map node \(id) was not found."
        case .protectedBoard: "All boards is protected."
        case .invalidName: "A board name must contain 1–80 characters."
        }
    }
}
