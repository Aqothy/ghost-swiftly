// Ported from ghostty src/font/sprite/Face.zig @ 81598385d608dda4946093d6d6a234d204a2f225
// Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors. MIT License.
//
// Box drawing, block elements, braille, the geometric Powerline glyphs and
// the decoration/cursor sprites. Ghostty also draws branch symbols,
// geometric shapes and the Symbols for Legacy Computing; those come from
// fonts here.

import Foundation

/// The built-in "font" of glyphs drawn in code. Glyph indexes are codepoints.
struct SpriteFace {
    let metrics: Metrics

    static func hasCodepoint(_ cp: UInt32) -> Bool {
        switch cp {
        case 0x2500...0x257F, 0x2580...0x259F, 0x2800...0x28FF: true
        default: Draw.powerlineCodepoints.contains(cp) || Sprite(rawValue: cp) != nil
        }
    }

    func renderGlyph(_ cp: UInt32, into atlas: Atlas, cellWidth: UInt8?) throws(Atlas.Full) -> Glyph {
        guard Self.hasCodepoint(cp) else { return .empty }
        let width = Int(metrics.cellWidth) * max(1, Int(cellWidth ?? 1))
        // Full-height cursors use the cursor height.
        let height: Int = switch Sprite(rawValue: cp) {
        case .cursorRect, .cursorHollowRect, .cursorBar: Int(metrics.cursorHeight)
        default: Int(metrics.cellHeight)
        }
        let paddingX = width / 4
        let paddingY = height / 4
        let canvas = Canvas(width: width, height: height, paddingX: paddingX, paddingY: paddingY)

        if let sprite = Sprite(rawValue: cp) {
            sprite.draw(canvas, width: width, height: height, metrics: metrics)
        } else {
            switch cp {
            case 0x2500...0x257F: Draw.boxDrawing(cp, canvas, metrics)
            case 0x2580...0x259F: Draw.blockElement(cp, canvas, metrics)
            case 0x2800...0x28FF: Draw.braille(cp, canvas, width: width, height: height)
            default: Draw.powerline(cp, canvas, width: width, height: height, metrics)
            }
        }

        let region = try canvas.writeAtlas(atlas)
        // The x offset is from the cell's left edge: the trimmed left edge
        // minus the padding. The y offset likewise, re-centering glyphs
        // drawn taller or shorter than the cell (cursors).
        let offsetX = Int32(canvas.clipLeft) - Int32(paddingX)
        let offsetY = Int32(Int(region.height) + canvas.clipBottom) - Int32(paddingY)
            + Int32((Int(metrics.cellHeight) - height) / 2)
        return Glyph(width: region.width, height: region.height, offsetX: offsetX, offsetY: offsetY,
                     atlasX: region.x, atlasY: region.y)
    }
}
