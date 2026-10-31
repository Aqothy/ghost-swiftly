import Foundation
import GhosttyVt
import Testing
@testable import GhosttyVT

struct SnapshotRestoreTests {
    /// An encoder that stores Kitty images snapshots their pixels as records
    /// of their own, which can arrive between history pages (ghostty
    /// snapshot.h, ghostty_snapshot_decoder_next). Restoring history passes
    /// over them instead of failing.
    @Test func restoresHistoryPastKittyImages() async throws {
        var handle: OpaquePointer?
        try #require(ghostty_terminal_new(nil, &handle, 10, 5) == GHOSTTY_SUCCESS)
        let source = try #require(handle)
        defer { ghostty_terminal_free(source) }
        var images: UInt64 = 1_000_000
        try #require(ghostty_terminal_set(source, GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_STORAGE_LIMIT, &images) == GHOSTTY_SUCCESS)
        var scrollback = 1_000_000
        try #require(ghostty_terminal_set(source, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, &scrollback) == GHOSTTY_SUCCESS)

        // History, a 1x1 image (a=T transmits and places it), more history.
        var input = (0..<3000).map { "line \($0)\r\n" }.joined()
        input += "\u{1b}_Ga=T,f=24,s=1,v=1;/wAA\u{1b}\\"
        input += (3000..<6000).map { "line \($0)\r\n" }.joined()
        let bytes = Array(input.utf8)
        ghostty_terminal_vt_write(source, bytes, bytes.count)

        var pointer: UnsafeMutablePointer<UInt8>?
        var length = 0
        try #require(ghostty_snapshot_encode_alloc(source, nil, &pointer, &length) == GHOSTTY_SUCCESS)
        let encoded = try #require(pointer)
        let snapshot = Data(bytes: encoded, count: length)
        ghostty_free(nil, encoded, length)

        let terminal = try Terminal(grid: GridSize(columns: 10, rows: 5))
        try await terminal.restore(snapshot: snapshot)
        var restoredRows = 0
        while true {
            switch try await terminal.restoreHistoryPage() {
            case .restored(let rows): restoredRows += rows
            case .dropped: Issue.record("a history page was dropped")
            case .finished:
                #expect(restoredRows > 0)
                #expect(try await terminal.text().contains("line 5999"))
                return
            }
        }
    }
}
