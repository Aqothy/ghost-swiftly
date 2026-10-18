// Ported from ghostty src/font/sprite/draw/braille.zig @ 81598385d608dda4946093d6d6a234d204a2f225
// Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors. MIT License.
//
// Braille Patterns, U+2800...U+28FF.

import Foundation

extension Draw {
    static func braille(_ cp: UInt32, _ canvas: Canvas, width: Int, height: Int) {
        var w = min(width / 4, height / 8)
        var xSpacing = width / 4
        var ySpacing = height / 8
        var xMargin = xSpacing / 2
        var yMargin = ySpacing / 2
        var xLeft = width - 2 * xMargin - xSpacing - 2 * w
        var yLeft = height - 2 * yMargin - 3 * ySpacing - 4 * w

        // First, try hard to make the dot width nonzero.
        if xLeft >= 2, yLeft >= 4, w == 0 {
            w += 1
            xLeft -= 2
            yLeft -= 4
        }
        // Second, prefer a nonzero margin.
        if xLeft >= 2, xMargin == 0 {
            xMargin = 1
            xLeft -= 2
        }
        if yLeft >= 2, yMargin == 0 {
            yMargin = 1
            yLeft -= 2
        }
        // Third, increase spacing.
        if xLeft >= 1 {
            xSpacing += 1
            xLeft -= 1
        }
        if yLeft >= 3 {
            ySpacing += 1
            yLeft -= 3
        }
        // Fourth, margins (spacing on the sides).
        if xLeft >= 2 {
            xMargin += 1
            xLeft -= 2
        }
        if yLeft >= 2 {
            yMargin += 1
            yLeft -= 2
        }
        // Last, a wider dot.
        if xLeft >= 2, yLeft >= 4 {
            w += 1
        }

        let x = [xMargin, xMargin + w + xSpacing]
        var y = [yMargin]
        for _ in 1..<4 { y.append(y.last! + w + ySpacing) }

        // The codepoint's low byte is the dot pattern: tl ul ll tr ur lr bl br.
        let pattern = UInt8(truncatingIfNeeded: cp)
        let dots: [(bit: UInt8, column: Int, row: Int)] = [
            (0, 0, 0), (1, 0, 1), (2, 0, 2), (6, 0, 3),
            (3, 1, 0), (4, 1, 1), (5, 1, 2), (7, 1, 3),
        ]
        for dot in dots where pattern & (1 << dot.bit) != 0 {
            canvas.box(x[dot.column], y[dot.row], x[dot.column] + w, y[dot.row] + w, .on)
        }
    }
}
