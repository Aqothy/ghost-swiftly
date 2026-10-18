// Ported from ghostty src/font/Metrics.zig @ 81598385d608dda4946093d6d6a234d204a2f225
// Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors. MIT License.
//
// Leaves out the config modifiers (adjust-cell-height and friends).

import Foundation

/// The cell grid's pixel metrics, derived from the primary font face.
struct Metrics: Equatable, Sendable {
    /// Recommended cell width and height for a monospace grid using this font.
    var cellWidth: UInt32
    var cellHeight: UInt32
    /// Distance in pixels from the bottom of the cell to the text baseline.
    var cellBaseline: UInt32
    /// Distance in pixels from the top of the cell to the top of the underline.
    var underlinePosition: UInt32
    var underlineThickness: UInt32
    /// Distance in pixels from the top of the cell to the top of the strikethrough.
    var strikethroughPosition: UInt32
    var strikethroughThickness: UInt32
    /// Distance in pixels from the top of the cell to the top of the overline.
    /// Can be negative to adjust the position above the top of the cell.
    var overlinePosition: Int32
    var overlineThickness: UInt32
    var boxThickness: UInt32
    var cursorThickness: UInt32 = 1
    var cursorHeight: UInt32
    /// The constraint height for nerd fonts icons.
    var iconHeight: Double
    /// The constraint height for nerd fonts icons limited to a single cell width.
    var iconHeightSingle: Double
    /// The unrounded face width, used in scaling calculations.
    var faceWidth: Double
    /// The unrounded face height, used in scaling calculations.
    var faceHeight: Double
    /// The offset from the bottom of the cell to the bottom of the face's
    /// bounding box, based on the rounded cell height.
    var faceY: Double

    /// Metrics extracted from a font face, from its tables and glyph
    /// measurements. Positions are relative to the baseline, +Y up, in px.
    struct FaceMetrics: Sendable {
        /// Pixels per em, to compare metrics from faces of different sizes.
        var pxPerEm: Double
        /// The minimum cell width that can contain any glyph in the ASCII range.
        var cellWidth: Double
        var ascent: Double
        /// Typically negative.
        var descent: Double
        var lineGap: Double
        /// The TOP of the underline stroke.
        var underlinePosition: Double?
        var underlineThickness: Double?
        /// The TOP of the strikethrough stroke.
        var strikethroughPosition: Double?
        var strikethroughThickness: Double?
        var capHeight: Double?
        var exHeight: Double?
        /// The measured height of the bounding box of all printable ASCII.
        var asciiHeight: Double?
        /// The width of "水" (U+6C34), to normalize CJK fallback sizes.
        var icWidth: Double?

        var lineHeight: Double { ascent - descent + lineGap }

        /// Estimated as 75% of the ascent when the font doesn't say.
        var resolvedCapHeight: Double {
            if let capHeight, capHeight > 0 { return capHeight }
            return 0.75 * ascent
        }

        /// Estimated as 75% of the cap height when the font doesn't say.
        var resolvedExHeight: Double {
            if let exHeight, exHeight > 0 { return exHeight }
            return 0.75 * resolvedCapHeight
        }

        /// Estimated as 1.5 × cap height, from measurements across programming fonts.
        var resolvedAsciiHeight: Double {
            if let asciiHeight, asciiHeight > 0 { return asciiHeight }
            return 1.5 * resolvedCapHeight
        }

        var resolvedIcWidth: Double {
            if let icWidth, icWidth > 0 { return icWidth }
            return min(resolvedAsciiHeight, 2 * cellWidth)
        }

        /// Estimated as 15% of the ex height.
        var resolvedUnderlineThickness: Double {
            if let underlineThickness, underlineThickness > 0 { return underlineThickness }
            return 0.15 * resolvedExHeight
        }

        var resolvedStrikethroughThickness: Double {
            if let strikethroughThickness, strikethroughThickness > 0 { return strikethroughThickness }
            return resolvedUnderlineThickness
        }

        /// One underline thickness below the baseline when the font doesn't say.
        var resolvedUnderlinePosition: Double {
            underlinePosition ?? -resolvedUnderlineThickness
        }

        /// Centered at half the ex height when the font doesn't say.
        var resolvedStrikethroughPosition: Double {
            strikethroughPosition ?? (resolvedExHeight + resolvedStrikethroughThickness) * 0.5
        }
    }

    /// Calculates the grid metrics from unrounded face metrics.
    init(face: FaceMetrics) {
        let faceWidth = face.cellWidth
        let faceHeight = face.lineHeight

        // Round rather than ceil so the apparent spacing stays within 0.5px
        // of the font's design on both low and high DPI displays.
        let cellWidth = faceWidth.rounded()
        let cellHeight = faceHeight.rounded()

        // Half the line gap goes on each side so text never bumps the cell edge.
        let halfLineGap = face.lineGap / 2

        // Unlike the other positions, the baseline is relative to the
        // BOTTOM of the cell. Center the face in the rounded cell height.
        let faceBaseline = halfLineGap - face.descent
        let cellBaseline = (faceBaseline - (cellHeight - faceHeight) / 2).rounded()
        let faceY = cellBaseline - faceBaseline
        let topToBaseline = cellHeight - cellBaseline

        let capHeight = face.resolvedCapHeight
        let underlineThickness = max(1, face.resolvedUnderlineThickness.rounded(.up))
        let strikethroughThickness = max(1, face.resolvedStrikethroughThickness.rounded(.up))
        let underlinePosition = (topToBaseline - face.resolvedUnderlinePosition).rounded()
        let strikethroughPosition = (topToBaseline - face.resolvedStrikethroughPosition).rounded()

        // Same heuristic as the font_patcher script.
        let iconHeight = faceHeight
        let iconHeightSingle = (2 * capHeight + faceHeight) / 3

        self.cellWidth = Self.clampedInt(cellWidth)
        self.cellHeight = Self.clampedInt(cellHeight)
        self.cellBaseline = Self.clampedInt(cellBaseline)
        self.underlinePosition = Self.clampedInt(underlinePosition)
        self.underlineThickness = Self.clampedInt(underlineThickness)
        self.strikethroughPosition = Self.clampedInt(strikethroughPosition)
        self.strikethroughThickness = Self.clampedInt(strikethroughThickness)
        self.overlinePosition = 0
        self.overlineThickness = Self.clampedInt(underlineThickness)
        self.boxThickness = Self.clampedInt(underlineThickness)
        self.cursorHeight = Self.clampedInt(cellHeight)
        self.iconHeight = iconHeight
        self.iconHeightSingle = iconHeightSingle
        self.faceWidth = faceWidth
        self.faceHeight = faceHeight
        self.faceY = faceY
        clamp()
    }

    private static func clampedInt(_ value: Double) -> UInt32 {
        UInt32(max(0, min(value, Double(UInt32.max))))
    }

    /// Keeps every metric in its allowable range so nothing ends up with a
    /// zero thickness or size.
    private mutating func clamp() {
        cellWidth = max(cellWidth, 1)
        cellHeight = max(cellHeight, 1)
        underlineThickness = max(underlineThickness, 1)
        strikethroughThickness = max(strikethroughThickness, 1)
        overlineThickness = max(overlineThickness, 1)
        boxThickness = max(boxThickness, 1)
        cursorThickness = max(cursorThickness, 1)
        cursorHeight = max(cursorHeight, 1)
        iconHeight = max(iconHeight, 1)
        iconHeightSingle = max(iconHeightSingle, 1)
        faceHeight = max(faceHeight, 1)
        faceWidth = max(faceWidth, 1)
    }
}
