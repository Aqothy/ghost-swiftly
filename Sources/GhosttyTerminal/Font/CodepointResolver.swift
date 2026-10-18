// Ported from ghostty src/font/CodepointResolver.zig @ 81598385d608dda4946093d6d6a234d204a2f225
// Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors. MIT License.
//
// No codepoint map overrides (config plumbing) and every style enabled.

import Foundation

/// Maps a codepoint to the font that should draw it, searching for fallback
/// fonts when the collection has none.
final class CodepointResolver {
    let collection: Collection
    var sprite: SpriteFace?

    init(collection: Collection) {
        self.collection = collection
    }

    /// The font for a codepoint, in this order:
    ///
    /// 1. The sprite font, for the glyphs drawn in code.
    /// 2. A loaded font with the exact style and presentation, in priority order.
    /// 3. For a styled request, the same search with the regular style, since
    ///    a regular glyph from a loaded font beats a styled one from a new
    ///    font with different metrics.
    /// 4. For the regular style, a fallback font found by discovery.
    /// 5. A regular font with any presentation.
    ///
    /// Not cached; ``FontGrid`` caches.
    func index(for codepoint: UInt32, style: FontStyle, presentation: Presentation?) -> FontIndex? {
        if sprite != nil, SpriteFace.hasCodepoint(codepoint) { return .sprite }

        let mode: PresentationMode = if let presentation {
            .explicit(presentation)
        } else {
            .default(Unicode.Scalar(codepoint)?.properties.isEmojiPresentation == true ? .emoji : .text)
        }

        if let index = collection.index(for: codepoint, style: style, mode) { return index }

        if style != .regular, let index = index(for: codepoint, style: .regular, presentation: presentation) {
            return index
        }

        if style == .regular {
            let descriptor = FontDescriptor(
                codepoint: codepoint, size: collection.size.points, bold: style.isBold, italic: style.isItalic)
            for candidate in Discovery.discoverFallback(collection, descriptor) {
                // Discovery can't search by presentation, so check it here.
                let entry = Collection.Entry(.deferred(candidate), fallback: true)
                guard entry.hasCodepoint(codepoint, mode) else { continue }
                return collection.addDeferred(candidate, style: style, fallback: true, sizeAdjustment: .icWidth)
            }
        }

        if style == .regular, case .any = mode { return nil }
        return collection.index(for: codepoint, style: .regular, .any)
    }

    /// Which atlas a glyph belongs in.
    func presentation(_ index: FontIndex, glyph: UInt32) -> Presentation {
        guard let face = collection.face(index) else { return .text }
        return face.isColorGlyph(glyph) ? .emoji : .text
    }

    /// Renders by glyph index (not codepoint; shaping picks the glyphs).
    func renderGlyph(_ index: FontIndex, glyph: UInt32, into atlas: Atlas, options: Glyph.RenderOptions) throws(Atlas.Full) -> Glyph {
        if case .sprite = index {
            return try sprite?.renderGlyph(glyph, into: atlas, cellWidth: options.cellWidth) ?? .empty
        }
        guard let face = collection.face(index) else { return .empty }
        return try face.renderGlyph(glyph, into: atlas, options: options)
    }
}
