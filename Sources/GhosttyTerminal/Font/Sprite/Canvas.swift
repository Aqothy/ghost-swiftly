// Ported from ghostty src/font/sprite/canvas.zig @ 81598385d608dda4946093d6d6a234d204a2f225
// Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors. MIT License.
//
// Ghostty draws sprites with z2d; this draws the same paths with
// CoreGraphics into an alpha-only bitmap with the same top-left origin.

import CoreGraphics
import Foundation

/// An alpha-only drawing surface for one sprite glyph, with padding around
/// the cell so decorations can reach slightly outside it.
final class Canvas {
    /// A pixel's coverage: on, off, or a shade between.
    struct Color: Equatable {
        let rawValue: UInt8

        static let on = Color(rawValue: 255)
        static let off = Color(rawValue: 0)
    }

    let width: Int
    let height: Int
    let paddingX: Int
    let paddingY: Int
    var clipTop = 0
    var clipLeft = 0
    var clipRight = 0
    var clipBottom = 0
    /// Rows top to bottom, including padding.
    private(set) var pixels: [UInt8]

    /// `width` and `height` are the cell's; the surface adds the padding on
    /// both sides.
    init(width: Int, height: Int, paddingX: Int, paddingY: Int) {
        self.width = width + 2 * paddingX
        self.height = height + 2 * paddingY
        self.paddingX = paddingX
        self.paddingY = paddingY
        pixels = [UInt8](repeating: 0, count: self.width * self.height)
    }

    /// Writes the drawing, trimmed of fully transparent edges, to the atlas.
    func writeAtlas(_ atlas: Atlas) throws(Atlas.Full) -> Atlas.Region {
        precondition(atlas.format == .grayscale)
        trim()
        let regionWidth = max(0, width - clipLeft - clipRight)
        let regionHeight = max(0, height - clipTop - clipBottom)
        let region = try atlas.reserve(width: UInt32(regionWidth), height: UInt32(regionHeight))
        if regionWidth > 0, regionHeight > 0 {
            var trimmed = [UInt8](repeating: 0, count: regionWidth * regionHeight)
            for row in 0..<regionHeight {
                let source = (clipTop + row) * width + clipLeft
                trimmed[(row * regionWidth)..<((row + 1) * regionWidth)] = pixels[source..<(source + regionWidth)]
            }
            trimmed.withUnsafeBytes { atlas.set(region, $0) }
        }
        return region
    }

    /// Moves the clip edges past fully transparent rows and columns.
    private func trim() {
        func rowEmpty(_ y: Int) -> Bool {
            pixels[(y * width + clipLeft)..<(y * width + width - clipRight)].allSatisfy { $0 == 0 }
        }
        func columnEmpty(_ x: Int) -> Bool {
            (clipTop..<(height - clipBottom)).allSatisfy { pixels[$0 * width + x] == 0 }
        }
        while clipTop < height - clipBottom, rowEmpty(clipTop) { clipTop += 1 }
        while clipBottom < height - clipTop, rowEmpty(height - clipBottom - 1) { clipBottom += 1 }
        while clipLeft < width - clipRight, columnEmpty(clipLeft) { clipLeft += 1 }
        while clipRight < width - clipLeft, columnEmpty(width - clipRight - 1) { clipRight += 1 }
    }

    /// Sets one pixel, in cell coordinates.
    func pixel(_ x: Int, _ y: Int, _ color: Color) {
        let px = x + paddingX
        let py = y + paddingY
        guard px >= 0, px < width, py >= 0, py < height else { return }
        pixels[py * width + px] = color.rawValue
    }

    /// Fills a rectangle of whole pixels; the main primitive for lines too.
    func rect(x: Int, y: Int, width w: Int, height h: Int, _ color: Color) {
        guard w > 0, h > 0 else { return }
        for py in y..<(y + h) {
            for px in x..<(x + w) {
                pixel(px, py, color)
            }
        }
    }

    /// Fills the box between two corners (exclusive of the far edges).
    func box(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, _ color: Color) {
        rect(x: min(x0, x1), y: min(y0, y1), width: abs(x1 - x0), height: abs(y1 - y0), color)
    }

    /// Draws with CoreGraphics in cell coordinates (y down, padding applied).
    func draw(_ body: (CGContext) -> Void) {
        let width = self.width
        let height = self.height
        let paddingX = self.paddingX
        let paddingY = self.paddingY
        pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue)
            else { return }
            // Top-left origin, offset by the padding.
            context.translateBy(x: CGFloat(paddingX), y: CGFloat(height - paddingY))
            context.scaleBy(x: 1, y: -1)
            context.setShouldAntialias(true)
            context.setAllowsAntialiasing(true)
            context.setFillColor(gray: 0, alpha: 1)
            context.setStrokeColor(gray: 0, alpha: 1)
            body(context)
        }
    }

    func fill(_ path: CGPath, _ color: Color = .on) {
        draw { context in
            context.setBlendMode(color == .on ? .normal : .clear)
            context.addPath(path)
            context.fillPath(using: .winding)
        }
    }

    func stroke(_ path: CGPath, lineWidth: Double, lineCap: CGLineCap = .butt, _ color: Color = .on) {
        draw { context in
            context.setBlendMode(color == .on ? .normal : .clear)
            context.setLineWidth(lineWidth)
            context.setLineCap(lineCap)
            context.addPath(path)
            context.strokePath()
        }
    }

    func quad(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint, _ color: Color = .on) {
        let path = CGMutablePath()
        path.addLines(between: [p0, p1, p2, p3])
        path.closeSubpath()
        fill(path, color)
    }

    func triangle(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ color: Color = .on) {
        let path = CGMutablePath()
        path.addLines(between: [p0, p1, p2])
        path.closeSubpath()
        fill(path, color)
    }

    func line(_ p0: CGPoint, _ p1: CGPoint, thickness: Double, _ color: Color = .on) {
        let path = CGMutablePath()
        path.move(to: p0)
        path.addLine(to: p1)
        stroke(path, lineWidth: thickness, color)
    }

    func invert() {
        for index in pixels.indices { pixels[index] = 255 - pixels[index] }
    }

    func flipHorizontal() {
        let clone = pixels
        for y in 0..<height {
            for x in 0..<width {
                pixels[y * width + x] = clone[y * width + width - x - 1]
            }
        }
        swap(&clipLeft, &clipRight)
    }

    func flipVertical() {
        let clone = pixels
        for y in 0..<height {
            for x in 0..<width {
                pixels[y * width + x] = clone[(height - y - 1) * width + x]
            }
        }
        swap(&clipTop, &clipBottom)
    }
}
