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
}
