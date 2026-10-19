// Ported from ghostty src/renderer/generic.zig @ 81598385d608dda4946093d6d6a234d204a2f225
// Ported from ghostty src/renderer/cursor.zig @ 81598385d608dda4946093d6d6a234d204a2f225
// Ported from ghostty src/terminal/style.zig @ 81598385d608dda4946093d6d6a234d204a2f225
// Ported from ghostty src/renderer/State.zig @ 81598385d608dda4946093d6d6a234d204a2f225
// Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors. MIT License.
//
// rebuildCells, rebuildRow, addGlyph, addUnderline/Overline/Strikethrough
// and addCursor, reading RenderUpdate instead of Ghostty's Zig render state.
// Without search highlights, links, kitty images, padding extension or
// background opacity (all config or out of scope).

import Foundation
import GhosttyVT

/// The colors a theme gives the renderer on top of the terminal's own.
struct RendererColors: Equatable, Sendable {
    /// Ghostty's `cursor-color`; nil uses the foreground.
    var cursor: RGB?
    /// Ghostty's `cursor-text`; nil uses the background.
    var cursorText: RGB?
    /// Ghostty's `selection-background`; nil uses the foreground.
    var selectionBackground: RGB?
    /// Ghostty's `selection-foreground`; nil uses the background.
    var selectionForeground: RGB?
}

/// IME composition text, drawn at the cursor until committed (Ghostty's
/// `renderer.State.Preedit`).
struct Preedit: Equatable, Sendable {
    struct Codepoint: Equatable, Sendable {
        var codepoint: UInt32
        var wide: Bool
    }

    var codepoints: [Codepoint]

    /// The columns the preedit covers starting at `start`, shifted left to
    /// end by `max`, and the first codepoint that fits when it's wider than
    /// that.
    func range(start: Int, max: Int) -> (start: Int, end: Int, codepointOffset: Int) {
        // Measure from the end so the latest input stays visible.
        let maxWidth = max - start + 1
        var width = 0
        var offset = 0
        for index in codepoints.indices.reversed() {
            width += codepoints[index].wide ? 2 : 1
            if width > maxWidth {
                offset = index
                break
            }
        }
        let end = width > 0 ? start + width - 1 : start
        let shift = end > max ? end - max : 0
        return (Swift.max(0, start - shift), Swift.max(0, end - shift), offset)
    }
}

/// Turns render updates into GPU cells, rebuilding only what changed.
final class CellBuilder {
    private(set) var contents = CellContents()
    /// Grid size, cursor and background, maintained here; the frame drawer
    /// fills in the screen-size fields.
    private(set) var uniforms = Uniforms()
    let grid: FontGrid
    private let shaper: Shaper
    private var shaperCache = ShaperCache()
    /// The viewport's rows as of the last update. A row that isn't dirty is
    /// unchanged since the update that carried it.
    private var rows: [[RenderCell]] = []
    private var selections: [ClosedRange<Int>?] = []
    private var preedit: Preedit?
    /// The row the preedit was last drawn on.
    private var preeditRow: Int?
    private var cursor: RenderCursor?
    var cursorBlinks: Bool { cursor?.blinking ?? false }
    private var colors: RenderColors?
    var rendererColors = RendererColors()
    /// Ghostty's `faint-opacity` default, 0.5.
    private let faintOpacity = UInt8((0.5 * 255).rounded(.up))

    init(grid: FontGrid) {
        self.grid = grid
        shaper = Shaper(grid: grid)
    }

    /// Rebuilds the rows an update carries, the cursor and the background.
    func apply(_ update: RenderUpdate, focused: Bool, blinkVisible: Bool) {
        let columns = Int(update.grid.columns)
        let rowCount = Int(update.grid.rows)
        let resized = contents.columns != columns || contents.rows != rowCount
        if resized {
            contents.resize(columns: columns, rows: rowCount)
            rows = [[RenderCell]](repeating: [], count: rowCount)
            selections = [ClosedRange<Int>?](repeating: nil, count: rowCount)
            preeditRow = nil
            uniforms.gridSize = SIMD2(UInt16(columns), UInt16(rowCount))
        }
        if update.dirty == .full || resized { contents.reset() }

        cursor = update.cursor
        colors = update.colors
        for row in update.rows where row.y < rowCount {
            rows[row.y] = row.cells
            selections[row.y] = row.selection
            contents.clear(row: row.y)
            rebuildRow(row.y, row.cells, selection: row.selection, update.colors, update.cursor)
        }
        if preedit != nil || preeditRow != nil { rebuildPreeditRows() }
        rebuildCursor(focused: focused, blinkVisible: blinkVisible)

        let background = update.colors.background
        uniforms.bgColor = SIMD4(background.r, background.g, background.b, 255)
    }

    /// Shows, changes or (with nil) removes the IME preedit.
    func setPreedit(_ preedit: Preedit?, focused: Bool, blinkVisible: Bool) {
        guard preedit != self.preedit else { return }
        self.preedit = preedit
        rebuildPreeditRows()
        rebuildCursor(focused: focused, blinkVisible: blinkVisible)
    }

    /// Rebuilds the row the preedit was on and the one it's on now, with the
    /// preedit drawn over the cells it covers.
    private func rebuildPreeditRows() {
        guard let colors, let cursor else { return }
        let target = preedit == nil ? nil : cursor.viewport.map(\.y)
        for y in Set([preeditRow, target].compactMap { $0 }) where y < rows.count {
            contents.clear(row: y)
            let range = y == target ? preedit?.range(start: cursor.viewport!.x, max: contents.columns - 1) : nil
            rebuildRow(y, rows[y], selection: selections[y], colors, cursor,
                       skip: range.map { $0.start...$0.end })
            if let preedit, let range {
                var x = range.start
                for codepoint in preedit.codepoints[range.codepointOffset...] {
                    addPreeditCell(codepoint, x, y, colors.foreground)
                    x += codepoint.wide ? 2 : 1
                }
            }
        }
        preeditRow = target
    }

    private func addPreeditCell(_ codepoint: Preedit.Codepoint, _ x: Int, _ y: Int, _ color: RGB) {
        guard x < contents.columns else { return }
        let options = Glyph.RenderOptions(gridMetrics: grid.metrics, cellWidth: 1)
        if let render = grid.renderCodepoint(codepoint.codepoint, style: .regular, presentation: .text, options: options) {
            contents.add(CellText(atlas: .grayscale, gridPos: SIMD2(UInt16(x), UInt16(y)),
                                  color: SIMD4(color.r, color.g, color.b, 255), glyph: render.glyph))
        }
        addDecoration(.underline, x, y, color, 255)
        if codepoint.wide, x < contents.columns - 1 { addDecoration(.underline, x + 1, y, color, 255) }
    }

    /// Redraws only the cursor, for focus and blink changes.
    func rebuildCursor(focused: Bool, blinkVisible: Bool) {
        contents.setCursor(nil, .beforeText)
        uniforms.cursorPos = SIMD2(.max, .max)
        // The preedit stands in for the cursor.
        guard preedit == nil else { return }
        guard let cursor, let colors, let viewport = cursor.viewport, viewport.y < rows.count else { return }
        let cells = rows[viewport.y]
        let cell = viewport.x < cells.count ? cells[viewport.x] : nil

        guard let style = Self.cursorStyle(cursor, focused: focused, blinkVisible: blinkVisible) else { return }

        let cursorColor = colors.cursor ?? rendererColors.cursor ?? colors.foreground
        addCursor(cursor, cell, style, cursorColor, focused: focused)

        if style == .block {
            let wide = cell?.wide ?? .narrow
            uniforms.cursorPos = SIMD2(
                UInt16(wide == .spacerTail ? max(0, viewport.x - 1) : viewport.x), UInt16(viewport.y))
            uniforms.cursorWide = wide == .wide || wide == .spacerTail
            let text = rendererColors.cursorText ?? colors.background
            uniforms.cursorColor = SIMD4(text.r, text.g, text.b, 255)
        }
    }

    // MARK: Cursor

    enum CursorStyle {
        case block
        case blockHollow
        case bar
        case underline
        case lock
    }

    /// Ghostty's `renderer.cursorStyle`, in priority order. A preedit hides
    /// the cursor before this is asked (generic.zig rebuildCells).
    static func cursorStyle(_ cursor: RenderCursor, focused: Bool, blinkVisible: Bool) -> CursorStyle? {
        guard cursor.viewport != nil else { return nil }
        if cursor.passwordInput { return .lock }
        if !cursor.visible { return nil }
        // Unfocused, always show the hollow box.
        if !focused { return .blockHollow }
        if cursor.blinking, !blinkVisible { return nil }
        return switch cursor.style {
        case .bar: .bar
        case .block: .block
        case .blockHollow: .blockHollow
        case .underline: .underline
        }
    }

    private func addCursor(_ cursor: RenderCursor, _ cell: RenderCell?, _ style: CursorStyle, _ color: RGB,
                           focused: Bool) {
        guard let viewport = cursor.viewport else { return }
        // On a wide character's tail, the cursor covers the whole character.
        let (wide, x) = cursor.wideTail ? (true, viewport.x - 1) : (cell?.wide == .wide, viewport.x)
        let options = Glyph.RenderOptions(gridMetrics: grid.metrics, cellWidth: wide ? 2 : 1)
        let render: FontGrid.Render?
        switch style {
        case .block, .blockHollow, .bar, .underline:
            let sprite: Sprite = switch style {
            case .block: .cursorRect
            case .blockHollow: .cursorHollowRect
            case .bar: .cursorBar
            default: .cursorUnderline
            }
            render = grid.renderGlyph(.sprite, glyph: sprite.rawValue, options: options)
        case .lock:
            // The lock icon, from the bundled Symbols Nerd Font.
            render = grid.renderCodepoint(0xF023, style: .regular, presentation: .text, options: options)
        }
        guard let render else { return }
        // Ghostty's `cursor-opacity` default is 1.
        let cell = CellText(atlas: .grayscale, bools: .isCursorGlyph, gridPos: SIMD2(UInt16(max(0, x)), UInt16(viewport.y)),
                            color: SIMD4(color.r, color.g, color.b, 255), glyph: render.glyph)
        contents.setCursor(cell, style == .block ? .beforeText : .afterText)
    }

    // MARK: Rows

    // swiftlint:disable:next function_body_length cyclomatic_complexity
    private func rebuildRow(_ y: Int, _ cells: [RenderCell], selection: ClosedRange<Int>?, _ colors: RenderColors,
                            _ cursor: RenderCursor, skip: ClosedRange<Int>? = nil) {
        let columns = min(cells.count, contents.columns)
        let cursorX = cursor.viewport?.y == y ? cursor.viewport?.x : nil
        var runs = RunIterator(grid: grid, shaper: shaper, cells: cells, selection: selection, cursorX: cursorX)
        var run = runs.next()
        var shaped: [ShapedCell]?
        var shapedIndex = 0

        for x in 0..<columns {
            // A preedit draws over these columns.
            if let skip {
                if skip.contains(x) { continue }
                // Catch the runs up past the skipped cells.
                if x == skip.upperBound + 1 {
                    while let current = run, current.offset + current.cells <= x {
                        run = runs.next()
                        shaped = nil
                        shapedIndex = 0
                    }
                }
            }
            let cell = cells[x]
            let style = cell.hasStyling ? cell.style : .default

            // Selection uses the wide character's first column.
            let compareX = cell.wide == .spacerTail ? max(0, x - 1) : x
            let selected = selection?.contains(compareX) ?? false

            // From the SGR style, before configuration, inversion or selection.
            let bgStyle = Self.background(style, cell, colors.palette)
            let fgStyle = Self.foreground(style, colors)

            let bg: RGB? = if selected {
                rendererColors.selectionBackground ?? colors.foreground
            } else if style.inverse != CellClass.isCovering(cell.codepoint) {
                // Inverse, or a covering glyph so padding extension works;
                // both together cancel out.
                fgStyle
            } else {
                bgStyle
            }

            let finalBackground = bgStyle ?? colors.background
            let fg: RGB = if selected {
                rendererColors.selectionForeground ?? colors.background
            } else {
                style.inverse ? finalBackground : fgStyle
            }

            let alpha: UInt8 = style.faint ? faintOpacity : 255

            // Selected, inverse and explicit backgrounds are opaque; others
            // show the surface background through.
            let rgb = bg ?? colors.background
            let bgAlpha: UInt8 = selected || style.inverse || bgStyle != nil ? 255 : 0
            contents.setBackground(row: y, column: x, SIMD4(rgb.r, rgb.g, rgb.b, bgAlpha))

            // Invisible draws no foreground at all, as in xterm.
            if style.invisible { continue }

            // Decorations draw under the text so descenders stay readable.
            if style.underline != .none {
                let underlineColor = Self.underlineColor(style, colors.palette) ?? fg
                addDecoration(Self.sprite(for: style.underline), x, y, underlineColor, alpha)
            }
            if style.overline { addDecoration(.overline, x, y, fg, alpha) }

            if let shapedCells = shaped, shapedIndex >= shapedCells.count {
                run = runs.next()
                shaped = nil
                shapedIndex = 0
            }

            if let current = run {
                if shaped == nil {
                    if let cached = shaperCache.get(current) {
                        shaped = cached
                    } else {
                        let cells = shaper.shape(current)
                        shaperCache.put(current, cells)
                        shaped = cells
                    }
                }
                // Glyphs land in at most one run, at increasing x.
                if let shapedCells = shaped {
                    // Glyphs of skipped cells.
                    while shapedIndex < shapedCells.count, current.offset + Int(shapedCells[shapedIndex].x) < x {
                        shapedIndex += 1
                    }
                    while shapedIndex < shapedCells.count, current.offset + Int(shapedCells[shapedIndex].x) == x {
                        addGlyph(x, y, cells, shapedCells[shapedIndex], current, fg, alpha)
                        shapedIndex += 1
                    }
                }
            }

            if style.strikethrough { addDecoration(.strikethrough, x, y, fg, alpha) }
        }
    }

    private static func sprite(for underline: CellStyle.Underline) -> Sprite {
        switch underline {
        case .double: .underlineDouble
        case .dotted: .underlineDotted
        case .dashed: .underlineDashed
        case .curly: .underlineCurly
        case .single, .none: .underline
        }
    }

    private func addDecoration(_ sprite: Sprite, _ x: Int, _ y: Int, _ color: RGB, _ alpha: UInt8) {
        let render = grid.renderGlyph(.sprite, glyph: sprite.rawValue,
                                      options: Glyph.RenderOptions(gridMetrics: grid.metrics, cellWidth: 1))
        contents.add(CellText(atlas: .grayscale, gridPos: SIMD2(UInt16(x), UInt16(y)),
                              color: SIMD4(color.r, color.g, color.b, alpha), glyph: render.glyph))
    }

    private func addGlyph(_ x: Int, _ y: Int, _ cells: [RenderCell], _ shaped: ShapedCell, _ run: TextRun,
                          _ color: RGB, _ alpha: UInt8) {
        let cp = cells[x].codepoint
        // Nerd Font constraints, else symbols fit their cells.
        let constraint = NerdFontConstraints.constraint(cp)
            ?? (CellClass.isSymbol(cp) ? Glyph.Constraint(size: .fit) : .none)
        let options = Glyph.RenderOptions(
            gridMetrics: grid.metrics,
            cellWidth: UInt8(cells[x].gridWidth),
            constraint: constraint,
            constraintWidth: CellClass.constraintWidth(cells, x))
        let render = grid.renderGlyph(run.fontIndex, glyph: shaped.glyphIndex, options: options)
        // Zero-sized glyphs draw nothing.
        if render.glyph.width == 0 || render.glyph.height == 0 { return }
        contents.add(CellText(
            atlas: render.presentation == .emoji ? .color : .grayscale,
            bools: CellClass.noMinContrast(cp) ? .noMinContrast : [],
            gridPos: SIMD2(UInt16(x), UInt16(y)),
            color: SIMD4(color.r, color.g, color.b, alpha),
            glyph: render.glyph,
            bearingOffset: SIMD2(Int32(shaped.xOffset), Int32(shaped.yOffset))))
    }

    // MARK: Style colors (terminal/style.zig)

    /// The background from a bg-only cell's content or the style; nil when
    /// neither sets one.
    static func background(_ style: CellStyle, _ cell: RenderCell, _ palette: [RGB]) -> RGB? {
        switch cell.content {
        case .backgroundPalette(let index): return palette[Int(index)]
        case .backgroundRGB(let rgb): return rgb
        case .codepoint, .grapheme: return resolve(style.background, palette)
        }
    }

    /// The foreground, with Ghostty's default `bold-color` (none).
    static func foreground(_ style: CellStyle, _ colors: RenderColors) -> RGB {
        resolve(style.foreground, colors.palette) ?? colors.foreground
    }

    static func underlineColor(_ style: CellStyle, _ palette: [RGB]) -> RGB? {
        resolve(style.underlineColor, palette)
    }

    private static func resolve(_ color: StyleColor, _ palette: [RGB]) -> RGB? {
        switch color {
        case .none: nil
        case .palette(let index): palette[Int(index)]
        case .rgb(let rgb): rgb
        }
    }
}
