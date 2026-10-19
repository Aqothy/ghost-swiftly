import Foundation
import GhosttyVT
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
#endif

extension ClipboardWrite {
    /// Writes the system clipboard, as Ghostty does for OSC 52. Only the
    /// standard clipboard: the system has no selection or primary one.
    @MainActor
    func perform() {
        guard location == .standard else { return }
        let representations = contents.compactMap { content in
            Self.type(content.mimeType).map { ($0.identifier, content.data) }
        }
        #if os(macOS)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard !representations.isEmpty else { return }
        let item = NSPasteboardItem()
        for (identifier, data) in representations {
            item.setData(data, forType: NSPasteboard.PasteboardType(identifier))
        }
        pasteboard.writeObjects([item])
        #else
        UIPasteboard.general.setItems(representations.isEmpty ? [] : [Dictionary(uniqueKeysWithValues: representations)])
        #endif
    }

    /// Plain text is UTF-8 (OSC 52 carries no charset), which the system's
    /// string readers ask for by its own type.
    private static func type(_ mimeType: String) -> UTType? {
        mimeType.hasPrefix("text/plain") ? .utf8PlainText : UTType(mimeType: mimeType)
    }
}
