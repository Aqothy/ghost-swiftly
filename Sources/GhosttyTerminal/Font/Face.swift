// Ported from ghostty src/font/face/coretext.zig @ 81598385d608dda4946093d6d6a234d204a2f225
// Ported from ghostty src/font/face.zig @ 81598385d608dda4946093d6d6a234d204a2f225
// Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors. MIT License.
//
// CoreText only: no HarfBuzz font, no FreeType.

import CoreGraphics
import CoreText
import Foundation

/// The desired size for loading a font.
struct DesiredSize: Equatable, Sendable {
    /// Size in points.
    var points: Double
    /// Device pixels per point (Ghostty's dpi / 72).
    var scale: Double

    var pixels: Double { points * scale }
}

/// A font variation axis setting, as in CSS `font-variation-settings`.
struct Variation: Equatable, Sendable {
    /// The four-character axis tag, such as "wght".
    var tag: String
    var value: Double

    var identifier: UInt32 {
        tag.utf8.reduce(0) { $0 << 8 | UInt32($1) }
    }
}

enum Presentation: Hashable, Sendable {
    /// U+FE0E.
    case text
    /// U+FE0F.
    case emoji
}

/// One loaded CoreText font at one size.
final class Face {
    let font: CTFont
    let size: DesiredSize
    /// The stroke width of a synthetic bold, for fonts without a bold.
    private(set) var syntheticBold: Double?
    /// Color glyph lookup, or nil when the font can't have color glyphs.
    private let color: ColorState?

    /// The matrix applied to a regular font to auto-italicize it.
    static let italicSkew = CGAffineTransform(a: 1, b: 0, c: 0.267949, d: 1, tx: 0, ty: 0) // ~tan(15°)

    /// Takes ownership of a CTFont already at its final size.
    init(font: CTFont, size: DesiredSize) {
        self.font = font
        self.size = size
        color = CTFontGetSymbolicTraits(font).contains(.traitColorGlyphs) ? ColorState(font) : nil
    }

    /// Loads a TTF/OTF from memory.
    convenience init?(data: Data, size: DesiredSize) {
        guard let descriptor = CTFontManagerCreateFontDescriptorFromData(data as CFData) else { return nil }
        let base = CTFontCreateWithFontDescriptor(descriptor, 12, nil)
        self.init(copying: base, size: size)
    }

    /// Copies a font (usually loaded at a default size during discovery) to
    /// the desired size.
    convenience init(copying base: CTFont, size: DesiredSize) {
        self.init(font: CTFontCreateCopyWithAttributes(base, size.pixels, nil, nil), size: size)
    }

    /// The same face skewed to look italic.
    func syntheticItalic() -> Face {
        var skew = Self.italicSkew
        return Face(font: CTFontCreateCopyWithAttributes(font, 0, &skew, nil), size: size)
    }

    /// The same face drawn with a stroke to look bold.
    func makeSyntheticBold() -> Face {
        let face = Face(font: CTFontCreateCopyWithAttributes(font, 0, nil, nil), size: size)
        // A 1pt stroke looks right at 14pt and scales roughly linearly.
        face.syntheticBold = max(size.points / 14, 1)
        return face
    }

    /// The same font at another size (Ghostty's `setSize`, which starts from
    /// the CTFont and so drops a synthetic bold).
    func resized(_ size: DesiredSize) -> Face {
        Face(copying: font, size: size)
    }

    /// The same face with variation axes set.
    func withVariations(_ variations: [Variation]) -> Face {
        guard !variations.isEmpty else { return self }
        var descriptor = CTFontCopyFontDescriptor(font)
        for variation in variations {
            descriptor = CTFontDescriptorCreateCopyWithVariation(
                descriptor, variation.identifier as CFNumber, CGFloat(variation.value))
        }
        return Face(font: CTFontCreateCopyWithAttributes(font, 0, nil, descriptor), size: size)
    }

    var familyName: String { CTFontCopyFamilyName(font) as String }

    var hasColor: Bool { color != nil }

    func isColorGlyph(_ glyph: UInt32) -> Bool {
        color?.isColorGlyph(glyph) ?? false
    }

    /// The glyph for a codepoint, or nil when the face doesn't have it.
    func glyphIndex(_ codepoint: UInt32) -> UInt32? {
        Self.glyph(in: font, for: codepoint).map(UInt32.init)
    }

    static func glyph(in font: CTFont, for codepoint: UInt32) -> CGGlyph? {
        guard let scalar = Unicode.Scalar(codepoint) else { return nil }
        var units = Array(String(Character(scalar)).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: units.count)
        guard CTFontGetGlyphsForCharacters(font, &units, &glyphs, units.count) else { return nil }
        // A surrogate pair decodes to one glyph, in the first slot.
        return glyphs[0]
    }

    // MARK: Rendering

    func renderGlyph(_ glyphIndex: UInt32, into atlas: Atlas, options: Glyph.RenderOptions) throws(Atlas.Full) -> Glyph {
        var glyphs = [CGGlyph(truncatingIfNeeded: glyphIndex)]
        // Origin bottom-left, +Y up.
        var rect = CTFontGetBoundingRectsForGlyphs(font, .horizontal, &glyphs, nil, 1)

        let isColor = isColorGlyph(glyphIndex)
        // Probably a bitmap (sbix), which synthetic bold and smoothing don't affect.
        let sbix = isColor && color?.sbix == true

        // A synthetic bold stroke adds half the line width on every edge.
        if !sbix, let lineWidth = syntheticBold {
            rect.size.width += lineWidth
            rect.size.height += lineWidth
            rect.origin.x -= lineWidth / 2
            rect.origin.y -= lineWidth / 2
        }

        // Smaller than a quarter pixel: no outlines worth rendering.
        if rect.width < 0.25 || rect.height < 0.25 { return .empty }

        let metrics = options.gridMetrics
        let cellWidth = Double(metrics.cellWidth)
        let cellHeight = Double(metrics.cellHeight)
        let cellBaseline = Double(metrics.cellBaseline)

        // Constraints work on cell-relative positions, not baseline-relative.
        let constrained = options.constraint.constrain(
            Glyph.Size(width: rect.width, height: rect.height, x: rect.origin.x, y: rect.origin.y + cellBaseline),
            metrics: metrics,
            constraintWidth: options.constraintWidth)
        var x = constrained.x
        var y = constrained.y
        var width = constrained.width
        var height = constrained.height

        // Center glyphs in a cell wider than the face, unless stretched
        // (already positioned for the cell width).
        if options.constraint.size != .stretch {
            let dx = (cellWidth - metrics.faceWidth) / 2
            x += dx
            // For a cell narrower than the advance, keep only the fractional
            // adjustment, for consistent subpixel positioning.
            if dx < 0 { x -= dx.rounded(.towardZero) }
        }

        // Bitmaps render as whole pixels, so quantize their position and size.
        if sbix {
            width = cellWidth - (cellWidth - width - x).rounded() - x.rounded()
            height = cellHeight - (cellHeight - height - y).rounded() - y.rounded()
            x = x.rounded()
            y = y.rounded()
        }

        // Assume smoothing ("thicken") adds at most 1px on any edge.
        let canvasPadding: Int32 = options.thicken && !sbix ? 1 : 0

        // Whole-pixel bearings; the fraction goes into the rasterized position.
        let pxX = Int32(x.rounded(.down)) - canvasPadding
        let pxY = Int32(y.rounded(.down)) - canvasPadding
        let fracX = x - x.rounded(.down)
        let fracY = y - y.rounded(.down)
        let pxWidth = Int(UInt32((width + fracX).rounded(.up))) + 2 * Int(canvasPadding)
        let pxHeight = Int(UInt32((height + fracY).rounded(.up))) + 2 * Int(canvasPadding)

        let depth = isColor ? 4 : 1
        precondition(atlas.format.depth == depth, "glyph rendered into the wrong atlas")
        let space: CGColorSpace
        let bitmapInfo: UInt32
        if isColor {
            space = CGColorSpace(name: CGColorSpace.displayP3)!
            bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        } else {
            space = CGColorSpace(name: CGColorSpace.linearGray)!
            bitmapInfo = CGImageAlphaInfo.alphaOnly.rawValue
        }

        var buffer = [UInt8](repeating: 0, count: pxWidth * pxHeight * depth)
        buffer.withUnsafeMutableBytes { pixels in
            guard let context = CGContext(
                data: pixels.baseAddress, width: pxWidth, height: pxHeight, bitsPerComponent: 8,
                bytesPerRow: pxWidth * depth, space: space, bitmapInfo: bitmapInfo)
            else { return }

            // An initial fill so no pixel is uninitialized.
            if isColor {
                context.setFillColor(red: 0, green: 0, blue: 0, alpha: 0)
            } else {
                context.setFillColor(gray: 0, alpha: 0)
            }
            context.fill(CGRect(x: 0, y: 0, width: pxWidth, height: pxHeight))

            // "Thicken" is CoreText font smoothing, which brings text closer to
            // system applications.
            context.setAllowsFontSmoothing(true)
            context.setShouldSmoothFonts(options.thicken)
            // Subpixel positioning for our alignment, without quantization,
            // since positions are managed here.
            context.setAllowsFontSubpixelPositioning(true)
            context.setShouldSubpixelPositionFonts(true)
            context.setAllowsFontSubpixelQuantization(false)
            context.setShouldSubpixelQuantizeFonts(false)
            context.setAllowsAntialiasing(true)
            context.setShouldAntialias(true)

            if isColor {
                context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
                context.setStrokeColor(red: 1, green: 1, blue: 1, alpha: 1)
            } else {
                let strength = CGFloat(options.thickenStrength) / 255
                context.setFillColor(gray: strength, alpha: 1)
                context.setStrokeColor(gray: strength, alpha: 1)
            }

            if let lineWidth = syntheticBold {
                context.setTextDrawingMode(.fillStroke)
                context.setLineWidth(lineWidth)
            }

            // Put the glyph's bottom-left at the subpixel position, then
            // stretch it to the constrained size. Drawing at the negated
            // bearings puts its bottom-left at exactly (0, 0).
            context.translateBy(x: fracX + Double(canvasPadding), y: fracY + Double(canvasPadding))
            context.scaleBy(x: width / rect.width, y: height / rect.height)
            var position = CGPoint(x: -rect.origin.x, y: -rect.origin.y)
            CTFontDrawGlyphs(font, &glyphs, &position, 1, context)
        }

        let region = try atlas.reserve(width: UInt32(pxWidth), height: UInt32(pxHeight))
        buffer.withUnsafeBytes { atlas.set(region, $0) }

        return Glyph(
            width: UInt32(pxWidth),
            height: UInt32(pxHeight),
            // From the left of the cell to the left of the glyph.
            offsetX: pxX,
            // From the bottom of the cell to the top of the glyph.
            offsetY: pxY + Int32(pxHeight),
            atlasX: region.x,
            atlasY: region.y)
    }

    // MARK: Metrics

    func metrics() -> Metrics.FaceMetrics {
        let head = table("head").flatMap(OpenType.Head.init) ?? table("bhed").flatMap(OpenType.Head.init)
        let post = table("post").flatMap(OpenType.Post.init)
        let os2 = table("OS/2").flatMap(OpenType.OS2.init)
        let hhea = table("hhea").flatMap(OpenType.Hhea.init)

        let unitsPerEm = Double(head?.unitsPerEm ?? UInt16(CTFontGetUnitsPerEm(font)))
        let pxPerEm = Double(CTFontGetSize(font))
        let pxPerUnit = pxPerEm / unitsPerEm

        let ascent: Double
        let descent: Double
        let lineGap: Double
        if let hhea {
            let hheaMetrics = (Double(hhea.ascender) * pxPerUnit, Double(hhea.descender) * pxPerUnit,
                               Double(hhea.lineGap) * pxPerUnit)
            if let os2 {
                let typo = (Double(os2.sTypoAscender) * pxPerUnit, Double(os2.sTypoDescender) * pxPerUnit,
                            Double(os2.sTypoLineGap) * pxPerUnit)
                // Trust the font when it says to use typo metrics; otherwise
                // prefer hhea, then typo, then win (FreeType's order, roughly).
                if os2.fsSelection.contains(.useTypoMetrics) {
                    (ascent, descent, lineGap) = typo
                } else if hhea.ascender != 0 || hhea.descender != 0 {
                    (ascent, descent, lineGap) = hheaMetrics
                } else if os2.sTypoAscender != 0 || os2.sTypoDescender != 0 {
                    (ascent, descent, lineGap) = typo
                } else {
                    // usWinDescent is positive-down, unlike the others.
                    (ascent, descent, lineGap) = (Double(os2.usWinAscent) * pxPerUnit,
                                                  -Double(os2.usWinDescent) * pxPerUnit, 0)
                }
            } else {
                (ascent, descent, lineGap) = hheaMetrics
            }
        } else {
            (ascent, descent, lineGap) = (CTFontGetAscent(font), -CTFontGetDescent(font), CTFontGetLeading(font))
        }

        // Degenerate 'post' tables have a zero thickness; a nonzero position
        // is still used.
        var underlinePosition: Double?
        var underlineThickness: Double?
        if let post {
            let broken = post.underlineThickness == 0
            underlinePosition = broken && post.underlinePosition == 0 ? nil : Double(post.underlinePosition) * pxPerUnit
            underlineThickness = broken ? nil : Double(post.underlineThickness) * pxPerUnit
        }

        var strikethroughPosition: Double?
        var strikethroughThickness: Double?
        if let os2 {
            let broken = os2.yStrikeoutSize == 0
            strikethroughPosition = broken && os2.yStrikeoutPosition == 0
                ? nil : Double(os2.yStrikeoutPosition) * pxPerUnit
            strikethroughThickness = broken ? nil : Double(os2.yStrikeoutSize) * pxPerUnit
        }

        let capHeight = os2?.sCapHeight.map { Double($0) * pxPerUnit } ?? CTFontGetCapHeight(font)
        let exHeight = os2?.sxHeight.map { Double($0) * pxPerUnit } ?? CTFontGetXHeight(font)

        // The cell is as wide as the widest printable ASCII glyph, and the
        // ASCII height is their overall bounding box.
        var characters = (UInt16(32)..<UInt16(127)).map { $0 }
        var asciiGlyphs = [CGGlyph](repeating: 0, count: characters.count)
        _ = CTFontGetGlyphsForCharacters(font, &characters, &asciiGlyphs, characters.count)
        var advances = [CGSize](repeating: .zero, count: asciiGlyphs.count)
        _ = CTFontGetAdvancesForGlyphs(font, .horizontal, &asciiGlyphs, &advances, asciiGlyphs.count)
        let cellWidth = advances.map(\.width).max() ?? 0
        let asciiHeight = CTFontGetBoundingRectsForGlyphs(font, .horizontal, &asciiGlyphs, nil, asciiGlyphs.count).height

        // "水" (U+6C34) for the ideograph width. An advance narrower than the
        // glyph is probably a nerd-font-patched CJK font with butchered
        // advances, and would make the font far too big when normalizing.
        var icWidth: Double?
        if let glyph = glyphIndex(0x6C34) {
            var glyphs = [CGGlyph(truncatingIfNeeded: glyph)]
            let advance = CTFontGetAdvancesForGlyphs(font, .horizontal, &glyphs, nil, 1)
            let bounds = CTFontGetBoundingRectsForGlyphs(font, .horizontal, &glyphs, nil, 1)
            icWidth = bounds.width > advance ? nil : advance
        }

        return Metrics.FaceMetrics(
            pxPerEm: pxPerEm,
            cellWidth: cellWidth,
            ascent: ascent,
            descent: descent,
            lineGap: lineGap,
            underlinePosition: underlinePosition,
            underlineThickness: underlineThickness,
            strikethroughPosition: strikethroughPosition,
            strikethroughThickness: strikethroughThickness,
            capHeight: capHeight,
            exHeight: exHeight,
            asciiHeight: asciiHeight,
            icWidth: icWidth)
    }

    private func table(_ tag: String) -> Data? {
        Self.table(tag, in: font)
    }

    static func table(_ tag: String, in font: CTFont) -> Data? {
        let identifier = tag.utf8.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        return CTFontCopyTable(font, identifier, []) as Data?
    }
}

/// Which glyphs of a font that may have color glyphs actually do.
private struct ColorState {
    /// The mere presence of an sbix table marks every glyph as color.
    let sbix: Bool
    let svg: OpenType.SVG?

    init(_ font: CTFont) {
        sbix = (Face.table("sbix", in: font)?.count ?? 0) > 0
        svg = Face.table("SVG ", in: font).flatMap(OpenType.SVG.init)
    }

    func isColorGlyph(_ glyph: UInt32) -> Bool {
        // Real fonts only have 16-bit glyph IDs; larger ones are special values.
        guard let glyph = UInt16(exactly: glyph) else { return false }
        if sbix { return true }
        return svg?.hasGlyph(glyph) ?? false
    }
}
