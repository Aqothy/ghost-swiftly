import Testing
@testable import GhosttyTerminal

struct FontGridTests {
    let grid = FontGrid.make(family: nil, size: DesiredSize(points: 13, scale: 2))

    private func options(_ cellWidth: UInt8 = 1) -> Glyph.RenderOptions {
        Glyph.RenderOptions(gridMetrics: grid.metrics, cellWidth: cellWidth)
    }

    @Test func theBundledFontIsPrimary() throws {
        let primary = try #require(grid.resolver.collection.face(.primary))
        #expect(primary.familyName == "JetBrains Mono")
        // JetBrains Mono advances 600/1000 em: 13pt × 2 × 0.6 = 15.6px.
        #expect(grid.metrics.cellWidth == 16)
    }

    @Test func textGlyphsRasterizeIntoTheGrayscaleAtlas() throws {
        let render = try #require(grid.renderCodepoint(0x41, style: .regular, presentation: nil, options: options()))
        #expect(render.presentation == .text)
        #expect(render.glyph.width > 0 && render.glyph.height > 0)
    }

    @Test func boxDrawingIsDrawnBySprites() throws {
        #expect(grid.index(for: 0x2500, style: .regular, presentation: nil) == .sprite)
        let render = grid.renderGlyph(.sprite, glyph: 0x2500, options: options())
        // A full-width light line.
        #expect(render.glyph.width == grid.metrics.cellWidth)
        #expect(render.glyph.height == grid.metrics.boxThickness)
    }

    @Test func emojiUseTheColorAtlas() throws {
        let index = try #require(grid.index(for: 0x1F600, style: .regular, presentation: nil))
        #expect(grid.resolver.collection.face(index)?.familyName == "Apple Color Emoji")
        let render = try #require(grid.renderCodepoint(0x1F600, style: .regular, presentation: nil, options: options(2)))
        #expect(render.presentation == .emoji)
    }

    @Test func cjkFallsBackToASystemFont() throws {
        let index = try #require(grid.index(for: 0x6C34, style: .regular, presentation: nil))
        #expect(index != .primary)
        #expect(grid.resolver.collection.face(index)?.glyphIndex(0x6C34) != nil)
    }

    @Test func nerdFontSymbolsComeFromTheBundledSymbolsFont() throws {
        // U+F418, the nf-oct-git_branch icon.
        let index = try #require(grid.index(for: 0xF418, style: .regular, presentation: nil))
        #expect(grid.resolver.collection.face(index)?.familyName == "Symbols Nerd Font")
    }

    @Test func aFullAtlasGrows() {
        let before = grid.grayscaleAtlas.size
        // 400 wide ideographs of about 32×34px overflow a 512×512 atlas.
        for codepoint in UInt32(0x4E00)..<UInt32(0x4E00 + 400) {
            _ = grid.renderCodepoint(codepoint, style: .regular, presentation: nil, options: options(2))
        }
        #expect(grid.grayscaleAtlas.size > before)
        let last = grid.renderCodepoint(0x4E00 + 399, style: .regular, presentation: nil, options: options(2))
        #expect((last?.glyph.width ?? 0) > 0)
    }
}
