import Foundation
import GhosttyVT
import Testing
@testable import GhosttyTerminal

@MainActor
struct RenderSmokeTests {
    /// Writes a sample screen to $GHOST_SWIFTLY_SHOTS when set, for looking at.
    @Test func rendersASampleScreen() async throws {
        let terminal = try Terminal(grid: Grid(columns: 60, rows: 12))
        var text = "plain \u{1b}[1mbold\u{1b}[0m \u{1b}[3mitalic\u{1b}[0m \u{1b}[4munder\u{1b}[0m \u{1b}[9mstrike\u{1b}[0m\r\n"
        text += "\u{1b}[31mred\u{1b}[32mgreen\u{1b}[34mblue\u{1b}[0m \u{1b}[38;2;255;128;0mtruecolor\u{1b}[0m \u{1b}[7minverse\u{1b}[0m\r\n"
        text += "日本語 wide 🚀 emoji 水\r\n"
        text += "╭──────╮ ┏━━┓ ║═╬═║ ▀▄█░▒▓ ⣿⠿⡇ \u{E0B0}\u{E0B2}\u{E0B4} \u{F418} \u{F023}\r\n"
        text += "│ box  │ ┃  ┃\r\n╰──────╯ ┗━━┛\r\n"
        text += "\u{1b}[4:3mcurly\u{1b}[0m \u{1b}[21mdouble\u{1b}[0m \u{1b}[4:4mdotted\u{1b}[0m \u{1b}[4:5mdashed\u{1b}[0m != -> => ===\r\n"
        text += "$ "
        await terminal.feed(Array(text.utf8))
        let image = try await OffscreenRender.image(terminal)
        #expect(image.width > 0)
        if let directory = ProcessInfo.processInfo.environment["GHOST_SWIFTLY_SHOTS"] {
            OffscreenRender.write(image, to: "\(directory)/sample.png")
        }
    }
}
