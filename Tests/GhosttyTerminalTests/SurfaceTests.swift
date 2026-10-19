import Foundation
import GhosttyVT
import Testing
@testable import GhosttyTerminal

@MainActor
final class RecordingIO: TerminalIO {
    var sent: [[UInt8]] = []
    var resizes: [GridSize] = []
    var preferredGrids: [GridSize] = []
    var events: [TerminalEvent] = []

    func send(_ bytes: [UInt8]) { sent.append(bytes) }
    func requestResize(_ grid: GridSize) { resizes.append(grid) }
    func preferredGridChanged(_ grid: GridSize) { preferredGrids.append(grid) }
    func handle(_ event: TerminalEvent) { events.append(event) }
}

/// Waits for a condition the main actor's tasks make true.
@MainActor
func waitUntil(_ condition: () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !(await condition()) {
        guard ContinuousClock.now < deadline else {
            Issue.record("timed out")
            return
        }
        try await Task.sleep(for: .milliseconds(5))
    }
}

@MainActor
struct SurfaceTests {
    /// The program's title reaches the I/O while a view shows the terminal.
    @Test func viewHandsTheProgramsEventsToItsIO() async throws {
        let terminal = try Terminal(grid: GridSize(columns: 80, rows: 24))
        let io = RecordingIO()
        let surface = TerminalSurface(terminal: terminal, io: io, configuration: .init())
        defer { surface.close() }
        // The view starts listening asynchronously; keep telling until it hears.
        try await waitUntil {
            await terminal.feed(Array("\u{1b}]2;working\u{07}".utf8))
            return io.events.contains(.titleChanged("working"))
        }
    }
}
