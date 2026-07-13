import Connections
import DBCore
import DBDriverSQLite
import Foundation
import Testing

@testable import Dbosk

/// Sidebar structure at legacy-system scale: several databases with
/// thousands of tables each must build and rebuild without noticeable cost.
@Suite @MainActor struct SidebarScaleTests {
    /// 3 databases × 1000 tables, some hidden and some grouped.
    private func makeSession() throws -> (ConnectionSession, [Namespace]) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dbosk-scale-\(UUID().uuidString).sqlite")
        let driver = try SQLiteDriver(
            config: ResolvedConnectionConfig(filePath: dir.path))
        let profile = ConnectionProfile(
            name: "scale-test", driverID: "sqlite", filePath: dir.path)
        let session = ConnectionSession(profile: profile, driver: driver)

        var roots: [Namespace] = []
        for db in ["legacy_a", "legacy_b", "legacy_c"] {
            let root = Namespace(path: [db], kind: .database, isExpandable: true)
            roots.append(root)
            session.children[root.id] = (0..<1000).map {
                Namespace(
                    path: [db, "table_with_a_long_realistic_name_\($0)"],
                    kind: .table(.table), isExpandable: false)
            }
        }
        session.rootNamespaces = roots
        // Annotate a slice: every 10th table hidden, every 25th grouped.
        for root in roots {
            for (index, table) in (session.children[root.id] ?? []).enumerated() {
                if index % 10 == 0 {
                    session.metadata.update(table.path) { $0.hidden = true }
                }
                if index % 25 == 0 {
                    session.metadata.update(table.path) { $0.group = "Core" }
                }
            }
        }
        return (session, roots)
    }

    @Test func childrenAreCorrectAtScale() throws {
        let (session, roots) = try makeSession()
        let kinds = try #require(session.sidebarChildren(of: roots[0]))

        // 1000 tables: 100 hidden, of which the %25∩%10 overlap stays in the
        // group folder. Visible ungrouped = 1000 - 40 (grouped) - 90 hidden
        // ungrouped (indices %10 == 0 but not %25 == 0: 100 - 20 = 80)...
        // Count explicitly instead of arithmetic in a comment:
        var expectedUngrouped = 0
        var expectedGroupedVisible = 0
        for index in 0..<1000 {
            let hidden = index % 10 == 0
            let grouped = index % 25 == 0
            if grouped {
                if !hidden { expectedGroupedVisible += 1 }
            } else if !hidden {
                expectedUngrouped += 1
            }
        }
        let groupFolders = kinds.filter {
            if case .group = $0 { return true } else { return false }
        }
        #expect(groupFolders.count == 1)
        #expect(kinds.count == 1 + expectedUngrouped)

        let groupChildren = session.sidebarGroupChildren(group: "Core", in: roots[0])
        #expect(groupChildren.count == expectedGroupedVisible)

        // Edit mode reveals everything.
        session.editingVisibility = true
        let editKinds = try #require(session.sidebarChildren(of: roots[0]))
        let editGroup = session.sidebarGroupChildren(group: "Core", in: roots[0])
        #expect(editKinds.count + editGroup.count == 1000 + 1)  // + group folder
    }

    @Test func flattenedRowsFollowExpansion() throws {
        let (session, roots) = try makeSession()

        // Collapsed: only the three database rows.
        #expect(session.sidebarRows(expanded: []).count == 3)

        // Expanding one root adds its group folder and visible ungrouped
        // tables at depth 1; the collapsed group folder hides its children.
        let expanded = session.sidebarRows(expanded: [roots[0].id])
        let root0Children = try #require(session.sidebarChildren(of: roots[0]))
        #expect(expanded.count == 3 + root0Children.count)
        #expect(expanded[1].depth == 1)
        #expect(expanded[0].checkState == nil)

        // Edit mode: every row carries a checkbox state; a hidden table is
        // unchecked and its parent database reports mixed.
        session.editingVisibility = true
        let editing = session.sidebarRows(expanded: [roots[0].id])
        #expect(editing.allSatisfy { $0.checkState != nil })
        #expect(editing[0].checkState == .mixed)
        let hiddenRows = editing.filter(\.isHidden)
        #expect(!hiddenRows.isEmpty)
        #expect(hiddenRows.allSatisfy { $0.checkState == .unchecked })
    }

    @Test func repeatedAccessIsCached() throws {
        let (session, roots) = try makeSession()
        // Warm the cache once per root.
        for root in roots { _ = session.sidebarChildren(of: root) }

        let clock = ContinuousClock()
        let elapsed = clock.measure {
            // A render pass touches every expanded node; simulate many.
            for _ in 0..<200 {
                for root in roots {
                    _ = session.sidebarChildren(of: root)
                    _ = session.sidebarGroupChildren(group: "Core", in: roots[0])
                }
            }
        }
        // 600 cached tree accesses over 3×1000 tables. Generous ceiling —
        // this guards against accidentally reintroducing per-access
        // recomputation (which took seconds at this scale), not CI jitter.
        #expect(elapsed < .milliseconds(200), "cached access took \(elapsed)")
    }
}
