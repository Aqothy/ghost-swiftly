import Synchronization
import Testing
@testable import GhosttyVT

struct RenderStateTests {
    private func text(_ row: RenderRow) -> String {
        String(String.UnicodeScalarView(row.cells.compactMap { Unicode.Scalar($0.codepoint) }.filter { $0 != "\0" }))
    }

    private func rows(_ update: RenderUpdate?) -> [Int: String] {
        Dictionary(uniqueKeysWithValues: (update?.rows ?? []).map { ($0.y, text($0)) })
    }

    @Test func updatesCarryDecodedRowsAndNothingWhenIdle() async throws {
        let wakes = Mutex(0)
        let state = try RenderState { wakes.withLock { $0 += 1 } }
        let terminal = try Terminal(grid: Grid(columns: 10, rows: 3))
        await terminal.attach(state)
        _ = state.takeUpdate()

        await terminal.feed(Array("a\u{1b}[1;31mb\u{1b}[0m日".utf8))
        let update = try #require(state.takeUpdate())
        let row = try #require(update.rows.first { $0.y == 0 })
        #expect(text(row) == "ab日")
        #expect(row.cells[0].style == .default)
        #expect(row.cells[1].style.bold)
        #expect(row.cells[1].style.foreground == .palette(1))
        #expect(row.cells[2].wide == .wide)
        #expect(row.cells[3].wide == .spacerTail)
        #expect(update.cursor.viewport?.x == 4)
        #expect(wakes.withLock { $0 } >= 2)

        // Nothing changed, so there's nothing to draw.
        #expect(state.takeUpdate() == nil)
    }

    @Test func aRenderHoldKeepsTheFrameFromWhenItBegan() async throws {
        let state = try RenderState {}
        let terminal = try Terminal(grid: Grid(columns: 20, rows: 3))
        await terminal.attach(state)
        _ = state.takeUpdate()

        // Everything before ?2026h is on screen; nothing after it shows until
        // ?2026l, even within one write.
        await terminal.feed(Array("first\u{1b}[?2026h\r\u{1b}[2Kpartial".utf8))
        #expect(rows(state.takeUpdate())[0] == "first")
        await terminal.feed(Array(" more".utf8))
        #expect(state.takeUpdate() == nil)

        await terminal.feed(Array("\u{1b}[?2026l".utf8))
        #expect(rows(state.takeUpdate())[0] == "partial more")
    }
}
