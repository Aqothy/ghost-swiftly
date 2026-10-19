import Testing
@testable import GhosttyVT

/// Expected bytes are the VT sequences from xterm's ctlseqs.
struct EncodingTests {
    @Test func arrowKeysFollowTheCursorKeyMode() async throws {
        let terminal = try Terminal(grid: GridSize(columns: 80, rows: 24))
        let up = KeyEvent(key: .arrowUp)
        #expect(await terminal.encode(up) == Array("\u{1b}[A".utf8))
        await terminal.feed(Array("\u{1b}[?1h".utf8))
        #expect(await terminal.encode(up) == Array("\u{1b}OA".utf8))
    }

    @Test func textAndOptionAsAlt() async throws {
        let terminal = try Terminal(grid: GridSize(columns: 80, rows: 24))
        #expect(await terminal.encode(KeyEvent(key: .a, text: "a", unshiftedCodepoint: "a")) == Array("a".utf8))
        let optionA = KeyEvent(key: .a, modifiers: .alt, text: "å", unshiftedCodepoint: "a")
        #expect(await terminal.encode(optionA, optionAsAlt: .none) == Array("å".utf8))
        #expect(await terminal.encode(optionA, optionAsAlt: .both) == Array("\u{1b}a".utf8))
    }

    @Test func pasteIsFramedAndRefusedWhenUnsafe() async throws {
        let terminal = try Terminal(grid: GridSize(columns: 80, rows: 24))
        #expect(await terminal.encodePaste("ls") == Array("ls".utf8))
        #expect(await terminal.encodePaste("rm -rf x\n") == nil)
        #expect(await terminal.encodePaste("a\nb", allowUnsafe: true) == Array("a\rb".utf8))

        await terminal.feed(Array("\u{1b}[?2004h".utf8))
        #expect(await terminal.encodePaste("a\nb") == Array("\u{1b}[200~a\nb\u{1b}[201~".utf8))
        #expect(await terminal.encodePaste("x\u{1b}[201~y") == nil)
    }

    @Test func focusIsReportedOnlyWhenRequested() async throws {
        let terminal = try Terminal(grid: GridSize(columns: 80, rows: 24))
        #expect(await terminal.encodeFocus(true) == [])
        await terminal.feed(Array("\u{1b}[?1004h".utf8))
        #expect(await terminal.encodeFocus(true) == Array("\u{1b}[I".utf8))
        #expect(await terminal.encodeFocus(false) == Array("\u{1b}[O".utf8))
    }

    @Test func mouseReportsFollowTheTrackingMode() async throws {
        let terminal = try Terminal(grid: GridSize(columns: 80, rows: 24))
        let geometry = MouseGeometry(screenWidth: 800, screenHeight: 480, cellWidth: 10, cellHeight: 20)
        // Cell (3, 2) zero-based is column 4, row 3 in SGR.
        let press = MouseEvent(action: .press, button: .left, x: 35, y: 45)
        #expect(await terminal.encode(press, geometry: geometry, anyButtonPressed: true) == [])
        await terminal.feed(Array("\u{1b}[?1000h\u{1b}[?1006h".utf8))
        #expect(await terminal.encode(press, geometry: geometry, anyButtonPressed: true) == Array("\u{1b}[<0;4;3M".utf8))
    }
}
