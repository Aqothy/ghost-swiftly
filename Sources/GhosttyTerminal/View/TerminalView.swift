import GhosttyVT
import SwiftUI

/// A terminal for SwiftUI: draws a ``Terminal`` and sends the user's input
/// to a ``TerminalIO``.
public struct TerminalView {
    let terminal: Terminal
    let io: TerminalIO?
    let configuration: TerminalConfiguration

    public init(terminal: Terminal, io: TerminalIO?, configuration: TerminalConfiguration = .init()) {
        self.terminal = terminal
        self.io = io
        self.configuration = configuration
    }
}

#if os(macOS)
extension TerminalView: NSViewRepresentable {
    public func makeNSView(context: Context) -> TerminalNSView {
        TerminalNSView(terminal: terminal, io: io, configuration: configuration)
    }

    public func updateNSView(_ view: TerminalNSView, context: Context) {
        view.io = io
        view.configuration = configuration
    }
}
#endif
