import Foundation
import Testing
@testable import GhosttyVT

/// The fixture is a snapshot from the Go binding the maiD daemon encodes
/// with, at the same Ghostty commit (Script/snapshot-fixture). Its expected
/// values are what the encoding terminal itself reported.
struct SnapshotFixtureTests {
    struct Expected: Decodable {
        var commit: String
        var columns: UInt16
        var rows: UInt16
        var scrollbackRows: Int
        var cursorX: UInt16
        var cursorY: UInt16
        var bracketedPaste: Bool
        var title: String
        var plain: String
        var tail: String
        var plainAfterTail: String
    }

    let expected: Expected
    let snapshot: Data

    init() throws {
        let fixtures = try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
        expected = try JSONDecoder().decode(
            Expected.self, from: Data(contentsOf: fixtures.appending(path: "snapshot.json")))
        snapshot = try Data(contentsOf: fixtures.appending(path: "snapshot.ghostsnp"))
    }

    @Test func fixtureMatchesTheLinkedLibrary() {
        #expect(BuildInfo.commit == expected.commit)
    }

    @Test func restoresTheEncodedTerminal() async throws {
        let terminal = try Terminal(grid: Grid(columns: 10, rows: 5))
        try await terminal.restore(snapshot: snapshot)

        // READY: the screen, cursor and modes are usable before any history.
        #expect(await terminal.grid == Grid(columns: expected.columns, rows: expected.rows))
        let cursor = await terminal.cursor
        #expect(cursor.x == expected.cursorX)
        #expect(cursor.y == expected.cursorY)
        #expect(await terminal.isEnabled(.bracketedPaste) == expected.bracketedPaste)
        #expect(await terminal.title == expected.title)
        let visible = try await terminal.text()
        #expect(visible.contains("cursor here"))
        #expect(expected.plain.hasSuffix(visible))

        var restoredRows = 0
        while true {
            switch try await terminal.restoreHistoryPage() {
            case .restored(let rows): restoredRows += rows
            case .dropped: Issue.record("a history page was dropped")
            case .finished:
                #expect(restoredRows > 0)
                #expect(await terminal.scrollbackRows == expected.scrollbackRows)
                #expect(try await terminal.text() == expected.plain)
                return
            }
        }
    }

    @Test func continuesTheUnfinishedSequenceAfterRestore() async throws {
        let terminal = try Terminal(grid: Grid(columns: 10, rows: 5))
        try await terminal.restore(snapshot: snapshot)
        while try await terminal.restoreHistoryPage() != .finished {}

        await terminal.feed(Array(expected.tail.utf8))

        let text = try await terminal.text()
        #expect(text == expected.plainAfterTail)
        // The snapshot ended inside "ESC [ 3"; the tail completes it as SGR 31,
        // so no stray "1m" text appears.
        #expect(text.contains("cursor here RED after"))
    }

    @Test func effectsFireOnTheRestoredTerminal() async throws {
        // A restore replaces the native terminal, which must get the effect
        // callbacks again.
        let events = try await events { terminal in
            try await terminal.restore(snapshot: snapshot)
            await terminal.feed(Array("\u{07}".utf8))
        }
        #expect(events == [.bell])
    }
}
