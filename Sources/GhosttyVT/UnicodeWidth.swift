import GhosttyVt

extension Unicode.Scalar {
    /// Columns the terminal gives this scalar on its own: 0, 1 or 2.
    package var terminalWidth: Int {
        Int(ghostty_unicode_codepoint_width(value))
    }
}
