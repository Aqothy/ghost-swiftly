import GhosttyVt

/// A failed libghostty-vt call.
public enum GhosttyError: Error, Equatable, Sendable {
    case outOfMemory
    case invalidValue
    case outOfSpace
    case noValue
    case ioError
    case limitExceeded
    case rejected
    case unknown(Int32)

    init(_ result: GhosttyResult) {
        switch result {
        case GHOSTTY_OUT_OF_MEMORY: self = .outOfMemory
        case GHOSTTY_INVALID_VALUE: self = .invalidValue
        case GHOSTTY_OUT_OF_SPACE: self = .outOfSpace
        case GHOSTTY_NO_VALUE: self = .noValue
        case GHOSTTY_IO_ERROR: self = .ioError
        case GHOSTTY_LIMIT_EXCEEDED: self = .limitExceeded
        case GHOSTTY_REJECTED: self = .rejected
        default: self = .unknown(result.rawValue)
        }
    }
}

func check(_ result: GhosttyResult) throws(GhosttyError) {
    guard result == GHOSTTY_SUCCESS else { throw GhosttyError(result) }
}
