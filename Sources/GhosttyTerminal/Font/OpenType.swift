// Ported from ghostty src/font/opentype/head.zig @ 81598385d608dda4946093d6d6a234d204a2f225
// Ported from ghostty src/font/opentype/hhea.zig @ 81598385d608dda4946093d6d6a234d204a2f225
// Ported from ghostty src/font/opentype/os2.zig @ 81598385d608dda4946093d6d6a234d204a2f225
// Ported from ghostty src/font/opentype/post.zig @ 81598385d608dda4946093d6d6a234d204a2f225
// Ported from ghostty src/font/opentype/svg.zig @ 81598385d608dda4946093d6d6a234d204a2f225
// Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors. MIT License.
//
// Only the fields the renderer reads, at their OpenType spec offsets. A
// table shorter than its struct fails to parse, as in Ghostty.

import Foundation

/// Big-endian reads from an OpenType table.
private struct TableReader {
    let data: Data

    func uint16(_ offset: Int) -> UInt16 {
        UInt16(data[data.startIndex + offset]) << 8 | UInt16(data[data.startIndex + offset + 1])
    }

    func int16(_ offset: Int) -> Int16 { Int16(bitPattern: uint16(offset)) }

    func uint32(_ offset: Int) -> UInt32 {
        UInt32(uint16(offset)) << 16 | UInt32(uint16(offset + 2))
    }
}

enum OpenType {
    /// 'head' (or the byte-identical 'bhed' of bitmap-only fonts).
    struct Head {
        static let size = 54
        var unitsPerEm: UInt16
        var macStyle: UInt16

        init?(_ data: Data) {
            guard data.count >= Self.size else { return nil }
            let r = TableReader(data: data)
            unitsPerEm = r.uint16(18)
            macStyle = r.uint16(44)
        }
    }

    struct Hhea {
        static let size = 36
        var ascender: Int16
        var descender: Int16
        var lineGap: Int16

        init?(_ data: Data) {
            guard data.count >= Self.size else { return nil }
            let r = TableReader(data: data)
            ascender = r.int16(4)
            descender = r.int16(6)
            lineGap = r.int16(8)
        }
    }

    struct Post {
        static let size = 32
        var underlinePosition: Int16
        var underlineThickness: Int16

        init?(_ data: Data) {
            guard data.count >= Self.size else { return nil }
            let r = TableReader(data: data)
            underlinePosition = r.int16(8)
            underlineThickness = r.int16(10)
        }
    }

    struct OS2 {
        struct FSSelection: OptionSet {
            let rawValue: UInt16
            static let italic = FSSelection(rawValue: 1 << 0)
            static let bold = FSSelection(rawValue: 1 << 5)
            static let useTypoMetrics = FSSelection(rawValue: 1 << 7)
        }

        var yStrikeoutSize: Int16
        var yStrikeoutPosition: Int16
        var fsSelection: FSSelection
        var sTypoAscender: Int16
        var sTypoDescender: Int16
        var sTypoLineGap: Int16
        var usWinAscent: UInt16
        var usWinDescent: UInt16
        /// Version 2 and later.
        var sxHeight: Int16?
        var sCapHeight: Int16?

        init?(_ data: Data) {
            guard data.count >= 2 else { return nil }
            let r = TableReader(data: data)
            // Struct sizes per version: v0 78, v1 86, v2-v4 96, v5 100.
            let version = r.uint16(0)
            let size: Int
            switch version {
            case 0: size = 78
            case 1: size = 86
            case 2, 3, 4: size = 96
            case 5: size = 100
            default: return nil
            }
            guard data.count >= size else { return nil }
            yStrikeoutSize = r.int16(26)
            yStrikeoutPosition = r.int16(28)
            fsSelection = FSSelection(rawValue: r.uint16(62))
            sTypoAscender = r.int16(68)
            sTypoDescender = r.int16(70)
            sTypoLineGap = r.int16(72)
            usWinAscent = r.uint16(74)
            usWinDescent = r.uint16(76)
            if version >= 2 {
                sxHeight = r.int16(86)
                sCapHeight = r.int16(88)
            }
        }
    }

    /// 'SVG ': which glyphs have SVG (color) documents.
    struct SVG {
        private let startGlyphID: UInt16
        private let endGlyphID: UInt16
        /// (start, end) glyph ranges of the document records, sorted.
        private let ranges: [(UInt16, UInt16)]

        init?(_ data: Data) {
            guard data.count >= 6 else { return nil }
            let r = TableReader(data: data)
            guard r.uint16(0) == 0 else { return nil }
            let offset = Int(r.uint32(2))
            guard offset + 2 <= data.count else { return nil }
            let count = Int(r.uint16(offset))
            let recordsStart = offset + 2
            guard count > 0, recordsStart + count * 12 <= data.count else { return nil }
            ranges = (0..<count).map { index in
                let record = recordsStart + index * 12
                return (r.uint16(record), r.uint16(record + 2))
            }
            startGlyphID = ranges[0].0
            endGlyphID = ranges[count - 1].1
        }

        func hasGlyph(_ glyph: UInt16) -> Bool {
            if glyph < startGlyphID || glyph > endGlyphID { return false }
            if glyph == startGlyphID || glyph == endGlyphID { return true }
            var low = 0
            var high = ranges.count - 1
            while low <= high {
                let mid = (low + high) / 2
                let (start, end) = ranges[mid]
                if glyph < start {
                    high = mid - 1
                } else if glyph > end {
                    low = mid + 1
                } else {
                    return true
                }
            }
            return false
        }
    }
}
