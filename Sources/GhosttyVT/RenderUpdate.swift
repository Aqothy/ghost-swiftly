/// An RGB color.
package struct RGB: Hashable, Sendable {
    package var r: UInt8
    package var g: UInt8
    package var b: UInt8

    package init(r: UInt8, g: UInt8, b: UInt8) {
        self.r = r
        self.g = g
        self.b = b
    }
}

/// A style color as SGR set it.
package enum StyleColor: Hashable, Sendable {
    case none
    case palette(UInt8)
    case rgb(RGB)
}

/// A cell's SGR attributes.
package struct CellStyle: Hashable, Sendable {
    package enum Underline: Hashable, Sendable {
        case none
        case single
        case double
        case curly
        case dotted
        case dashed
    }

    package var foreground: StyleColor = .none
    package var background: StyleColor = .none
    package var underlineColor: StyleColor = .none
    package var bold = false
    package var italic = false
    package var faint = false
    package var blink = false
    package var inverse = false
    package var invisible = false
    package var strikethrough = false
    package var overline = false
    package var underline: Underline = .none

    package static let `default` = CellStyle()
}

/// One cell of a row, decoded from the render state.
package struct RenderCell: Hashable, Sendable {
    package enum Wide: Hashable, Sendable {
        case narrow
        /// The first cell of a wide character.
        case wide
        /// The cell after a wide character; draws nothing.
        case spacerTail
        /// The last cell of a soft-wrapped row whose wide character moved to
        /// the next row.
        case spacerHead
    }

    package enum Content: Hashable, Sendable {
        /// A codepoint, zero when empty.
        case codepoint(UInt32)
        /// A codepoint with more codepoints in the same grapheme cluster.
        case grapheme(UInt32, [UInt32])
        /// No text, a palette background.
        case backgroundPalette(UInt8)
        /// No text, an RGB background.
        case backgroundRGB(RGB)
    }

    package var content: Content
    package var wide: Wide
    /// Zero for the default style. Equal ids in one row mean equal styles.
    package var styleID: UInt16
    /// The cell's style; ``CellStyle/default`` when `styleID` is zero.
    package var style: CellStyle

    package var codepoint: UInt32 {
        switch content {
        case .codepoint(let cp), .grapheme(let cp, _): cp
        case .backgroundPalette, .backgroundRGB: 0
        }
    }

    /// The extra codepoints of a grapheme cluster, after the first.
    package var graphemeTail: [UInt32] {
        if case .grapheme(_, let tail) = content { return tail }
        return []
    }

    package var hasGrapheme: Bool {
        if case .grapheme = content { return true }
        return false
    }

    package var hasText: Bool { codepoint != 0 }

    package var hasStyling: Bool { styleID != 0 }

    /// No text or background, and not part of a wide character.
    package var isEmpty: Bool {
        switch content {
        case .codepoint, .grapheme: !hasText && wide == .narrow
        case .backgroundPalette, .backgroundRGB: false
        }
    }

    /// Columns the cell's character takes up.
    package var gridWidth: Int { wide == .wide ? 2 : 1 }
}

/// One row of the viewport that changed.
package struct RenderRow: Sendable {
    /// Row in the viewport, from the top.
    package var y: Int
    package var cells: [RenderCell]
    /// The selected columns of this row, inclusive.
    package var selection: ClosedRange<Int>?
}

package struct RenderCursor: Sendable, Equatable {
    package enum Style: Sendable, Equatable {
        case bar
        case block
        case underline
        case blockHollow
    }

    /// The cursor's cell, or nil when it isn't in the viewport.
    package var viewport: (x: Int, y: Int)?
    /// On the second half of a wide character.
    package var wideTail: Bool
    /// Visible per the terminal's modes (DECTCEM).
    package var visible: Bool
    package var blinking: Bool
    /// At a password prompt.
    package var passwordInput: Bool
    package var style: Style

    package static func == (lhs: RenderCursor, rhs: RenderCursor) -> Bool {
        lhs.viewport?.x == rhs.viewport?.x && lhs.viewport?.y == rhs.viewport?.y
            && lhs.wideTail == rhs.wideTail && lhs.visible == rhs.visible && lhs.blinking == rhs.blinking
            && lhs.passwordInput == rhs.passwordInput && lhs.style == rhs.style
    }
}

package struct RenderColors: Sendable, Equatable {
    package var background: RGB
    package var foreground: RGB
    /// Set by the program (OSC 12) or the host's default; nil when neither.
    package var cursor: RGB?
    package var palette: [RGB]
}

/// The scrollable extent and the viewport's place in it, in rows.
package struct Scrollbar: Sendable, Equatable {
    package var total: UInt64
    package var offset: UInt64
    package var length: UInt64
}

/// What changed in the viewport since the renderer last took an update.
package struct RenderUpdate: Sendable {
    package enum Dirty: Sendable {
        /// Only `rows` changed.
        case partial
        /// Everything changed; `rows` holds every row.
        case full
    }

    package var grid: Grid
    package var dirty: Dirty
    package var rows: [RenderRow]
    package var cursor: RenderCursor
    package var colors: RenderColors
    package var scrollbar: Scrollbar
}
