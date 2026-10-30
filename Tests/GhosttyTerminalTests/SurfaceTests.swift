import Foundation
import GhosttyVT
import Testing
@testable import GhosttyTerminal

@MainActor
final class RecordingIO: TerminalIO {
    var sent: [[UInt8]] = []
    var resizes: [GridSize] = []
    var activations = 0
    var events: [TerminalEvent] = []

    func send(_ bytes: [UInt8]) { sent.append(bytes) }
    func requestResize(_ grid: GridSize) { resizes.append(grid) }
    func activate() { activations += 1 }
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

    /// A host's view reports the grid that fits it whenever that changes,
    /// whoever's grid it draws, and once its size settles rather than at
    /// every step of an animation such as the iOS keyboard's.
    @Test func hostsViewReportsTheGridThatFitsIt() async throws {
        let terminal = try Terminal(grid: GridSize(columns: 80, rows: 24))
        let io = RecordingIO()
        var configuration = TerminalConfiguration()
        configuration.gridPolicy = .host
        let surface = TerminalSurface(terminal: terminal, io: io, configuration: configuration)
        defer { surface.close() }
        surface.layout(size: CGSize(width: 800, height: 500), scale: 2)
        let first = try #require(surface.preferredGrid)
        #expect(io.resizes == [first])

        // Another view's grid.
        let other = GridSize(columns: 50, rows: 20)
        try await terminal.resize(to: other)
        try await waitUntil { surface.screen?.grid == other }
        surface.layout(size: CGSize(width: 1000, height: 600), scale: 2)
        let grown = try #require(surface.preferredGrid)
        #expect(grown != first)
        #expect(io.resizes == [first, grown])

        surface.setSizeSettling(true)
        surface.layout(size: CGSize(width: 1000, height: 500), scale: 2)
        surface.layout(size: CGSize(width: 1000, height: 400), scale: 2)
        #expect(io.resizes == [first, grown])
        surface.setSizeSettling(false)
        let settled = try #require(surface.preferredGrid)
        #expect(io.resizes == [first, grown, settled])
    }

    /// Focusing, pressing, tapping or typing into the view activates it;
    /// staying focused doesn't again, and the program's focus reports don't.
    @Test func usingTheViewActivatesIt() async throws {
        let terminal = try Terminal(grid: GridSize(columns: 80, rows: 24))
        let io = RecordingIO()
        var configuration = TerminalConfiguration()
        configuration.gridPolicy = .host
        let surface = TerminalSurface(terminal: terminal, io: io, configuration: configuration)
        defer { surface.close() }
        surface.layout(size: CGSize(width: 800, height: 500), scale: 2)

        surface.setFocused(true)
        surface.setFocused(true)
        #expect(io.activations == 1)
        surface.send(.mouseButton(.press, .left, [], CGPoint(x: 10, y: 10), local: nil))
        surface.send(.mouseButton(.release, .left, [], CGPoint(x: 10, y: 10), local: nil))
        try await waitUntil { io.activations == 2 }
        surface.tapped()
        #expect(io.activations == 3)

        surface.send(.text("a"))
        try await waitUntil { io.sent.last == Array("a".utf8) }
        #expect(io.activations == 4)

        // The program asks for focus reports; losing focus sends one.
        await terminal.feed(Array("\u{1b}[?1004h".utf8))
        surface.setFocused(false)
        try await waitUntil { io.sent.last == Array("\u{1b}[O".utf8) }
        #expect(io.activations == 4)
    }
}
