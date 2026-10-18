/// Something the program running in a terminal asked for, delivered in
/// stream order from ``Terminal/events``.
public enum TerminalEvent: Sendable, Equatable {
    /// OSC 0 / OSC 2.
    case titleChanged(String)
    /// OSC 7 / OSC 9 / OSC 1337 CurrentDir, as the raw value the shell sent
    /// (typically a `file://` URI for OSC 7).
    case pwdChanged(String)
    /// BEL.
    case bell
    /// OSC 7501.
    case programStatus(ProgramStatus)
    /// OSC 52 / OSC 1337 / OSC 5522 clipboard write.
    case clipboardWrite(ClipboardWrite)
}
