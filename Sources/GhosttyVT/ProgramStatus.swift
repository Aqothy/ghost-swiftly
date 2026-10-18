import GhosttyVt

/// One program status report (OSC 7501,
/// https://www.superlogical.com/rex/docs/build/program-status).
///
/// A report replaces its record completely; see `GhosttyTerminalProgramStatusFn`
/// in ghostty `terminal.h` for how records combine.
public struct ProgramStatus: Sendable, Hashable {
    public enum State: Sendable, Hashable {
        /// Waiting for the user's next instruction.
        case idle
        /// Running on its own. `progress` is 0...100, or nil when indeterminate.
        case working(progress: Int?)
        /// Finished; the result is ready to look at.
        case done
        /// Can't continue until the user does something.
        case blocked(BlockedKind, progress: Int?)
        /// Failed and stopped.
        case error
        /// Remove the record with this id and every record beneath it; an
        /// empty id removes every record.
        case clear
    }

    public enum BlockedKind: Sendable, Hashable {
        case unspecified
        case permission
        case question
        case auth
    }

    public var state: State
    /// Which record the report is about; empty for the program itself. A "/"
    /// makes a child record.
    public var id: String
    /// A stable machine name such as "codex"; empty when not sent.
    public var app: String
    /// A short label for people; empty when not sent.
    public var title: String
    /// One line for people, already decoded. Untrusted program text.
    public var message: String

    public init(state: State, id: String = "", app: String = "", title: String = "", message: String = "") {
        self.state = state
        self.id = id
        self.app = app
        self.title = title
        self.message = message
    }

    init(_ report: GhosttyTerminalProgramStatus) {
        let progress = report.progress < 0 ? nil : Int(report.progress)
        switch report.state {
        case GHOSTTY_PROGRAM_STATUS_STATE_IDLE: state = .idle
        case GHOSTTY_PROGRAM_STATUS_STATE_WORKING: state = .working(progress: progress)
        case GHOSTTY_PROGRAM_STATUS_STATE_DONE: state = .done
        case GHOSTTY_PROGRAM_STATUS_STATE_BLOCKED:
            let kind: BlockedKind = switch report.kind {
            case GHOSTTY_PROGRAM_STATUS_KIND_PERMISSION: .permission
            case GHOSTTY_PROGRAM_STATUS_KIND_QUESTION: .question
            case GHOSTTY_PROGRAM_STATUS_KIND_AUTH: .auth
            default: .unspecified
            }
            state = .blocked(kind, progress: progress)
        case GHOSTTY_PROGRAM_STATUS_STATE_ERROR: state = .error
        default: state = .clear
        }
        id = String(ghostty: report.id)
        app = String(ghostty: report.app)
        title = String(ghostty: report.title)
        message = String(ghostty: report.message)
    }
}
