import GhosttyVT

/// What a view sends to whoever runs the program. The view never answers
/// the program's queries; only user input comes out.
@MainActor
public protocol TerminalIO: AnyObject {
    /// Input for the program, in order: keys, pastes, mouse and focus
    /// reports, already encoded for the program's modes.
    func send(_ bytes: [UInt8])

    /// The grid the view wants. With ``TerminalConfiguration/GridPolicy/fitView``
    /// the view has already resized its terminal; resize the PTY to match.
    /// With ``TerminalConfiguration/GridPolicy/host``, ask the host; the view
    /// keeps drawing the host's grid until it resizes the terminal. A resize
    /// requested before typing always arrives before the typed bytes.
    func requestResize(_ grid: GridSize)

    /// The grid that fits the view at its font size changed. A host attaches
    /// at this grid; it is not a request to resize.
    func preferredGridChanged(_ grid: GridSize)

    /// What the program asked of its terminal while the view showed it, in
    /// order: title, working directory, bell and program status. The view
    /// writes the clipboard itself (Ghostty's default `clipboard-write =
    /// allow`).
    func handle(_ event: TerminalEvent)
}

public extension TerminalIO {
    func handle(_ event: TerminalEvent) {}
}
