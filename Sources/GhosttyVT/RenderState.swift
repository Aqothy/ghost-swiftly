import GhosttyVt
import Synchronization

/// The render state a view draws from, shared by its ``Terminal`` and its
/// renderer.
///
/// libghostty-vt splits a render state update in two (ghostty `render.h`,
/// "Two-Phase Updates"): `begin_update` needs the terminal, `end_update` only
/// the render state. The terminal's executor begins updates; the renderer
/// ends them and copies out the dirty rows. The lock covers only the render
/// state, so the renderer's hold time is a copy, and the terminal never waits
/// on shaping or drawing. Several begins before one end are fine: dirty flags
/// and pending styles accumulate until the renderer cleans them (ghostty
/// `src/terminal/render.zig`, `endUpdate`).
///
/// A begin walks every dirty row, and while output scrolls every row is
/// dirty, so beginning one per read would rebuild the viewport for every few
/// hundred bytes. The terminal begins at most one update per frame instead,
/// as Ghostty's renderer does from its own thread: while the renderer hasn't
/// taken the last update, a change only marks it behind, and taking a behind
/// update asks the terminal for a fresh one.
package final class RenderState: Sendable {
    private struct Native: ~Copyable {
        let state: OpaquePointer
        let rows: OpaquePointer
        let cells: OpaquePointer
        var pending = Pending.none
        /// A program holds the screen (synchronized output): keep the frame
        /// captured when the hold began.
        var held = false
        /// Read with each begin, while the terminal is exclusive, so it
        /// describes the same moment as the render state (ghostty `render.h`,
        /// "Overscan").
        var scrollbar = Scrollbar(total: 0, offset: 0, length: 0)

        deinit {
            ghostty_render_state_row_cells_free(cells)
            ghostty_render_state_row_iterator_free(rows)
            ghostty_render_state_free(state)
        }
    }

    private enum Pending {
        /// The renderer has taken every update.
        case none
        /// An update is ready for the renderer.
        case current
        /// An update is ready, and the terminal has changed since it began.
        case behind
    }

    private let native: Mutex<Native>
    private let wake: @Sendable () -> Void
    /// Asks the attached terminal to begin a fresh update, on its executor.
    private let recapture = Mutex<(@Sendable () -> Void)?>(nil)

    /// `wake` is called, outside the lock, whenever a new update is ready.
    package init(wake: @escaping @Sendable () -> Void) throws(GhosttyError) {
        var state: OpaquePointer?
        var rows: OpaquePointer?
        var cells: OpaquePointer?
        guard ghostty_render_state_new(nil, &state) == GHOSTTY_SUCCESS, let state,
              ghostty_render_state_row_iterator_new(nil, &rows) == GHOSTTY_SUCCESS, let rows,
              ghostty_render_state_row_cells_new(nil, &cells) == GHOSTTY_SUCCESS, let cells
        else {
            ghostty_render_state_row_cells_free(cells)
            ghostty_render_state_row_iterator_free(rows)
            ghostty_render_state_free(state)
            throw .outOfMemory
        }
        native = Mutex(Native(state: state, rows: rows, cells: cells))
        self.wake = wake
    }

    // MARK: Terminal side (the terminal's executor)

    func attached(recapture: @escaping @Sendable () -> Void) {
        self.recapture.withLock { $0 = recapture }
    }

    /// The terminal changed: begins an update unless a program holds the
    /// screen or the renderer hasn't taken the last one.
    func capture(_ terminal: OpaquePointer) {
        let terminal = BorrowedTerminal(pointer: terminal)
        let began = native.withLock { native in
            guard !native.held else { return false }
            if native.pending != .none {
                native.pending = .behind
                return false
            }
            Self.begin(&native, terminal)
            return true
        }
        if began { wake() }
    }

    /// A program began or ended a render hold (mode 2026). When it begins,
    /// the terminal holds exactly the frame the program wants left on screen
    /// (ghostty `terminal.h`, `GhosttyTerminalRenderHoldFn`), so capture it.
    func setHeld(_ held: Bool, _ terminal: OpaquePointer) {
        let terminal = BorrowedTerminal(pointer: terminal)
        native.withLock { native in
            if held { Self.begin(&native, terminal) }
            native.held = held
        }
        wake()
    }

    private static func begin(_ native: inout Native, _ terminal: BorrowedTerminal) {
        let terminal = terminal.pointer
        ghostty_render_state_begin_update(native.state, terminal)
        var scrollbar = GhosttyTerminalScrollbar()
        if ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_SCROLLBAR, &scrollbar) == GHOSTTY_SUCCESS {
            native.scrollbar = Scrollbar(total: scrollbar.total, offset: scrollbar.offset, length: scrollbar.len)
        }
        native.pending = .current
    }

    // MARK: Renderer side

    /// Marks every row dirty, for a renderer that lost its cells (new fonts
    /// or colors).
    package func redrawAll() {
        native.withLock { native in
            var full = GHOSTTY_RENDER_STATE_DIRTY_FULL
            ghostty_render_state_set(native.state, GHOSTTY_RENDER_STATE_OPTION_DIRTY, &full)
            if native.pending == .none { native.pending = .current }
        }
        wake()
    }

    /// Takes what changed since the last call, or nil when nothing did.
    package func takeUpdate() -> RenderUpdate? {
        let (update, behind) = native.withLock { native -> (RenderUpdate?, Bool) in
            let pending = native.pending
            guard pending != .none else { return (nil, false) }
            native.pending = .none
            ghostty_render_state_end_update(native.state)
            defer { ghostty_render_state_clean(native.state) }
            return (Self.read(native), pending == .behind)
        }
        if behind { recapture.withLock { $0 }?() }
        return update
    }

    private static func read(_ native: borrowing Native) -> RenderUpdate? {
        let state = native.state
        var dirty = GHOSTTY_RENDER_STATE_DIRTY_FALSE
        ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_DIRTY, &dirty)
        var columns: UInt16 = 0
        var rowCount: UInt16 = 0
        ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_COLS, &columns)
        ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_ROWS, &rowCount)

        var colors = GhosttyRenderStateColors()
        colors.size = MemoryLayout<GhosttyRenderStateColors>.size
        ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_COLORS, &colors)
        var cursor = GhosttyRenderStateCursor()
        cursor.size = MemoryLayout<GhosttyRenderStateCursor>.size
        ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_CURSOR, &cursor)

        var rows: [RenderRow] = []
        var rowIterator: OpaquePointer? = native.rows
        if dirty != GHOSTTY_RENDER_STATE_DIRTY_FALSE,
           ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &rowIterator) == GHOSTTY_SUCCESS {
            var y: UInt16 = 0
            while ghostty_render_state_row_iterator_next_dirty(native.rows, &y) {
                rows.append(readRow(Int(y), native.rows, native.cells))
            }
        }

        return RenderUpdate(
            grid: GridSize(columns: columns, rows: rowCount),
            dirty: dirty == GHOSTTY_RENDER_STATE_DIRTY_FULL ? .full : .partial,
            rows: rows,
            cursor: RenderCursor(cursor),
            colors: RenderColors(colors),
            scrollbar: native.scrollbar)
    }

    private static func readRow(_ y: Int, _ rowIterator: OpaquePointer, _ rowCells: OpaquePointer) -> RenderRow {
        var view = GhosttyCellsView()
        ghostty_render_state_row_get(rowIterator, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS_RAW, &view)
        var cellsHandle: OpaquePointer? = rowCells
        ghostty_render_state_row_get(rowIterator, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, &cellsHandle)

        var selection = GhosttyRenderStateRowSelection()
        selection.size = MemoryLayout<GhosttyRenderStateRowSelection>.size
        let selected = ghostty_render_state_row_get(rowIterator, GHOSTTY_RENDER_STATE_ROW_DATA_SELECTION, &selection)
            == GHOSTTY_SUCCESS
            ? Int(selection.start_x)...Int(selection.end_x) : nil

        // Style ids are unique within a row's page, so each is read once.
        var styles: [UInt16: CellStyle] = [:]
        var cells: [RenderCell] = []
        cells.reserveCapacity(view.len)
        for x in 0..<view.len {
            let raw = view.ptr[x]
            let styleID: UInt16 = cellValue(raw, GHOSTTY_CELL_DATA_STYLE_ID)
            let style: CellStyle
            if styleID == 0 {
                style = .default
            } else if let cached = styles[styleID] {
                style = cached
            } else {
                var native = GhosttyStyle()
                native.size = MemoryLayout<GhosttyStyle>.size
                ghostty_render_state_row_cells_select(rowCells, UInt16(x))
                ghostty_render_state_row_cells_get(rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, &native)
                style = CellStyle(native)
                styles[styleID] = style
            }
            cells.append(RenderCell(
                content: content(raw, x: x, rowCells),
                wide: wide(raw),
                styleID: styleID,
                style: style))
        }
        return RenderRow(y: y, cells: cells, selection: selected)
    }

    private static func content(_ raw: GhosttyCell, x: Int, _ rowCells: OpaquePointer) -> RenderCell.Content {
        let tag: GhosttyCellContentTag = enumValue(raw, GHOSTTY_CELL_DATA_CONTENT_TAG)
        switch tag {
        case GHOSTTY_CELL_CONTENT_BG_COLOR_PALETTE:
            return .backgroundPalette(cellValue(raw, GHOSTTY_CELL_DATA_COLOR_PALETTE))
        case GHOSTTY_CELL_CONTENT_BG_COLOR_RGB:
            var rgb = GhosttyColorRgb()
            ghostty_cell_get(raw, GHOSTTY_CELL_DATA_COLOR_RGB, &rgb)
            return .backgroundRGB(RGB(rgb))
        case GHOSTTY_CELL_CONTENT_CODEPOINT_GRAPHEME:
            ghostty_render_state_row_cells_select(rowCells, UInt16(x))
            var length: UInt32 = 0
            ghostty_render_state_row_cells_get(rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_LEN, &length)
            var codepoints = [UInt32](repeating: 0, count: Int(length))
            codepoints.withUnsafeMutableBufferPointer { buffer in
                _ = ghostty_render_state_row_cells_get(
                    rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF, buffer.baseAddress)
            }
            guard let first = codepoints.first else { return .codepoint(0) }
            return .grapheme(first, Array(codepoints.dropFirst()))
        default:
            return .codepoint(cellValue(raw, GHOSTTY_CELL_DATA_CODEPOINT))
        }
    }

    private static func wide(_ raw: GhosttyCell) -> RenderCell.Wide {
        switch enumValue(raw, GHOSTTY_CELL_DATA_WIDE) as GhosttyCellWide {
        case GHOSTTY_CELL_WIDE_WIDE: .wide
        case GHOSTTY_CELL_WIDE_SPACER_TAIL: .spacerTail
        case GHOSTTY_CELL_WIDE_SPACER_HEAD: .spacerHead
        default: .narrow
        }
    }

    private static func cellValue<T: FixedWidthInteger>(_ raw: GhosttyCell, _ data: GhosttyCellData) -> T {
        var value: T = 0
        ghostty_cell_get(raw, data, &value)
        return value
    }

    private static func enumValue<T: RawRepresentable>(_ raw: GhosttyCell, _ data: GhosttyCellData) -> T
        where T.RawValue: FixedWidthInteger {
        var value: T.RawValue = 0
        ghostty_cell_get(raw, data, &value)
        return T(rawValue: value)!
    }
}

/// The terminal handle for the length of one call from the terminal's
/// executor, which is the only place that touches it.
private struct BorrowedTerminal: @unchecked Sendable {
    let pointer: OpaquePointer
}

extension RGB {
    init(_ rgb: GhosttyColorRgb) {
        self.init(r: rgb.r, g: rgb.g, b: rgb.b)
    }
}

extension StyleColor {
    init(_ color: GhosttyStyleColor) {
        switch color.tag {
        case GHOSTTY_STYLE_COLOR_PALETTE: self = .palette(color.value.palette)
        case GHOSTTY_STYLE_COLOR_RGB: self = .rgb(RGB(color.value.rgb))
        default: self = .none
        }
    }
}

extension CellStyle {
    init(_ style: GhosttyStyle) {
        foreground = StyleColor(style.fg_color)
        background = StyleColor(style.bg_color)
        underlineColor = StyleColor(style.underline_color)
        bold = style.bold
        italic = style.italic
        faint = style.faint
        blink = style.blink
        inverse = style.inverse
        invisible = style.invisible
        strikethrough = style.strikethrough
        overline = style.overline
        underline = switch GhosttySgrUnderline(rawValue: Int32(style.underline)) {
        case GHOSTTY_SGR_UNDERLINE_SINGLE: .single
        case GHOSTTY_SGR_UNDERLINE_DOUBLE: .double
        case GHOSTTY_SGR_UNDERLINE_CURLY: .curly
        case GHOSTTY_SGR_UNDERLINE_DOTTED: .dotted
        case GHOSTTY_SGR_UNDERLINE_DASHED: .dashed
        default: .none
        }
    }
}

extension RenderCursor {
    init(_ cursor: GhosttyRenderStateCursor) {
        viewport = cursor.viewport_has_value ? (Int(cursor.viewport_x), Int(cursor.viewport_y)) : nil
        wideTail = cursor.viewport_has_value && cursor.wide_tail
        visible = cursor.visible
        blinking = cursor.blinking
        passwordInput = cursor.password_input
        style = switch cursor.visual_style {
        case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BAR: .bar
        case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_UNDERLINE: .underline
        case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK_HOLLOW: .blockHollow
        default: .block
        }
    }
}

extension RenderColors {
    init(_ colors: GhosttyRenderStateColors) {
        background = RGB(colors.background)
        foreground = RGB(colors.foreground)
        cursor = colors.cursor_has_value ? RGB(colors.cursor) : nil
        palette = withUnsafeBytes(of: colors.palette) { bytes in
            let rgb = bytes.bindMemory(to: GhosttyColorRgb.self)
            return rgb.map(RGB.init)
        }
    }
}
