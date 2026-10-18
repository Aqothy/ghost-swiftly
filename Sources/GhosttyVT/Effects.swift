import GhosttyVt

/// Receives a terminal's effect callbacks and turns them into
/// ``TerminalEvent``s.
///
/// libghostty-vt invokes effects synchronously inside
/// `ghostty_terminal_vt_write` (ghostty `terminal.h`, "Effects"), which only
/// runs on the owning ``Terminal``'s executor, so this is only touched there.
///
/// Only effects that need no reply are installed. In particular there is no
/// `write_pty`: a view never answers the program (queries are the host's job),
/// which also drops OSC 5522 clipboard acknowledgements.
final class Effects: @unchecked Sendable {
    let continuation: AsyncStream<TerminalEvent>.Continuation
    /// Called with `held` when synchronized output (mode 2026) begins or ends.
    var renderHold: ((OpaquePointer, Bool) -> Void)?

    init(continuation: AsyncStream<TerminalEvent>.Continuation) {
        self.continuation = continuation
    }

    /// Installs every effect on `terminal`. A snapshot restore returns a new
    /// terminal handle, so this runs once per handle.
    func install(on terminal: OpaquePointer) {
        let userdata = Unmanaged.passUnretained(self).toOpaque()
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_USERDATA, userdata)
        set(terminal, GHOSTTY_TERMINAL_OPT_TITLE_CHANGED, titleChanged)
        set(terminal, GHOSTTY_TERMINAL_OPT_PWD_CHANGED, pwdChanged)
        set(terminal, GHOSTTY_TERMINAL_OPT_BELL, bell)
        set(terminal, GHOSTTY_TERMINAL_OPT_PROGRAM_STATUS, programStatus)
        set(terminal, GHOSTTY_TERMINAL_OPT_CLIPBOARD_WRITE, clipboardWrite)
        set(terminal, GHOSTTY_TERMINAL_OPT_RENDER_HOLD, renderHoldChanged)
    }

    private func set<Callback>(_ terminal: OpaquePointer, _ option: GhosttyTerminalOption, _ callback: Callback) {
        ghostty_terminal_set(terminal, option, unsafeBitCast(callback, to: UnsafeRawPointer.self))
    }

    static func from(_ userdata: UnsafeMutableRawPointer?) -> Effects {
        // USERDATA is set before any callback in install(on:).
        Unmanaged<Effects>.fromOpaque(userdata!).takeUnretainedValue()
    }
}

private func string(_ terminal: OpaquePointer?, _ data: GhosttyTerminalData) -> String {
    var value = GhosttyString()
    guard ghostty_terminal_get(terminal, data, &value) == GHOSTTY_SUCCESS else { return "" }
    return String(ghostty: value)
}

private let titleChanged: GhosttyTerminalTitleChangedFn = { terminal, userdata in
    Effects.from(userdata).continuation.yield(.titleChanged(string(terminal, GHOSTTY_TERMINAL_DATA_TITLE)))
}

private let pwdChanged: GhosttyTerminalPwdChangedFn = { terminal, userdata in
    Effects.from(userdata).continuation.yield(.pwdChanged(string(terminal, GHOSTTY_TERMINAL_DATA_PWD)))
}

private let bell: GhosttyTerminalBellFn = { _, userdata in
    Effects.from(userdata).continuation.yield(.bell)
}

private let programStatus: GhosttyTerminalProgramStatusFn = { _, userdata, report in
    // A sized struct: every field read here has been present since the
    // struct was introduced, so only a shorter struct is rejected.
    guard let report, report.pointee.size >= MemoryLayout<GhosttyTerminalProgramStatus>.size else { return }
    Effects.from(userdata).continuation.yield(.programStatus(ProgramStatus(report.pointee)))
}

private let clipboardWrite: GhosttyTerminalClipboardWriteFn = { _, userdata, write in
    guard let write else { return }
    Effects.from(userdata).continuation.yield(.clipboardWrite(ClipboardWrite(write.pointee)))
    // The reply must happen during the callback (ghostty terminal.h,
    // GhosttyClipboardWrite). Whether to perform the write is the view's
    // policy; the reply only reaches the program through write_pty, which a
    // view never installs.
    var reply = GhosttyClipboardWriteReply()
    reply.size = MemoryLayout<GhosttyClipboardWriteReply>.size
    reply.result = GHOSTTY_CLIPBOARD_WRITE_RESULT_SUCCESS
    write.pointee.reply(write, &reply)
}

private let renderHoldChanged: GhosttyTerminalRenderHoldFn = { terminal, userdata, held in
    guard let terminal else { return }
    Effects.from(userdata).renderHold?(terminal, held)
}
