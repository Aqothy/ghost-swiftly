import Foundation
import Testing
@testable import GhosttyVT

struct EffectTests {
    @Test func programStatusArrivesAsATypedEvent() async throws {
        let events = try await events { terminal in
            // "Apply?" base64-encoded, the example in ghostty terminal.h.
            await terminal.feed(Array("\u{1b}]7501;state=blocked:kind=permission:app=terraform:msg=QXBwbHk/\u{1b}\\".utf8))
            await terminal.feed(Array("\u{1b}]7501;state=working:progress=40:app=codex\u{07}".utf8))
            await terminal.feed(Array("\u{1b}]7501;state=clear\u{07}".utf8))
        }
        #expect(events == [
            .programStatus(ProgramStatus(state: .blocked(.permission, progress: nil), app: "terraform", message: "Apply?")),
            .programStatus(ProgramStatus(state: .working(progress: 40), app: "codex")),
            .programStatus(ProgramStatus(state: .clear)),
        ])
    }

    @Test func titleClipboardAndBellArriveInOrder() async throws {
        let events = try await events { terminal in
            // "hi" base64-encoded.
            await terminal.feed(Array("\u{1b}]2;first\u{07}\u{1b}]52;c;aGk=\u{07}\u{07}".utf8))
        }
        let write = ClipboardWrite(location: .standard, contents: [.init(mimeType: "text/plain", data: Data("hi".utf8))])
        #expect(events == [.titleChanged("first"), .clipboardWrite(write), .bell])
    }

    /// Nobody performs a clipboard write or shows a title for a terminal no
    /// view is listening to, so it keeps none of them.
    @Test func eventsWithoutAListenerAreDropped() async throws {
        let terminal = try Terminal(grid: GridSize(columns: 80, rows: 24))
        await terminal.feed(Array("\u{1b}]2;unheard\u{07}\u{1b}]52;c;aGk=\u{07}".utf8))
        let events = await terminal.events()
        await terminal.feed(Array("\u{1b}]2;heard\u{07}".utf8))
        var iterator = events.makeAsyncIterator()
        #expect(await iterator.next() == .titleChanged("heard"))
    }

    /// A new view replaces the old one as the listener, and the old one's
    /// stream ends rather than both waiting on one stream.
    @Test func aNewListenerEndsThePreviousStream() async throws {
        let terminal = try Terminal(grid: GridSize(columns: 80, rows: 24))
        let first = await terminal.events()
        let second = await terminal.events()
        await terminal.feed(Array("\u{1b}]2;title\u{07}".utf8))
        var firstEvents: [TerminalEvent] = []
        for await event in first { firstEvents.append(event) }
        #expect(firstEvents.isEmpty)
        var iterator = second.makeAsyncIterator()
        #expect(await iterator.next() == .titleChanged("title"))
    }
}
