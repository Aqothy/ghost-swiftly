// Ported from ghostty src/font/shaper/coretext.zig @ 81598385d608dda4946093d6d6a234d204a2f225
// Ported from ghostty src/font/shaper/run.zig @ 81598385d608dda4946093d6d6a234d204a2f225
// Ported from ghostty src/font/shaper/Cache.zig @ 81598385d608dda4946093d6d6a234d204a2f225
// Ported from ghostty src/font/shape.zig @ 81598385d608dda4946093d6d6a234d204a2f225
// Ported from ghostty src/datastruct/cache_table.zig @ 81598385d608dda4946093d6d6a234d204a2f225
// Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors. MIT License.
//
// No font-feature config: only the default `liga`. CoreFoundation objects
// are released in place rather than on Ghostty's release thread.

import CoreText
import Foundation
import GhosttyVT

/// One glyph to draw for a shaped run.
struct ShapedCell: Equatable {
    /// The cell, relative to the run's offset.
    var x: UInt16
    var xOffset: Int16 = 0
    var yOffset: Int16 = 0
    var glyphIndex: UInt32
}

/// A run of cells in one row with one font and style, ready to shape.
struct TextRun {
    /// Identifies the run's content independent of its position in the row,
    /// so identical runs anywhere share a cache entry.
    var hash: Int
    /// The run's first cell in the row.
    var offset: Int
    /// How many cells the run spans.
    var cells: Int
    var fontIndex: FontIndex
}

/// Shapes runs with CoreText.
final class Shaper {
    private struct Codepoint {
        var codepoint: UInt32
        var cluster: UInt32
    }

    /// The run being built: UTF-16 for CoreText, plus each UTF-16 unit's
    /// codepoint and cluster (a surrogate pair's second unit is a 0 entry).
    private var codepoints: [Codepoint] = []
    private var unichars: [UInt16] = []
    private var cells: [ShapedCell] = []
    /// Attribute dictionaries per font index, built once.
    private var fonts: [FontIndex: CFDictionary] = [:]
    private let grid: FontGrid
    /// `liga` on, as Ghostty's default features.
    private let features: CTFontDescriptor
    /// Forces every line left to right: setting a writing direction on the
    /// string still lets CoreText reorder trailing spaces of RTL text
    /// (ghostty#1737, ghostty#1442).
    private let typesetterOptions = [kCTTypesetterOptionForcedEmbeddingLevel: 0] as CFDictionary

    init(grid: FontGrid) {
        self.grid = grid
        let settings: [[CFString: Any]] = [[
            kCTFontOpenTypeFeatureTag: "liga",
            kCTFontOpenTypeFeatureValue: 1,
        ]]
        features = CTFontDescriptorCreateWithAttributes(
            [kCTFontFeatureSettingsAttribute: settings] as CFDictionary)
    }

    // MARK: Run building

    func beginRun() {
        codepoints.removeAll(keepingCapacity: true)
        unichars.removeAll(keepingCapacity: true)
    }

    func addCodepoint(_ codepoint: UInt32, cluster: UInt32) {
        guard let scalar = Unicode.Scalar(codepoint) else { return }
        unichars.append(contentsOf: scalar.utf16)
        codepoints.append(Codepoint(codepoint: codepoint, cluster: cluster))
        // CTRunGetStringIndices counts UTF-16 units, so a pair needs a
        // placeholder to keep indexes aligned.
        if scalar.utf16.count == 2 { codepoints.append(Codepoint(codepoint: 0, cluster: cluster)) }
    }

    // MARK: Shaping

    /// Shapes the run built since ``beginRun()``.
    func shape(_ run: TextRun) -> [ShapedCell] {
        // The sprite font isn't shaped: its glyph indexes are codepoints.
        if case .sprite = run.fontIndex {
            return codepoints.compactMap { entry in
                // Skip the surrogate placeholders.
                entry.codepoint == 0 ? nil : ShapedCell(x: UInt16(entry.cluster), glyphIndex: entry.codepoint)
            }
        }
        guard let attributes = attributes(run.fontIndex) else { return [] }

        let string = String(utf16CodeUnits: unichars, count: unichars.count)
        let attributed = CFAttributedStringCreate(nil, string as CFString, attributes)!
        let typesetter = CTTypesetterCreateWithAttributedStringAndOptions(attributed, typesetterOptions)!
        let line = CTTypesetterCreateLine(typesetter, CFRange(location: 0, length: 0))

        // The x offset (sum of advances) and furthest cluster so far.
        var runX = 0.0
        var runCluster: UInt32 = 0
        // Where the current cell starts.
        var cellX = 0.0
        var cellCluster: UInt32 = 0
        cells.removeAll(keepingCapacity: true)
        // CoreText may still produce non-monotonic runs despite the forced
        // embedding level; those need sorting.
        var nonLTR = false

        // CoreText can split our run into several, always in sequence.
        let glyphRuns = (CTLineGetGlyphRuns(line) as? [CTRun]) ?? []
        for glyphRun in glyphRuns {
            let status = CTRunGetStatus(glyphRun)
            if status.contains(.nonMonotonic) || status.contains(.rightToLeft) { nonLTR = true }
            let count = CTRunGetGlyphCount(glyphRun)
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var advances = [CGSize](repeating: .zero, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            var indices = [CFIndex](repeating: 0, count: count)
            let all = CFRange(location: 0, length: 0)
            CTRunGetGlyphs(glyphRun, all, &glyphs)
            CTRunGetAdvances(glyphRun, all, &advances)
            CTRunGetPositions(glyphRun, all, &positions)
            CTRunGetStringIndices(glyphRun, all, &indices)

            for i in 0..<count {
                let index = indices[i]
                // The cluster is the cell's x. A new cluster usually starts a
                // new cell, unless its first codepoint isn't in the stream
                // (it probably formed a ligature with an earlier cluster) or
                // the cluster was already passed (marks from a later cluster
                // drawn first, as in Chakma and Bengali).
                let cluster = codepoints[index].cluster
                if cellCluster != cluster {
                    let afterCurrentOrNext = cluster <= runCluster
                    var firstInCluster = true
                    var previous = index
                    while previous > 0 {
                        previous -= 1
                        if codepoints[previous].codepoint == 0 { continue }
                        firstInCluster = codepoints[previous].cluster != cluster
                        break
                    }
                    if firstInCluster, !afterCurrentOrNext {
                        cellCluster = cluster
                        cellX = runX
                    }
                }

                cells.append(ShapedCell(
                    x: UInt16(cellCluster),
                    xOffset: Int16((positions[i].x - cellX).rounded()),
                    yOffset: Int16(positions[i].y.rounded()),
                    glyphIndex: UInt32(glyphs[i])))

                // Advances apply to the next cell.
                runX += advances[i].width
                runCluster = max(runCluster, cluster)
            }
        }

        // Exceedingly rare: complex scripts this doesn't really support.
        if nonLTR { cells.sort { $0.x < $1.x } }
        return cells
    }

    private func attributes(_ index: FontIndex) -> CFDictionary? {
        if let cached = fonts[index] { return cached }
        guard let face = grid.resolver.collection.face(index) else { return nil }
        let font = CTFontCreateCopyWithAttributes(face.font, 0, nil, features)
        let attributes = [kCTFontAttributeName: font] as CFDictionary
        fonts[index] = attributes
        return attributes
    }
}

/// Shaping results by run hash: a fixed table of 256 buckets of 8, each
/// bucket least recently used first (Ghostty's CacheTable).
struct ShaperCache {
    private static let bucketCount = 256
    private static let bucketSize = 8
    private var buckets = [[(hash: Int, cells: [ShapedCell])]](repeating: [], count: bucketCount)

    mutating func get(_ run: TextRun) -> [ShapedCell]? {
        let bucket = Self.bucket(run.hash)
        guard let position = buckets[bucket].lastIndex(where: { $0.hash == run.hash }) else { return nil }
        // Most recently used goes last.
        let entry = buckets[bucket].remove(at: position)
        buckets[bucket].append(entry)
        return entry.cells
    }

    mutating func put(_ run: TextRun, _ cells: [ShapedCell]) {
        let bucket = Self.bucket(run.hash)
        if buckets[bucket].count == Self.bucketSize { buckets[bucket].removeFirst() }
        buckets[bucket].append((run.hash, cells))
    }

    private static func bucket(_ hash: Int) -> Int {
        Int(UInt(bitPattern: hash) % UInt(bucketCount))
    }
}

/// Kitty graphics' Unicode placeholder, drawn blank.
private let kittyPlaceholder: UInt32 = 0x10EEEE

/// Splits a row into runs to shape: one font, one style (backgrounds may
/// differ), no selection or cursor boundary inside.
struct RunIterator {
    let grid: FontGrid
    let shaper: Shaper
    let cells: [RenderCell]
    /// The selected columns of the row.
    let selection: ClosedRange<Int>?
    /// Runs break around the cursor so it can show what's under it.
    let cursorX: Int?
    /// Past the last non-empty cell: the empty right side isn't shaped.
    private let end: Int
    private var i = 0

    init(grid: FontGrid, shaper: Shaper, cells: [RenderCell], selection: ClosedRange<Int>?, cursorX: Int?) {
        self.grid = grid
        self.shaper = shaper
        self.cells = cells
        self.selection = selection
        self.cursorX = cursorX
        end = (cells.lastIndex { !$0.isEmpty } ?? -1) + 1
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    mutating func next() -> TextRun? {
        // Invisible cells draw no glyphs.
        while i < end, cells[i].hasStyling, cells[i].style.invisible { i += 1 }
        if i >= end { return nil }

        shaper.beginRun()
        var hasher = Hasher()
        var currentFont = FontIndex.primary
        let style = cells[i].hasStyling ? cells[i].style : .default

        // `break` leaves j at the cell that ends the run; `continue` and the
        // end of the body move past the cell.
        var j = i
        cellLoop: while j < end {
            // Relative clusters make the cache position-independent.
            let cluster = UInt32(j - i)
            let cell = cells[j]

            if let selection, j > i {
                if selection.lowerBound > 0, j == selection.lowerBound { break }
                if selection.upperBound > 0, j == selection.upperBound + 1 { break }
            }

            if cell.wide == .spacerHead || cell.wide == .spacerTail {
                j += 1
                continue cellLoop
            }

            if j > i {
                let previous = cells[j - 1]
                // Commonly bad ligatures: fl, fi, st.
                if case .codepoint(let previousCodepoint) = previous.content, case .codepoint(let codepoint) = cell.content {
                    if previousCodepoint == 0x66, codepoint == 0x6C || codepoint == 0x69 { break }
                    if previousCodepoint == 0x73, codepoint == 0x74 { break }
                }
                // Any style change but the background splits the run, so a
                // ">=" glyph isn't drawn in one color for two styles.
                if previous.styleID != cell.styleID {
                    var a = style
                    var b = cell.hasStyling ? cell.style : .default
                    a.background = .none
                    b.background = .none
                    if a != b { break }
                }
            }

            let fontStyle = FontStyle(bold: style.bold, italic: style.italic)

            // VS15/VS16 must directly follow the codepoint.
            var presentation: Presentation?
            if let first = cell.graphemeTail.first {
                if first == 0xFE0E { presentation = .text }
                if first == 0xFE0F { presentation = .emoji }
            }

            // Break before, at and after the cursor, but never inside a
            // grapheme cell, so hovering an emoji keeps it whole.
            if !cell.hasGrapheme, let cursorX {
                if i == cursorX, j == i + 1 { break }
                if i < cursorX, j == cursorX { break }
            }

            // A font for the whole grapheme, or a replacement character.
            var fallback: UInt32?
            let index: FontIndex
            if let found = indexForCell(cell, fontStyle, presentation) {
                index = found
            } else if let replacement = grid.index(for: 0xFFFD, style: fontStyle, presentation: presentation) {
                index = replacement
                fallback = 0xFFFD
            } else if let space = grid.index(for: 0x20, style: fontStyle, presentation: presentation) {
                index = space
                fallback = 0x20
            } else {
                // Unreachable: every grid can draw a space.
                j += 1
                continue cellLoop
            }

            if j == i { currentFont = index }
            if index != currentFont { break }

            if let fallback {
                add(fallback, cluster, &hasher)
            } else if cell.codepoint == kittyPlaceholder {
                add(0x20, cluster, &hasher)
            } else {
                add(cell.codepoint == 0 ? 0x20 : cell.codepoint, cluster, &hasher)
                for codepoint in cell.graphemeTail where codepoint != 0xFE0E && codepoint != 0xFE0F {
                    add(codepoint, cluster, &hasher)
                }
            }
            j += 1
        }

        // The length and font are part of the identity too.
        hasher.combine(j - i)
        hasher.combine(currentFont)
        defer { i = j }
        return TextRun(hash: hasher.finalize(), offset: i, cells: j - i, fontIndex: currentFont)
    }

    private func add(_ codepoint: UInt32, _ cluster: UInt32, _ hasher: inout Hasher) {
        hasher.combine(codepoint)
        hasher.combine(cluster)
        shaper.addCodepoint(codepoint, cluster: cluster)
    }

    /// A font with every codepoint of the cell's grapheme: the base
    /// codepoint's font, else the first font of an extra codepoint that has
    /// them all. The extra codepoints needn't support the base presentation,
    /// since emoji fonts often lack ZWJ pieces like gender signs.
    private func indexForCell(_ cell: RenderCell, _ style: FontStyle, _ presentation: Presentation?) -> FontIndex? {
        if cell.isEmpty || cell.codepoint == 0 || cell.codepoint == kittyPlaceholder {
            return grid.index(for: 0x20, style: style, presentation: presentation)
        }
        guard let primary = grid.index(for: cell.codepoint, style: style, presentation: presentation) else {
            return nil
        }
        guard cell.hasGrapheme else { return primary }

        let ignored: Set<UInt32> = [0xFE0E, 0xFE0F, 0x200D]
        var candidates = [primary]
        for codepoint in cell.graphemeTail where !ignored.contains(codepoint) {
            guard let index = grid.index(for: codepoint, style: style, presentation: nil) else { return nil }
            candidates.append(index)
        }
        return candidates.first { index in
            grid.hasCodepoint(index, cell.codepoint, presentation)
                && cell.graphemeTail.allSatisfy { ignored.contains($0) || grid.hasCodepoint(index, $0, nil) }
        }
    }
}
