@testable import GhosttyVT

/// Every event a terminal produced during `body`. Releasing the terminal ends
/// its event stream, so a missing event fails an assertion instead of hanging.
func events(
    grid: GridSize = GridSize(columns: 80, rows: 24),
    _ body: (Terminal) async throws -> Void
) async throws -> [TerminalEvent] {
    let stream: AsyncStream<TerminalEvent>
    do {
        let terminal = try Terminal(grid: grid)
        stream = terminal.events
        try await body(terminal)
    }
    var events: [TerminalEvent] = []
    for await event in stream {
        events.append(event)
    }
    return events
}
