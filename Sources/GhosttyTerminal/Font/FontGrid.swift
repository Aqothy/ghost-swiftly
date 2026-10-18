// Ported from ghostty src/font/SharedGrid.zig @ 81598385d608dda4946093d6d6a234d204a2f225
// Ported from ghostty src/font/SharedGridSet.zig @ 81598385d608dda4946093d6d6a234d204a2f225
// Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors. MIT License.
//
// One grid per view, confined to its renderer, so there's no lock. A new
// font or size builds a new grid, as Ghostty's SharedGridSet does.

import Foundation

/// The fonts, glyph caches and atlases for drawing one terminal grid.
final class FontGrid {
    struct Render {
        var glyph: Glyph
        var presentation: Presentation
    }

    private struct CodepointKey: Hashable {
        var codepoint: UInt32
        var style: FontStyle
        var presentation: Presentation?
    }

    /// The glyph's identity; the metrics and constraint follow from it.
    private struct GlyphKey: Hashable {
        var glyph: UInt32
        var index: FontIndex
        var cellWidth: UInt8
        var thicken: Bool
        var thickenStrength: UInt8
        var constraintWidth: UInt8
    }

    let resolver: CodepointResolver
    let metrics: Metrics
    let grayscaleAtlas = Atlas(size: 512, format: .grayscale)
    let colorAtlas = Atlas(size: 512, format: .bgra)
    private var codepoints: [CodepointKey: FontIndex?] = [:]
    private var glyphs: [GlyphKey: Render] = [:]

    init(resolver: CodepointResolver) {
        resolver.collection.updateMetrics()
        self.resolver = resolver
        metrics = resolver.collection.metrics ?? Self.fallbackMetrics
        resolver.sprite = SpriteFace(metrics: metrics)
    }

    /// Only reached if the primary font can't load, which the bundled
    /// fonts rule out.
    private static let fallbackMetrics = Metrics(face: .init(
        pxPerEm: 12, cellWidth: 8, ascent: 12, descent: -4, lineGap: 0))

    /// The cached font for a codepoint. Loads the face, since a caller asking
    /// is about to use it.
    func index(for codepoint: UInt32, style: FontStyle, presentation: Presentation?) -> FontIndex? {
        let key = CodepointKey(codepoint: codepoint, style: style, presentation: presentation)
        if let cached = codepoints[key] { return cached }
        let index = resolver.index(for: codepoint, style: style, presentation: presentation)
        codepoints[key] = index
        if let index { _ = resolver.collection.face(index) }
        return index
    }

    func hasCodepoint(_ index: FontIndex, _ codepoint: UInt32, _ presentation: Presentation?) -> Bool {
        resolver.collection.hasCodepoint(index, codepoint, presentation.map { .explicit($0) } ?? .any)
    }

    /// Renders the first font's glyph for a codepoint, or nil when no font
    /// has it.
    func renderCodepoint(_ codepoint: UInt32, style: FontStyle, presentation: Presentation?,
                         options: Glyph.RenderOptions) -> Render? {
        guard let index = index(for: codepoint, style: style, presentation: presentation) else { return nil }
        let glyph: UInt32
        if case .sprite = index {
            glyph = codepoint
        } else {
            guard let found = resolver.collection.face(index)?.glyphIndex(codepoint) else { return nil }
            glyph = found
        }
        return renderGlyph(index, glyph: glyph, options: options)
    }

    /// Renders a glyph into the right atlas, growing it when full. Cached.
    func renderGlyph(_ index: FontIndex, glyph: UInt32, options: Glyph.RenderOptions) -> Render {
        let key = GlyphKey(
            glyph: glyph, index: index, cellWidth: options.cellWidth ?? 0, thicken: options.thicken,
            thickenStrength: options.thickenStrength, constraintWidth: options.constraintWidth)
        if let cached = glyphs[key] { return cached }

        let presentation = resolver.presentation(index, glyph: glyph)
        let atlas = presentation == .emoji ? colorAtlas : grayscaleAtlas
        var options = options
        if presentation == .emoji {
            // Emoji fill their cells, centered, keeping their aspect ratio,
            // with a little padding so they don't touch the edges.
            options.constraint = Glyph.Constraint(
                size: .cover, alignVertical: .center, alignHorizontal: .center, padLeft: 0.025, padRight: 0.025)
        }

        var rendered: Glyph
        do {
            rendered = try resolver.renderGlyph(index, glyph: glyph, into: atlas, options: options)
        } catch {
            atlas.grow(to: atlas.size * 2)
            rendered = (try? resolver.renderGlyph(index, glyph: glyph, into: atlas, options: options)) ?? .empty
        }
        let render = Render(glyph: rendered, presentation: presentation)
        glyphs[key] = render
        return render
    }
}

extension FontGrid {
    /// Builds the collection Ghostty builds for a font family: the family's
    /// faces if given, synthesized styles, the bundled JetBrains Mono as
    /// fallback (bold and bold italic through its weight axis), Symbols
    /// Nerd Font, and Apple Color Emoji.
    static func make(family: String?, size: DesiredSize) -> FontGrid {
        let collection = Collection(size: size)

        if let family {
            for style in FontStyle.allCases {
                let descriptor = FontDescriptor(
                    family: family, size: size.points, bold: style.isBold, italic: style.isItalic)
                if let face = Discovery.discover(descriptor).first {
                    collection.addDeferred(face, style: style, fallback: false, sizeAdjustment: .none)
                }
            }
        }
        collection.completeStyles()

        let bold = [Variation(tag: "wght", value: 700)]
        for (style, file, variations) in [
            (FontStyle.regular, "JetBrainsMono", [Variation]()),
            (.bold, "JetBrainsMono", bold),
            (.italic, "JetBrainsMono-Italic", []),
            (.boldItalic, "JetBrainsMono-Italic", bold),
        ] {
            guard let face = BundledFont.face(file, size: size) else { continue }
            collection.add(face.withVariations(variations), style: style, fallback: true, sizeAdjustment: .icWidth)
        }
        if let symbols = BundledFont.face("SymbolsNerdFont-Regular", size: size) {
            collection.add(symbols, style: .regular, fallback: true, sizeAdjustment: .none)
        }
        // Always prefer the official emoji font over others the user has
        // installed.
        if let emoji = Discovery.discoverExactFamily("Apple Color Emoji") {
            collection.addDeferred(emoji, style: .regular, fallback: true, sizeAdjustment: .none)
        }
        return FontGrid(resolver: CodepointResolver(collection: collection))
    }
}

/// The fonts in the package's resources.
enum BundledFont {
    static func face(_ name: String, size: DesiredSize) -> Face? {
        guard let url = Bundle.module.url(forResource: name, withExtension: "ttf", subdirectory: "Fonts"),
              let data = try? Data(contentsOf: url) else { return nil }
        return Face(data: data, size: size)
    }
}
