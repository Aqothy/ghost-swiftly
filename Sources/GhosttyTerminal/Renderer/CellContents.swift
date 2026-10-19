// Ported from ghostty src/renderer/cell.zig @ 81598385d608dda4946093d6d6a234d204a2f225
// Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors. MIT License.

import Foundation
import GhosttyVT

/// The GPU cells of the whole grid, kept between frames so only dirty rows
/// are rebuilt.
struct CellContents {
    enum CursorPlacement {
        /// Block cursors draw before the text.
        case beforeText
        /// The others draw after it.
        case afterText
    }

    private(set) var columns = 0
    private(set) var rows = 0
    /// Indexed `row * columns + column`.
    private(set) var bgCells: [CellBg] = []
    /// Foreground cells by row, with one list before the rows and one after
    /// for the cursor (`fgRows[y + 1]` is row y).
    private(set) var fgRows: [[CellText]] = []

    /// Resizes, clearing everything.
    mutating func resize(columns: Int, rows: Int) {
        self.columns = columns
        self.rows = rows
        bgCells = [CellBg](repeating: .zero, count: columns * rows)
        fgRows = [[CellText]](repeating: [], count: rows + 2)
        // Glyphs plus underline, overline and strikethrough fit three per
        // column; combining marks and multi-glyph substitutions can exceed
        // it, so this is a reservation, not a limit.
        for index in fgRows.indices.dropFirst().dropLast() { fgRows[index].reserveCapacity(columns * 3) }
    }

    mutating func reset() {
        for index in bgCells.indices { bgCells[index] = .zero }
        for index in fgRows.indices { fgRows[index].removeAll(keepingCapacity: true) }
    }

    mutating func setCursor(_ cell: CellText?, _ placement: CursorPlacement) {
        guard rows > 0 else { return }
        fgRows[0].removeAll(keepingCapacity: true)
        fgRows[rows + 1].removeAll(keepingCapacity: true)
        guard let cell else { return }
        switch placement {
        case .beforeText: fgRows[0].append(cell)
        case .afterText: fgRows[rows + 1].append(cell)
        }
    }

    mutating func setBackground(row: Int, column: Int, _ color: CellBg) {
        bgCells[row * columns + column] = color
    }

    mutating func add(_ cell: CellText) {
        fgRows[Int(cell.gridPos.y) + 1].append(cell)
    }

    /// Clears one row's backgrounds and foreground.
    mutating func clear(row: Int) {
        for column in 0..<columns { bgCells[row * columns + column] = .zero }
        fgRows[row + 1].removeAll(keepingCapacity: true)
    }
}

enum CellClass {
    /// Covers the whole cell (U+2588 FULL BLOCK); its foreground is used as
    /// the background so padding extension works (ghostty#2099).
    static func isCovering(_ cp: UInt32) -> Bool {
        cp == 0x2588
    }

    /// Private use, or in Arrows, Dingbats, Emoticons, Miscellaneous
    /// Symbols, Enclosed Alphanumerics (and Supplement), Miscellaneous
    /// Symbols and Pictographs, or Transport and Map Symbols (Ghostty's
    /// `is_symbol`, src/build/uucode_config.zig).
    static func isSymbol(_ cp: UInt32) -> Bool {
        switch cp {
        case 0x2190...0x21FF, 0x2700...0x27BF, 0x1F600...0x1F64F, 0x2600...0x26FF, 0x2460...0x24FF,
             0x1F100...0x1F1FF, 0x1F300...0x1F5FF, 0x1F680...0x1F6FF,
             // The private use areas, which Unicode never changes.
             0xE000...0xF8FF, 0xF0000...0xFFFFD, 0x100000...0x10FFFD:
            true
        default:
            false
        }
    }

    /// The cells a glyph may span: its grid width, or two for a symbol with
    /// a space after it (unless the previous cell is a non-graphic symbol,
    /// so runs of icons stay aligned).
    static func constraintWidth(_ cells: [RenderCell], _ x: Int) -> UInt8 {
        let cell = cells[x]
        if cell.gridWidth > 1 { return UInt8(cell.gridWidth) }
        let cp = cell.codepoint
        if !isSymbol(cp) { return 1 }
        if x == cells.count - 1 { return 1 }
        if x > 0 {
            let previous = cells[x - 1].codepoint
            if isSymbol(previous), !isGraphicsElement(previous) { return 1 }
        }
        let next = cells[x + 1].codepoint
        return next == 0 || isSpace(next) ? 2 : 1
    }

    /// Graphics elements keep their colors under minimum contrast.
    static func noMinContrast(_ cp: UInt32) -> Bool {
        isGraphicsElement(cp)
    }

    /// Spaces that let a symbol widen; others are kept to force fixed width.
    private static func isSpace(_ cp: UInt32) -> Bool {
        cp == 0x20 || cp == 0x2002
    }

    /// Box drawing, block elements, legacy computing and Powerline glyphs.
    private static func isGraphicsElement(_ cp: UInt32) -> Bool {
        switch cp {
        case 0x2500...0x257F, 0x2580...0x259F, 0x1FB00...0x1FBFF, 0x1CC00...0x1CEBF, 0xE0B0...0xE0D7: true
        default: false
        }
    }
}
