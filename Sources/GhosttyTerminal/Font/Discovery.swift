// Ported from ghostty src/font/discovery.zig @ 81598385d608dda4946093d6d6a234d204a2f225
// Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors. MIT License.
//
// The CoreText discoverer only.

import CoreText
import Foundation

/// What to search for.
struct FontDescriptor {
    var family: String?
    /// A style name to match, such as "Bold Italic".
    var style: String?
    /// A codepoint the font must have.
    var codepoint: UInt32 = 0
    /// Points.
    var size: Double = 0
    var bold = false
    var italic = false
    var monospace = false
    var variations: [Variation] = []

    func coreTextDescriptor() -> CTFontDescriptor {
        var attributes: [CFString: Any] = [:]
        if let family { attributes[kCTFontFamilyNameAttribute] = family }
        if let style { attributes[kCTFontStyleNameAttribute] = style }
        if codepoint > 0 {
            attributes[kCTFontCharacterSetAttribute] = CharacterSet(
                charactersIn: Unicode.Scalar(codepoint).map { String(Character($0)) } ?? "")
        }
        if size > 0 { attributes[kCTFontSizeAttribute] = Int32(size.rounded()) }
        var traits: CTFontSymbolicTraits = []
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        if monospace { traits.insert(.traitMonoSpace) }
        if !traits.isEmpty {
            attributes[kCTFontTraitsAttribute] = [kCTFontSymbolicTrait: traits.rawValue]
        }
        return CTFontDescriptorCreateWithAttributes(attributes as CFDictionary)
    }
}

enum Discovery {
    /// Fonts matching the descriptor, best first.
    static func discover(_ descriptor: FontDescriptor) -> [DeferredFace] {
        let collection = CTFontCollectionCreateWithFontDescriptors([descriptor.coreTextDescriptor()] as CFArray, nil)
        let matches = (CTFontCollectionCreateMatchingFontDescriptors(collection) as? [CTFontDescriptor]) ?? []
        return sorted(matches, for: descriptor).map { deferred($0, descriptor.variations) }
    }

    /// A font by its exact family, full or PostScript name, without the
    /// system-wide matching `discover` does. Nil when it isn't installed:
    /// CTFontCreateWithName substitutes a font instead of failing.
    static func discoverExactFamily(_ family: String) -> DeferredFace? {
        let font = CTFontCreateWithName(family as CFString, 12, nil)
        guard CTFontCopyFamilyName(font) as String == family else { return nil }
        return DeferredFace(font: font, variations: [])
    }

    /// Fonts that can stand in for a codepoint the collection doesn't have.
    static func discoverFallback(_ collection: Collection, _ descriptor: FontDescriptor) -> [DeferredFace] {
        // For CJK Unified Ideographs, only CoreText's own fallback takes the
        // system locale into account (Blink's LocaleInFonts.md).
        if (0x4E00...0x9FFF).contains(descriptor.codepoint),
           let han = discoverCodepoint(collection, descriptor) {
            return [deferred(han, descriptor.variations)]
        }
        let found = discover(descriptor)
        // When matching finds nothing, ask CoreText which font it would use
        // for the codepoint (ghostty#2499).
        if found.isEmpty, descriptor.codepoint > 0, let font = discoverCodepoint(collection, descriptor) {
            return [deferred(font, descriptor.variations)]
        }
        return found
    }

    /// CoreText's own pick for a codepoint, via CTFontCreateForString on the
    /// collection's face of the requested style.
    private static func discoverCodepoint(_ collection: Collection, _ descriptor: FontDescriptor) -> CTFontDescriptor? {
        let style: FontStyle = if descriptor.bold, descriptor.italic, !collection.faces[.boldItalic]!.isEmpty {
            .boldItalic
        } else if descriptor.bold, !collection.faces[.bold]!.isEmpty {
            .bold
        } else if descriptor.italic, !collection.faces[.italic]!.isEmpty {
            .italic
        } else {
            .regular
        }
        guard let original = collection.face(.face(style, 0)),
              let scalar = Unicode.Scalar(descriptor.codepoint) else { return nil }
        let string = String(Character(scalar))
        let font = CTFontCreateForString(original.font, string as CFString, CFRange(location: 0, length: string.utf16.count))
        // LastResort only has replacement glyphs.
        if CTFontCopyPostScriptName(font) as String == "LastResort" { return nil }
        return CTFontCopyFontDescriptor(font)
    }

    private static func deferred(_ descriptor: CTFontDescriptor, _ variations: [Variation]) -> DeferredFace {
        // The character set narrowed the search; it must not narrow the font.
        let copy = CTFontDescriptorCreateCopyWithAttributes(
            descriptor, [kCTFontCharacterSetAttribute: kCFNull] as CFDictionary)
        return DeferredFace(font: CTFontCreateWithFontDescriptor(copy, 12, nil), variations: variations)
    }

    private static func sorted(_ descriptors: [CTFontDescriptor], for wanted: FontDescriptor) -> [CTFontDescriptor] {
        descriptors.map { (score(wanted, $0), $0) }.sorted { $0.0 > $1.0 }.map(\.1)
    }

    /// Ranks a candidate; fields compare in order of precedence: codepoint,
    /// monospace, exact style, italic, bold, fuzzy style, glyph count.
    private struct Score: Comparable {
        var codepoint = false
        var monospace = false
        var exactStyle = false
        var italic = false
        var bold = false
        var fuzzyStyle: UInt8 = 0
        var glyphCount: UInt16 = 0

        /// Packed most significant first, like Ghostty's packed struct.
        private var key: UInt64 {
            func bit(_ value: Bool, _ shift: UInt64) -> UInt64 { value ? 1 << shift : 0 }
            return bit(codepoint, 28) | bit(monospace, 27) | bit(exactStyle, 26) | bit(italic, 25)
                | bit(bold, 24) | UInt64(fuzzyStyle) << 16 | UInt64(glyphCount)
        }

        static func < (lhs: Score, rhs: Score) -> Bool { lhs.key < rhs.key }
        static func == (lhs: Score, rhs: Score) -> Bool { lhs.key == rhs.key }
    }

    private static func score(_ wanted: FontDescriptor, _ candidate: CTFontDescriptor) -> Score {
        var score = Score()
        // Fonts that can't load score zero.
        let font = CTFontCreateWithFontDescriptor(candidate, 12, nil)
        score.glyphCount = UInt16(clamping: CTFontGetGlyphCount(font))
        if wanted.codepoint > 0 {
            score.codepoint = Face.glyph(in: font, for: wanted.codepoint) != nil
        }

        let traitsDictionary = CTFontDescriptorCopyAttribute(candidate, kCTFontTraitsAttribute) as? [CFString: Any]
        let symbolic = CTFontSymbolicTraits(rawValue: (traitsDictionary?[kCTFontSymbolicTrait] as? UInt32) ?? 0)
        score.monospace = symbolic.contains(.traitMonoSpace)

        // The font's own tables are more reliable than its symbolic traits.
        var isItalic = symbolic.contains(.traitItalic)
        var isBold = symbolic.contains(.traitBold)
        if let head = Face.table("head", in: font).flatMap(OpenType.Head.init) {
            isBold = isBold || head.macStyle & 1 == 1
            isItalic = isItalic || head.macStyle & 2 == 2
        }
        if let os2 = Face.table("OS/2", in: font).flatMap(OpenType.OS2.init) {
            isBold = isBold || os2.fsSelection.contains(.bold)
            isItalic = isItalic || os2.fsSelection.contains(.italic)
        }
        if let axes = CTFontCopyVariationAxes(font) as? [[CFString: Any]],
           let values = CTFontCopyVariation(font) as? [NSNumber: NSNumber] {
            // An 'ital' axis overrides 'slnt'.
            var italSeen = false
            for axis in axes {
                guard let identifier = axis[kCTFontVariationAxisIdentifierKey] as? NSNumber,
                      let name = axis[kCTFontVariationAxisNameKey] as? String else { continue }
                let defaultValue = (axis[kCTFontVariationAxisDefaultValueKey] as? NSNumber)?.doubleValue ?? 0
                let value = values[identifier]?.doubleValue ?? defaultValue
                switch name {
                case "wght":
                    // Somewhat subjective: bold above 600.
                    isBold = value > 600
                case "ital":
                    isItalic = value > 0.5
                    italSeen = true
                case "slnt" where !italSeen:
                    // More than 5° clockwise is italic.
                    isItalic = value <= -5
                default:
                    break
                }
            }
        }
        score.bold = wanted.bold == isBold
        score.italic = wanted.italic == isItalic

        let styleName = (CTFontDescriptorCopyAttribute(candidate, kCTFontStyleNameAttribute) as? String) ?? ""
        // The first is the exact match; every one found improves the fuzzy score.
        let desired: [String] = if let style = wanted.style {
            [style]
        } else if wanted.bold {
            wanted.italic ? ["bold italic", "bold", "italic", "oblique"] : ["bold", "upright"]
        } else if wanted.italic {
            ["italic", "regular", "oblique"]
        } else {
            ["regular", "upright"]
        }
        score.exactStyle = styleName.caseInsensitiveCompare(desired[0]) == .orderedSame
        // Zero if no desired style is present; higher for fewer characters
        // outside the desired styles.
        var unmatched = min(styleName.utf8.count, Int(UInt8.max))
        for style in desired where styleName.range(of: style, options: .caseInsensitive) != nil {
            unmatched = max(0, unmatched - style.utf8.count)
        }
        score.fuzzyStyle = UInt8.max - UInt8(unmatched)
        return score
    }
}
