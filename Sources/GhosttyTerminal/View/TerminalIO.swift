import GhosttyVT

/// What a view sends to whoever runs the program. The view never answers
/// the program's queries; only user input comes out.
@MainActor
public protocol TerminalIO: AnyObject {
    /// Input for the program, in order: keys, pastes, mouse and focus
    /// reports, already encoded for the program's modes.
    func send(_ bytes: [UInt8])

    /// The grid that fits the view at its font size changed. With
    /// ``TerminalConfiguration/GridPolicy/fitView`` the view has already
    /// resized its terminal; resize the PTY to match. With
    /// ``TerminalConfiguration/GridPolicy/host``, tell the host, which sizes
    /// the terminal to the grid of the view the user is using (see
    /// ``activate()``); the view draws the host's grid. While the view's size
    /// animates (the iOS keyboard), the grid is reported once it settles.
    func requestResize(_ grid: GridSize)

    /// The user focused, clicked, tapped or typed into the view: with
    /// ``TerminalConfiguration/GridPolicy/host``, the host gives the terminal
    /// this view's grid. It comes before the typed input it precedes; the
    /// program's mouse and focus reports don't activate the view.
    func activate()

    /// What the program asked of its terminal while the view showed it, in
    /// order: title, working directory, bell and program status. The view
    /// writes the clipboard itself (Ghostty's default `clipboard-write =
    /// allow`).
    func handle(_ event: TerminalEvent)
}

public extension TerminalIO {
    func activate() {}
    func handle(_ event: TerminalEvent) {}
}
