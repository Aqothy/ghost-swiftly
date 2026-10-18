// Ported from ghostty src/font/Collection.zig @ 81598385d608dda4946093d6d6a234d204a2f225
// Ported from ghostty src/font/DeferredFace.zig @ 81598385d608dda4946093d6d6a234d204a2f225
// Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors. MIT License.
//
// CoreText only. No metric modifiers (config plumbing).

import CoreText
import Foundation

enum FontStyle: CaseIterable, Hashable, Sendable {
    case regular
    case bold
    case italic
    case boldItalic

    init(bold: Bool, italic: Bool) {
        switch (bold, italic) {
        case (true, true): self = .boldItalic
        case (true, false): self = .bold
        case (false, true): self = .italic
        case (false, false): self = .regular
        }
    }

    var isBold: Bool { self == .bold || self == .boldItalic }
    var isItalic: Bool { self == .italic || self == .boldItalic }
}

/// A specific font in a collection, or the sprite font drawn in code.
enum FontIndex: Hashable, Sendable {
    case face(FontStyle, Int)
    case sprite

    static let primary = FontIndex.face(.regular, 0)
}

/// A discovered font that isn't loaded at its final size yet. Cheap enough
/// to search many of for a codepoint.
struct DeferredFace {
    /// At 12pt; resized on load.
    let font: CTFont
    let variations: [Variation]

    var familyName: String { CTFontCopyFamilyName(font) as String }

    func load(size: DesiredSize) -> Face {
        Face(copying: font, size: size).withVariations(variations)
    }

    /// Whether the font has the codepoint, in the presentation if given. The
    /// presentation check looks at the whole font's color trait, since
    /// forced presentations are only used for emoji.
    func hasCodepoint(_ codepoint: UInt32, _ presentation: Presentation?) -> Bool {
        if let presentation {
            let color = CTFontGetSymbolicTraits(font).contains(.traitColorGlyphs)
            guard (color ? .emoji : .text) == presentation else { return false }
        }
        return Face.glyph(in: font, for: codepoint) != nil
    }
}

/// The presentation a codepoint lookup requires.
enum PresentationMode {
    /// Explicit (VS15/VS16): always honored.
    case explicit(Presentation)
    /// From the Unicode data: honored by fallback fonts only.
    case `default`(Presentation)
    /// Any presentation.
    case any
}

/// How a fallback face's size is matched to the primary face, like CSS
/// `font-size-adjust`.
enum SizeAdjustment {
    case none
    /// Match the ideograph width.
    case icWidth
    case exHeight
    case capHeight
    case lineHeight
}

/// Fonts by style, in priority order, all at one size.
final class Collection {
    final class Entry {
        enum Content {
            case deferred(DeferredFace)
            case loaded(Face)
        }

        enum Scale {
            /// Computed once the face is loaded.
            case adjustment(SizeAdjustment)
            case factor(Double)
        }

        var content: Content
        /// Fallback faces need an exact presentation match; explicitly chosen
        /// faces use any glyph they have for a codepoint unless a presentation
        /// is forced.
        let fallback: Bool
        var scale: Scale

        init(_ content: Content, fallback: Bool, scale: Scale = .factor(1)) {
            self.content = content
            self.fallback = fallback
            self.scale = scale
        }

        var loaded: Face? {
            if case .loaded(let face) = content { return face }
            return nil
        }

        func hasCodepoint(_ codepoint: UInt32, _ mode: PresentationMode) -> Bool {
            switch mode {
            case .default(let presentation):
                // Fallback fonts require explicit presentation matching.
                return hasCodepoint(codepoint, fallback ? .explicit(presentation) : .any)
            case .explicit(let presentation):
                switch content {
                case .deferred(let face):
                    return face.hasCodepoint(codepoint, presentation)
                case .loaded(let face):
                    guard let glyph = face.glyphIndex(codepoint) else { return false }
                    return face.isColorGlyph(glyph) == (presentation == .emoji)
                }
            case .any:
                switch content {
                case .deferred(let face): return face.hasCodepoint(codepoint, nil)
                case .loaded(let face): return face.glyphIndex(codepoint) != nil
                }
            }
        }
    }

    /// The faces of each style. An entry may appear in several styles (an
    /// alias, such as a regular face standing in for a missing italic).
    private(set) var faces: [FontStyle: [Entry]] = Dictionary(uniqueKeysWithValues: FontStyle.allCases.map { ($0, []) })
    /// The size every face is loaded at, before its scale factor.
    let size: DesiredSize
    private(set) var metrics: Metrics?
    private var primaryFaceMetrics: Metrics.FaceMetrics?

    init(size: DesiredSize) {
        self.size = size
    }

    /// Adds a loaded face last in its style's priority order, resized to
    /// the collection's size.
    @discardableResult
    func add(_ face: Face, style: FontStyle, fallback: Bool, sizeAdjustment: SizeAdjustment) -> FontIndex {
        let factor = scaleFactor(face.metrics(), sizeAdjustment)
        let resized = face.resized(DesiredSize(points: size.points * factor, scale: size.scale))
        return append(Entry(.loaded(resized), fallback: fallback, scale: .factor(factor)), style)
    }

    @discardableResult
    func addDeferred(_ face: DeferredFace, style: FontStyle, fallback: Bool, sizeAdjustment: SizeAdjustment) -> FontIndex {
        append(Entry(.deferred(face), fallback: fallback, scale: .adjustment(sizeAdjustment)), style)
    }

    private func append(_ entry: Entry, _ style: FontStyle) -> FontIndex {
        faces[style, default: []].append(entry)
        return .face(style, faces[style]!.count - 1)
    }

    func entry(_ index: FontIndex) -> Entry? {
        guard case .face(let style, let position) = index, let list = faces[style], position < list.count else {
            return nil
        }
        return list[position]
    }

    /// The face for an index, loading it if it is deferred. Nil for the
    /// sprite font and invalid indexes.
    func face(_ index: FontIndex) -> Face? {
        entry(index).map(load)
    }

    private func load(_ entry: Entry) -> Face {
        switch entry.content {
        case .loaded(let face):
            return face
        case .deferred(let deferred):
            var face = deferred.load(size: size)
            if case .adjustment(let adjustment) = entry.scale {
                entry.scale = .factor(scaleFactor(face.metrics(), adjustment))
            }
            if case .factor(let factor) = entry.scale, factor != 1 {
                face = Face(copying: face.font, size: DesiredSize(points: size.points * factor, scale: size.scale))
            }
            entry.content = .loaded(face)
            return face
        }
    }

    /// The first face of the style that has the codepoint. Doesn't load
    /// deferred faces.
    func index(for codepoint: UInt32, style: FontStyle, _ mode: PresentationMode) -> FontIndex? {
        faces[style]?.firstIndex { $0.hasCodepoint(codepoint, mode) }.map { .face(style, $0) }
    }

    func hasCodepoint(_ index: FontIndex, _ codepoint: UInt32, _ mode: PresentationMode) -> Bool {
        entry(index)?.hasCodepoint(codepoint, mode) ?? false
    }

    /// Makes every style available, synthesizing italic and bold from the
    /// first regular face with text glyphs when a style has no face.
    func completeStyles() {
        guard FontStyle.allCases.contains(where: { faces[$0]!.isEmpty }) else { return }

        // The first regular face with text glyphs, which may not be the
        // first if a color (emoji) font comes first. A mixed font counts if
        // it has basic ASCII.
        guard let regular = faces[.regular]!.first(where: { entry in
            let face = load(entry)
            return !face.hasColor || face.glyphIndex(UInt32(("A" as Unicode.Scalar).value)) != nil
        }) else { return }

        let hadBold = !faces[.bold]!.isEmpty
        if faces[.italic]!.isEmpty {
            faces[.italic]!.append(Entry(.loaded(load(regular).syntheticItalic()), fallback: false))
        }
        if !hadBold {
            faces[.bold]!.append(Entry(.loaded(load(regular).makeSyntheticBold()), fallback: false))
        }
        if faces[.boldItalic]!.isEmpty {
            // Prefer italicizing a real bold; otherwise bolden the italic.
            if hadBold {
                faces[.boldItalic]!.append(Entry(.loaded(load(faces[.bold]![0]).syntheticItalic()), fallback: false))
            } else {
                faces[.boldItalic]!.append(Entry(.loaded(load(faces[.italic]![0]).makeSyntheticBold()), fallback: false))
            }
        }
    }

    /// The factor to scale a face by to match the primary face, per the
    /// adjustment. A metric the face doesn't define falls through to the
    /// next one (ic width, ex height, cap height, line height).
    private func scaleFactor(_ faceMetrics: Metrics.FaceMetrics, _ adjustment: SizeAdjustment) -> Double {
        if case .none = adjustment { return 1 }
        if primaryFaceMetrics == nil {
            guard let primary = face(.primary) else { return 1 }
            primaryFaceMetrics = primary.metrics()
        }
        let primary = primaryFaceMetrics!
        // Compare in ems, so the faces' actual sizes don't matter.
        let primaryScale = 1 / primary.pxPerEm
        let faceScale = 1 / faceMetrics.pxPerEm

        var adjustment = adjustment
        while true {
            switch adjustment {
            case .none:
                return 1
            case .icWidth:
                guard faceMetrics.icWidth == faceMetrics.resolvedIcWidth else { adjustment = .exHeight; continue }
                return (primary.resolvedIcWidth * primaryScale) / (faceMetrics.resolvedIcWidth * faceScale)
            case .exHeight:
                guard faceMetrics.exHeight == faceMetrics.resolvedExHeight else { adjustment = .capHeight; continue }
                return (primary.resolvedExHeight * primaryScale) / (faceMetrics.resolvedExHeight * faceScale)
            case .capHeight:
                guard faceMetrics.capHeight == faceMetrics.resolvedCapHeight else { adjustment = .lineHeight; continue }
                return (primary.resolvedCapHeight * primaryScale) / (faceMetrics.resolvedCapHeight * faceScale)
            case .lineHeight:
                return (primary.lineHeight * primaryScale) / (faceMetrics.lineHeight * faceScale)
            }
        }
    }

    /// Computes the grid metrics from the primary face.
    func updateMetrics() {
        guard let primary = face(.primary) else { return }
        primaryFaceMetrics = primary.metrics()
        metrics = Metrics(face: primaryFaceMetrics!)
    }
}
