// Ported from ghostty src/font/sprite/draw/common.zig @ 81598385d608dda4946093d6d6a234d204a2f225
// Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors. MIT License.

import Foundation

enum Thickness {
    case superLight
    case light
    case heavy

    /// The line height in pixels for a base thickness in pixels.
    func height(_ base: UInt32) -> Int {
        switch self {
        case .superLight: Int(max(base / 2, 1))
        case .light: Int(base)
        case .heavy: Int(base * 2)
        }
    }
}

enum Shade: UInt8 {
    case off = 0x00
    case light = 0x40
    case medium = 0x80
    case dark = 0xc0
    case on = 0xff

    var color: Canvas.Color { Canvas.Color(rawValue: rawValue) }
}

/// Which quadrants of a cell a figure covers.
struct Quads: OptionSet {
    let rawValue: UInt8
    static let tl = Quads(rawValue: 1 << 0)
    static let tr = Quads(rawValue: 1 << 1)
    static let bl = Quads(rawValue: 1 << 2)
    static let br = Quads(rawValue: 1 << 3)
}

enum Corner {
    case tl, tr, bl, br
}

/// Where a figure sits in its cell.
struct Alignment {
    enum Horizontal { case left, right, center }
    enum Vertical { case top, bottom, middle }

    var horizontal: Horizontal = .center
    var vertical: Vertical = .middle

    static let upper = Alignment(vertical: .top)
    static let lower = Alignment(vertical: .bottom)
    static let left = Alignment(horizontal: .left)
    static let right = Alignment(horizontal: .right)
    static let center = Alignment()
}

/// A fraction of the way across the cell.
struct Fraction {
    let value: Double

    static let zero = Fraction(value: 0)
    static let quarter = Fraction(value: 0.25)
    static let half = Fraction(value: 0.5)
    static let full = Fraction(value: 1)

    static let halves = (0...2).map { Fraction(value: Double($0) / 2) }

    /// The position as a block's min (left/top) coordinate. It aligns with
    /// the complementary fraction from the end so rounding evens out: for
    /// size 7, start→half and half→end are both 4px (0→4 and 3→7).
    func min(_ size: UInt32) -> Int {
        let s = Double(size)
        return Int(s - ((1 - value) * s).rounded())
    }

    /// The position as a block's max (right/bottom) coordinate.
    func max(_ size: UInt32) -> Int {
        Int((value * Double(size)).rounded())
    }
}

enum Draw {
    /// Fills the part of the cell between two fraction lines on each axis.
    static func fill(_ metrics: Metrics, _ canvas: Canvas, _ x0: Fraction, _ x1: Fraction, _ y0: Fraction, _ y1: Fraction) {
        canvas.box(x0.min(metrics.cellWidth), y0.min(metrics.cellHeight),
                   x1.max(metrics.cellWidth), y1.max(metrics.cellHeight), .on)
    }

    /// A centered vertical line.
    static func vlineMiddle(_ metrics: Metrics, _ canvas: Canvas, _ thickness: Thickness) {
        let thick = thickness.height(metrics.boxThickness)
        vline(canvas, 0, Int(metrics.cellHeight), Swift.max(0, Int(metrics.cellWidth) - thick) / 2, thick)
    }

    /// A centered horizontal line.
    static func hlineMiddle(_ metrics: Metrics, _ canvas: Canvas, _ thickness: Thickness) {
        let thick = thickness.height(metrics.boxThickness)
        hline(canvas, 0, Int(metrics.cellWidth), Swift.max(0, Int(metrics.cellHeight) - thick) / 2, thick)
    }

    /// A vertical line with its left edge at `x`, from `y1` to `y2`.
    static func vline(_ canvas: Canvas, _ y1: Int, _ y2: Int, _ x: Int, _ thickness: Int) {
        canvas.box(x, y1, x + thickness, y2, .on)
    }

    /// A horizontal line with its top edge at `y`, from `x1` to `x2`.
    static func hline(_ canvas: Canvas, _ x1: Int, _ x2: Int, _ y: Int, _ thickness: Int) {
        canvas.box(x1, y, x2, y + thickness, .on)
    }
}
