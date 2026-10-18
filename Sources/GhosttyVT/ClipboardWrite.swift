import Foundation
import GhosttyVt

/// A program's request to write a clipboard.
public struct ClipboardWrite: Sendable, Hashable {
    public enum Location: Sendable, Hashable {
        case standard
        case selection
        case primary
    }

    /// One representation of the value.
    public struct Content: Sendable, Hashable {
        public var mimeType: String
        public var data: Data

        public init(mimeType: String, data: Data) {
            self.mimeType = mimeType
            self.data = data
        }
    }

    public var location: Location
    /// Representations of one value, to be committed together. Empty means
    /// clear the clipboard.
    public var contents: [Content]

    /// The first text representation, which is all OSC 52 carries.
    public var text: String? {
        contents.first { $0.mimeType.hasPrefix("text/") }.map { String(decoding: $0.data, as: UTF8.self) }
    }

    public init(location: Location, contents: [Content]) {
        self.location = location
        self.contents = contents
    }

    init(_ write: GhosttyClipboardWrite) {
        location = switch write.location {
        case GHOSTTY_CLIPBOARD_LOCATION_SELECTION: .selection
        case GHOSTTY_CLIPBOARD_LOCATION_PRIMARY: .primary
        default: .standard
        }
        contents = (0..<write.contents_len).map { index in
            let content = write.contents[index]
            let data = content.data.ptr.map { Data(bytes: $0, count: content.data.len) } ?? Data()
            return Content(mimeType: String(ghostty: content.mime), data: data)
        }
    }
}
