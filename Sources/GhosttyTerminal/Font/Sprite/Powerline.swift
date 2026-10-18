// Ported from ghostty src/font/sprite/draw/powerline.zig @ 81598385d608dda4946093d6d6a234d204a2f225
// Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors. MIT License.
//
// The geometric Powerline and Powerline Extra glyphs, U+E0B0...U+E0D4.

import CoreGraphics
import Foundation

extension Draw {
    static let powerlineCodepoints: Set<UInt32> = [
        0xE0B0, 0xE0B1, 0xE0B2, 0xE0B3, 0xE0B4, 0xE0B5, 0xE0B6, 0xE0B7, 0xE0B8, 0xE0B9, 0xE0BA, 0xE0BB,
        0xE0BC, 0xE0BD, 0xE0BE, 0xE0BF, 0xE0D2, 0xE0D4,
    ]

    static func powerline(_ cp: UInt32, _ canvas: Canvas, width: Int, height: Int, _ metrics: Metrics) {
        let w = Double(width)
        let h = Double(height)
        switch cp {
        case 0xE0B0:
            canvas.triangle(CGPoint(x: 0, y: 0), CGPoint(x: w, y: h / 2), CGPoint(x: 0, y: h))
        case 0xE0B2:
            canvas.triangle(CGPoint(x: w, y: 0), CGPoint(x: 0, y: h / 2), CGPoint(x: w, y: h))
        case 0xE0B8:
            canvas.triangle(CGPoint(x: 0, y: 0), CGPoint(x: w, y: h), CGPoint(x: 0, y: h))
        case 0xE0BA:
            canvas.triangle(CGPoint(x: w, y: 0), CGPoint(x: w, y: h), CGPoint(x: 0, y: h))
        case 0xE0BC:
            canvas.triangle(CGPoint(x: 0, y: 0), CGPoint(x: w, y: 0), CGPoint(x: 0, y: h))
        case 0xE0BE:
            canvas.triangle(CGPoint(x: 0, y: 0), CGPoint(x: w, y: 0), CGPoint(x: w, y: h))
        case 0xE0B9, 0xE0BF:
            lightDiagonalUpperLeftToLowerRight(metrics, canvas)
        case 0xE0BB, 0xE0BD:
            lightDiagonalUpperRightToLowerLeft(metrics, canvas)
        case 0xE0B1:
            chevron(canvas, w, h, metrics)
        case 0xE0B3:
            chevron(canvas, w, h, metrics)
            canvas.flipHorizontal()
        case 0xE0B4:
            halfCircle(canvas, w, h)
        case 0xE0B6:
            halfCircle(canvas, w, h)
            canvas.flipHorizontal()
        case 0xE0B5:
            halfCircleOutline(canvas, w, h, metrics)
        case 0xE0B7:
            halfCircleOutline(canvas, w, h, metrics)
            canvas.flipHorizontal()
        case 0xE0D2:
            notchedBlock(canvas, w, h, metrics)
        case 0xE0D4:
            notchedBlock(canvas, w, h, metrics)
            canvas.flipHorizontal()
        default:
            break
        }
    }

    private static func chevron(_ canvas: Canvas, _ w: Double, _ h: Double, _ metrics: Metrics) {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: w, y: h / 2))
        path.addLine(to: CGPoint(x: 0, y: h))
        canvas.stroke(path, lineWidth: Double(Thickness.light.height(metrics.boxThickness)))
    }

    /// Bézier coefficient approximating a circular arc.
    private static let arcCoefficient = (2.0.squareRoot() - 1) * 4 / 3

    private static func halfCirclePath(_ w: Double, _ h: Double, inset: Double) -> CGMutablePath {
        let c = arcCoefficient
        let radius = min(w, h / 2)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: 0))
        if inset > 0 { path.addLine(to: CGPoint(x: inset, y: 0)) }
        path.addCurve(to: CGPoint(x: radius, y: radius),
                      control1: CGPoint(x: radius * c, y: 0),
                      control2: CGPoint(x: radius, y: radius - radius * c))
        path.addLine(to: CGPoint(x: radius, y: h - radius))
        path.addCurve(to: CGPoint(x: inset, y: h),
                      control1: CGPoint(x: radius, y: h - radius + radius * c),
                      control2: CGPoint(x: radius * c, y: h))
        if inset > 0 { path.addLine(to: CGPoint(x: 0, y: h)) }
        return path
    }

    private static func halfCircle(_ canvas: Canvas, _ w: Double, _ h: Double) {
        let path = halfCirclePath(w, h, inset: 0)
        path.closeSubpath()
        canvas.fill(path)
    }

    /// Ghostty strokes the outline inset by half the line width (z2d path
    /// offset). Stroking at twice the width clipped to the filled shape
    /// gives the same band inside the edge.
    private static func halfCircleOutline(_ canvas: Canvas, _ w: Double, _ h: Double, _ metrics: Metrics) {
        // The horizontal lead-in/out keeps both ends butt-capped
        // perpendicular to the cell edge.
        let outline = halfCirclePath(w, h, inset: 1)
        let interior = halfCirclePath(w, h, inset: 1)
        interior.closeSubpath()
        let lineWidth = Double(metrics.boxThickness)
        canvas.draw { context in
            context.addPath(interior)
            context.clip()
            context.setLineWidth(lineWidth * 2)
            context.setLineCap(.butt)
            context.addPath(outline)
            context.strokePath()
        }
    }

    private static func notchedBlock(_ canvas: Canvas, _ w: Double, _ h: Double, _ metrics: Metrics) {
        let thick = Double(metrics.boxThickness)
        let top = CGMutablePath()
        top.addLines(between: [
            CGPoint(x: 0, y: 0), CGPoint(x: w, y: 0), CGPoint(x: w / 2, y: h / 2 - thick / 2),
            CGPoint(x: 0, y: h / 2 - thick / 2),
        ])
        top.closeSubpath()
        canvas.fill(top)
        let bottom = CGMutablePath()
        bottom.addLines(between: [
            CGPoint(x: 0, y: h), CGPoint(x: w, y: h), CGPoint(x: w / 2, y: h / 2 + thick / 2),
            CGPoint(x: 0, y: h / 2 + thick / 2),
        ])
        bottom.closeSubpath()
        canvas.fill(bottom)
    }
}
