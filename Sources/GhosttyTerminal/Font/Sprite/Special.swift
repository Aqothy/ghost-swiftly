// Ported from ghostty src/font/sprite/draw/special.zig @ 81598385d608dda4946093d6d6a234d204a2f225
// Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors. MIT License.

import CoreGraphics
import Foundation

/// Glyphs outside Unicode that the renderer itself draws: decorations and
/// cursors. Their codepoints start just above the Unicode range.
enum Sprite: UInt32, CaseIterable {
    case underline = 0x20_0000
    case underlineDouble
    case underlineDotted
    case underlineDashed
    case underlineCurly
    case strikethrough
    case overline
    case cursorRect
    case cursorHollowRect
    case cursorBar
    case cursorUnderline

    func draw(_ canvas: Canvas, width: Int, height: Int, metrics: Metrics) {
        let underlinePosition = Int(metrics.underlinePosition)
        let underlineThickness = Int(metrics.underlineThickness)
        switch self {
        case .underline:
            // Never past the bottom of the canvas, a quarter cell below the cell.
            let y = min(underlinePosition, height + canvas.paddingY - underlineThickness)
            canvas.rect(x: 0, y: y, width: width, height: underlineThickness, .on)

        case .underlineDouble:
            // One line above the single underline position and one below,
            // a "negative" underline where the single one would be.
            let y = min(underlinePosition, height + canvas.paddingY - 2 * underlineThickness)
            canvas.rect(x: 0, y: max(0, y - underlineThickness), width: width, height: underlineThickness, .on)
            canvas.rect(x: 0, y: y + underlineThickness, width: width, height: underlineThickness, .on)

        case .underlineDotted:
            let floatWidth = Double(width)
            let thickness = Double(underlineThickness)
            // √2 × the thickness, since otherwise dots look anemic.
            let radius = 0.5.squareRoot() * thickness
            let y = min(Double(underlinePosition) + 0.5 * thickness,
                        Double(height) + Double(canvas.paddingY) - radius.rounded(.up))
            // Space between dots about their diameter, at least their radius
            // and one pixel, and at least one dot per cell.
            let dotCount = max(
                min((floatWidth / (4 * radius)).rounded(.up),
                    (floatWidth / (3 * radius)).rounded(.down),
                    (floatWidth / (2 * radius + 1)).rounded(.down)),
                1)
            let path = CGMutablePath()
            var x = (floatWidth / dotCount) / 2
            for _ in 0..<Int(dotCount) {
                path.addArc(center: CGPoint(x: x, y: y), radius: radius, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
                path.closeSubpath()
                x += floatWidth / dotCount
            }
            canvas.fill(path)

        case .underlineDashed:
            let y = min(underlinePosition, height + canvas.paddingY - underlineThickness)
            let dashWidth = width / 3 + 1
            let dashCount = width / dashWidth + 1
            for index in stride(from: 0, to: dashCount, by: 2) {
                canvas.rect(x: index * dashWidth, y: y, width: dashWidth, height: underlineThickness, .on)
            }

        case .underlineCurly:
            let floatWidth = Double(width)
            let lineWidth = Double(underlineThickness)
            let amplitude = floatWidth / .pi
            // Never past the bottom of the canvas, for fonts with bad
            // metadata.
            let top = min(Double(underlinePosition),
                          Double(height) + Double(canvas.paddingY) - amplitude - lineWidth)
            let bottom = top + amplitude
            // Curvature: 0.4 makes a smooth wiggle.
            let r = 0.4
            let center = 0.5 * floatWidth
            // One cycle of a wave peaking at the center of the cell.
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 0, y: bottom))
            path.addCurve(to: CGPoint(x: center, y: top),
                          control1: CGPoint(x: center * r, y: bottom),
                          control2: CGPoint(x: center - center * r, y: top))
            path.addCurve(to: CGPoint(x: floatWidth, y: bottom),
                          control1: CGPoint(x: center + center * r, y: top),
                          control2: CGPoint(x: floatWidth - center * r, y: bottom))
            // Round caps overlap neighbors invisibly but look cleaner at the ends.
            canvas.stroke(path, lineWidth: lineWidth, lineCap: .round)

        case .strikethrough:
            canvas.rect(x: 0, y: Int(metrics.strikethroughPosition), width: width,
                        height: Int(metrics.strikethroughThickness), .on)

        case .overline:
            // Never above the canvas, a quarter cell above the cell.
            let y = max(Int(metrics.overlinePosition), -canvas.paddingY)
            canvas.rect(x: 0, y: y, width: width, height: Int(metrics.overlineThickness), .on)

        case .cursorRect:
            canvas.rect(x: 0, y: 0, width: width, height: height, .on)

        case .cursorHollowRect:
            let thickness = Int(metrics.cursorThickness)
            canvas.rect(x: 0, y: 0, width: width, height: height, .on)
            canvas.rect(x: thickness, y: thickness, width: max(0, width - thickness * 2),
                        height: max(0, height - thickness * 2), .off)

        case .cursorBar:
            // Centered on the cell's left edge, rounding a 1px bar to the left.
            let thickness = Int(metrics.cursorThickness)
            canvas.rect(x: -((thickness + 1) / 2), y: 0, width: thickness, height: height, .on)

        case .cursorUnderline:
            let y = min(underlinePosition, height + canvas.paddingY - underlineThickness)
            canvas.rect(x: 0, y: y, width: width, height: Int(metrics.cursorThickness), .on)
        }
    }
}
