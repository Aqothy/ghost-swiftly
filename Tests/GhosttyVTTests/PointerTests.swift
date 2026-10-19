import Testing
@testable import GhosttyVT

struct PointerTests {
    /// 20x5 cells of 10x20 pixels, no padding.
    private let geometry = MouseGeometry(screenWidth: 200, screenHeight: 100, cellWidth: 10, cellHeight: 20)
    private let interval = Duration.milliseconds(500)

    /// The surface pixel at the middle of a cell.
    private func at(_ column: Int, _ row: Int) -> (x: Double, y: Double) {
        (Double(column) * 10 + 5, Double(row) * 20 + 10)
    }

    private func terminal(_ output: String) async throws -> Terminal {
        let terminal = try Terminal(grid: GridSize(columns: 20, rows: 5))
        await terminal.feed(Array(output.utf8))
        return terminal
    }

    @Test func dragAndDoubleClickSelect() async throws {
        let terminal = try await terminal("hello world")
        var point = at(0, 0)
        _ = await terminal.mouseButton(.press, .left, modifiers: [], x: point.x, y: point.y,
                                       geometry: geometry, clickInterval: interval)
        // Past the middle of the last cell, which Ghostty requires to include it.
        point = (48, 10)
        _ = await terminal.mouseMoved(modifiers: [], x: point.x, y: point.y, geometry: geometry)
        _ = await terminal.mouseButton(.release, .left, modifiers: [], x: point.x, y: point.y,
                                       geometry: geometry, clickInterval: interval)
        let dragged = await terminal.selectionText()
        #expect(dragged == "hello")

        point = at(8, 0)
        for _ in 0..<2 {
            _ = await terminal.mouseButton(.press, .left, modifiers: [], x: point.x, y: point.y,
                                           geometry: geometry, clickInterval: interval)
            _ = await terminal.mouseButton(.release, .left, modifiers: [], x: point.x, y: point.y,
                                           geometry: geometry, clickInterval: interval)
        }
        #expect(await terminal.selectionText() == "world")

        _ = await terminal.mouseButton(.press, .left, modifiers: [], x: point.x, y: point.y,
                                       geometry: geometry, clickInterval: interval)
        #expect(await terminal.selectionText() == "hello world")

        // Typing clears it.
        _ = await terminal.type(KeyEvent(key: .a, text: "a"), optionAsAlt: .none)
        #expect(await terminal.selectionText() == nil)
    }

    @Test func trackedClicksAreReportedAndShiftSelects() async throws {
        // Normal tracking, SGR format.
        let terminal = try await terminal("hello\u{1b}[?1000h\u{1b}[?1006h")
        var point = at(2, 1)
        let press = await terminal.mouseButton(.press, .left, modifiers: [], x: point.x, y: point.y,
                                               geometry: geometry, clickInterval: interval)
        #expect(press == .reported(Array("\u{1b}[<0;3;2M".utf8)))
        _ = await terminal.mouseButton(.release, .left, modifiers: [], x: point.x, y: point.y,
                                       geometry: geometry, clickInterval: interval)
        #expect(await terminal.hasSelection == false)

        point = at(0, 0)
        #expect(await terminal.mouseButton(.press, .left, modifiers: .shift, x: point.x, y: point.y,
                                           geometry: geometry, clickInterval: interval) == .local)
        point = (48, 10)
        #expect(await terminal.mouseMoved(modifiers: .shift, x: point.x, y: point.y, geometry: geometry).isEmpty)
        let dragged = await terminal.selectionText()
        #expect(dragged == "hello")
    }

    @Test func wheelOnTheAlternateScreenSendsArrowKeys() async throws {
        // Alternate screen with alternate scroll (1007), application cursor keys.
        let terminal = try await terminal("\u{1b}[?1049h\u{1b}[?1007h\u{1b}[?1h")
        #expect(await terminal.scroll(x: 0, y: 2, precise: false, geometry: geometry)
            == Array("\u{1b}OA\u{1b}OA\u{1b}OA\u{1b}OA\u{1b}OA\u{1b}OA".utf8))
        #expect(await terminal.scroll(x: 0, y: -1, precise: false, geometry: geometry)
            == Array("\u{1b}OB\u{1b}OB\u{1b}OB".utf8))
    }

    @Test func wheelOnThePrimaryScreenScrollsTheViewport() async throws {
        let state = try RenderState {}
        let terminal = try await terminal((1...20).map { "line \($0)" }.joined(separator: "\r\n"))
        await terminal.attach(state)
        let bottom = try #require(state.takeUpdate()).scrollbar.offset

        // One discrete tick is three rows (Ghostty's default multiplier).
        #expect(await terminal.scroll(x: 0, y: 1, precise: false, geometry: geometry).isEmpty)
        #expect(try #require(state.takeUpdate()).scrollbar.offset == bottom - 3)

        // Less than a row of precise scrolling waits for more.
        #expect(await terminal.scroll(x: 0, y: 15, precise: true, geometry: geometry).isEmpty)
        #expect(state.takeUpdate() == nil)
        _ = await terminal.scroll(x: 0, y: 10, precise: true, geometry: geometry)
        #expect(try #require(state.takeUpdate()).scrollbar.offset == bottom - 4)

        // Typing returns to the bottom.
        _ = await terminal.type(KeyEvent(key: .a, text: "a"), optionAsAlt: .none)
        #expect(try #require(state.takeUpdate()).scrollbar.offset == bottom)
    }
}
