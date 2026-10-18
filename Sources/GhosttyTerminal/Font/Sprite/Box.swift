// Ported from ghostty src/font/sprite/draw/box.zig @ 81598385d608dda4946093d6d6a234d204a2f225
// Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors. MIT License.
//
// Box Drawing, U+2500...U+257F.

import CoreGraphics
import Foundation

/// The line style from each edge of a box-drawing character to its center.
struct Lines {
    enum Style { case none, light, heavy, double }

    var up: Style = .none
    var right: Style = .none
    var down: Style = .none
    var left: Style = .none
}

extension Draw {
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    static func boxDrawing(_ cp: UInt32, _ canvas: Canvas, _ metrics: Metrics) {
        let light = Thickness.light.height(metrics.boxThickness)
        let heavy = Thickness.heavy.height(metrics.boxThickness)
        switch cp {
        case 0x2500: linesChar(metrics, canvas, Lines(right: .light, left: .light))
        case 0x2501: linesChar(metrics, canvas, Lines(right: .heavy, left: .heavy))
        case 0x2502: linesChar(metrics, canvas, Lines(up: .light, down: .light))
        case 0x2503: linesChar(metrics, canvas, Lines(up: .heavy, down: .heavy))
        case 0x2504: dashHorizontal(metrics, canvas, 3, light, max(4, light))
        case 0x2505: dashHorizontal(metrics, canvas, 3, heavy, max(4, light))
        case 0x2506: dashVertical(metrics, canvas, 3, light, max(4, light))
        case 0x2507: dashVertical(metrics, canvas, 3, heavy, max(4, light))
        case 0x2508: dashHorizontal(metrics, canvas, 4, light, max(4, light))
        case 0x2509: dashHorizontal(metrics, canvas, 4, heavy, max(4, light))
        case 0x250a: dashVertical(metrics, canvas, 4, light, max(4, light))
        case 0x250b: dashVertical(metrics, canvas, 4, heavy, max(4, light))
        case 0x254c: dashHorizontal(metrics, canvas, 2, light, light)
        case 0x254d: dashHorizontal(metrics, canvas, 2, heavy, heavy)
        case 0x254e: dashVertical(metrics, canvas, 2, light, heavy)
        case 0x254f: dashVertical(metrics, canvas, 2, heavy, heavy)
        case 0x256d: arc(metrics, canvas, .br, .light)
        case 0x256e: arc(metrics, canvas, .bl, .light)
        case 0x256f: arc(metrics, canvas, .tl, .light)
        case 0x2570: arc(metrics, canvas, .tr, .light)
        case 0x2571: lightDiagonalUpperRightToLowerLeft(metrics, canvas)
        case 0x2572: lightDiagonalUpperLeftToLowerRight(metrics, canvas)
        case 0x2573:
            lightDiagonalUpperRightToLowerLeft(metrics, canvas)
            lightDiagonalUpperLeftToLowerRight(metrics, canvas)
        default:
            if let lines = boxLines[cp] { linesChar(metrics, canvas, lines) }
        }
    }

    /// The intersection-style characters, by codepoint.
    private static let boxLines: [UInt32: Lines] = {
        let l = Lines.Style.light, h = Lines.Style.heavy, d = Lines.Style.double
        func lines(up: Lines.Style = .none, right: Lines.Style = .none, down: Lines.Style = .none,
                   left: Lines.Style = .none) -> Lines {
            Lines(up: up, right: right, down: down, left: left)
        }
        return [
            0x250c: lines(right: l, down: l), 0x250d: lines(right: h, down: l),
            0x250e: lines(right: l, down: h), 0x250f: lines(right: h, down: h),
            0x2510: lines(down: l, left: l), 0x2511: lines(down: l, left: h),
            0x2512: lines(down: h, left: l), 0x2513: lines(down: h, left: h),
            0x2514: lines(up: l, right: l), 0x2515: lines(up: l, right: h),
            0x2516: lines(up: h, right: l), 0x2517: lines(up: h, right: h),
            0x2518: lines(up: l, left: l), 0x2519: lines(up: l, left: h),
            0x251a: lines(up: h, left: l), 0x251b: lines(up: h, left: h),
            0x251c: lines(up: l, right: l, down: l), 0x251d: lines(up: l, right: h, down: l),
            0x251e: lines(up: h, right: l, down: l), 0x251f: lines(up: l, right: l, down: h),
            0x2520: lines(up: h, right: l, down: h), 0x2521: lines(up: h, right: h, down: l),
            0x2522: lines(up: l, right: h, down: h), 0x2523: lines(up: h, right: h, down: h),
            0x2524: lines(up: l, down: l, left: l), 0x2525: lines(up: l, down: l, left: h),
            0x2526: lines(up: h, down: l, left: l), 0x2527: lines(up: l, down: h, left: l),
            0x2528: lines(up: h, down: h, left: l), 0x2529: lines(up: h, down: l, left: h),
            0x252a: lines(up: l, down: h, left: h), 0x252b: lines(up: h, down: h, left: h),
            0x252c: lines(right: l, down: l, left: l), 0x252d: lines(right: l, down: l, left: h),
            0x252e: lines(right: h, down: l, left: l), 0x252f: lines(right: h, down: l, left: h),
            0x2530: lines(right: l, down: h, left: l), 0x2531: lines(right: l, down: h, left: h),
            0x2532: lines(right: h, down: h, left: l), 0x2533: lines(right: h, down: h, left: h),
            0x2534: lines(up: l, right: l, left: l), 0x2535: lines(up: l, right: l, left: h),
            0x2536: lines(up: l, right: h, left: l), 0x2537: lines(up: l, right: h, left: h),
            0x2538: lines(up: h, right: l, left: l), 0x2539: lines(up: h, right: l, left: h),
            0x253a: lines(up: h, right: h, left: l), 0x253b: lines(up: h, right: h, left: h),
            0x253c: lines(up: l, right: l, down: l, left: l), 0x253d: lines(up: l, right: l, down: l, left: h),
            0x253e: lines(up: l, right: h, down: l, left: l), 0x253f: lines(up: l, right: h, down: l, left: h),
            0x2540: lines(up: h, right: l, down: l, left: l), 0x2541: lines(up: l, right: l, down: h, left: l),
            0x2542: lines(up: h, right: l, down: h, left: l), 0x2543: lines(up: h, right: l, down: l, left: h),
            0x2544: lines(up: h, right: h, down: l, left: l), 0x2545: lines(up: l, right: l, down: h, left: h),
            0x2546: lines(up: l, right: h, down: h, left: l), 0x2547: lines(up: h, right: h, down: l, left: h),
            0x2548: lines(up: l, right: h, down: h, left: h), 0x2549: lines(up: h, right: l, down: h, left: h),
            0x254a: lines(up: h, right: h, down: h, left: l), 0x254b: lines(up: h, right: h, down: h, left: h),
            0x2550: lines(right: d, left: d), 0x2551: lines(up: d, down: d),
            0x2552: lines(right: d, down: l), 0x2553: lines(right: l, down: d),
            0x2554: lines(right: d, down: d), 0x2555: lines(down: l, left: d),
            0x2556: lines(down: d, left: l), 0x2557: lines(down: d, left: d),
            0x2558: lines(up: l, right: d), 0x2559: lines(up: d, right: l),
            0x255a: lines(up: d, right: d), 0x255b: lines(up: l, left: d),
            0x255c: lines(up: d, left: l), 0x255d: lines(up: d, left: d),
            0x255e: lines(up: l, right: d, down: l), 0x255f: lines(up: d, right: l, down: d),
            0x2560: lines(up: d, right: d, down: d), 0x2561: lines(up: l, down: l, left: d),
            0x2562: lines(up: d, down: d, left: l), 0x2563: lines(up: d, down: d, left: d),
            0x2564: lines(right: d, down: l, left: d), 0x2565: lines(right: l, down: d, left: l),
            0x2566: lines(right: d, down: d, left: d), 0x2567: lines(up: l, right: d, left: d),
            0x2568: lines(up: d, right: l, left: l), 0x2569: lines(up: d, right: d, left: d),
            0x256a: lines(up: l, right: d, down: l, left: d), 0x256b: lines(up: d, right: l, down: d, left: l),
            0x256c: lines(up: d, right: d, down: d, left: d),
            0x2574: lines(left: l), 0x2575: lines(up: l), 0x2576: lines(right: l), 0x2577: lines(down: l),
            0x2578: lines(left: h), 0x2579: lines(up: h), 0x257a: lines(right: h), 0x257b: lines(down: h),
            0x257c: lines(right: h, left: l), 0x257d: lines(up: l, down: h),
            0x257e: lines(right: l, left: h), 0x257f: lines(up: h, down: l),
        ]
    }()

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    static func linesChar(_ metrics: Metrics, _ canvas: Canvas, _ lines: Lines) {
        func sub(_ a: Int, _ b: Int) -> Int { max(0, a - b) }
        let cellWidth = Int(metrics.cellWidth)
        let cellHeight = Int(metrics.cellHeight)
        let lightPx = Thickness.light.height(metrics.boxThickness)
        let heavyPx = Thickness.heavy.height(metrics.boxThickness)

        let hLightTop = sub(cellHeight, lightPx) / 2
        let hLightBottom = hLightTop + lightPx
        let hHeavyTop = sub(cellHeight, heavyPx) / 2
        let hHeavyBottom = hHeavyTop + heavyPx
        let hDoubleTop = sub(hLightTop, lightPx)
        let hDoubleBottom = hLightBottom + lightPx
        let vLightLeft = sub(cellWidth, lightPx) / 2
        let vLightRight = vLightLeft + lightPx
        let vHeavyLeft = sub(cellWidth, heavyPx) / 2
        let vHeavyRight = vHeavyLeft + heavyPx
        let vDoubleLeft = sub(vLightLeft, lightPx)
        let vDoubleRight = vLightRight + lightPx

        let upBottom = if lines.left == .heavy || lines.right == .heavy {
            hHeavyBottom
        } else if lines.left != lines.right || lines.down == lines.up {
            lines.left == .double || lines.right == .double ? hDoubleBottom : hLightBottom
        } else if lines.left == .none, lines.right == .none {
            hLightBottom
        } else {
            hLightTop
        }
        let downTop = if lines.left == .heavy || lines.right == .heavy {
            hHeavyTop
        } else if lines.left != lines.right || lines.up == lines.down {
            lines.left == .double || lines.right == .double ? hDoubleTop : hLightTop
        } else if lines.left == .none, lines.right == .none {
            hLightTop
        } else {
            hLightBottom
        }
        let leftRight = if lines.up == .heavy || lines.down == .heavy {
            vHeavyRight
        } else if lines.up != lines.down || lines.left == lines.right {
            lines.up == .double || lines.down == .double ? vDoubleRight : vLightRight
        } else if lines.up == .none, lines.down == .none {
            vLightRight
        } else {
            vLightLeft
        }
        let rightLeft = if lines.up == .heavy || lines.down == .heavy {
            vHeavyLeft
        } else if lines.up != lines.down || lines.right == lines.left {
            lines.up == .double || lines.down == .double ? vDoubleLeft : vLightLeft
        } else if lines.up == .none, lines.down == .none {
            vLightLeft
        } else {
            vLightRight
        }

        switch lines.up {
        case .none: break
        case .light: canvas.box(vLightLeft, 0, vLightRight, upBottom, .on)
        case .heavy: canvas.box(vHeavyLeft, 0, vHeavyRight, upBottom, .on)
        case .double:
            canvas.box(vDoubleLeft, 0, vLightLeft, lines.left == .double ? hLightTop : upBottom, .on)
            canvas.box(vLightRight, 0, vDoubleRight, lines.right == .double ? hLightTop : upBottom, .on)
        }
        switch lines.right {
        case .none: break
        case .light: canvas.box(rightLeft, hLightTop, cellWidth, hLightBottom, .on)
        case .heavy: canvas.box(rightLeft, hHeavyTop, cellWidth, hHeavyBottom, .on)
        case .double:
            canvas.box(lines.up == .double ? vLightRight : rightLeft, hDoubleTop, cellWidth, hLightTop, .on)
            canvas.box(lines.down == .double ? vLightRight : rightLeft, hLightBottom, cellWidth, hDoubleBottom, .on)
        }
        switch lines.down {
        case .none: break
        case .light: canvas.box(vLightLeft, downTop, vLightRight, cellHeight, .on)
        case .heavy: canvas.box(vHeavyLeft, downTop, vHeavyRight, cellHeight, .on)
        case .double:
            canvas.box(vDoubleLeft, lines.left == .double ? hLightBottom : downTop, vLightLeft, cellHeight, .on)
            canvas.box(vLightRight, lines.right == .double ? hLightBottom : downTop, vDoubleRight, cellHeight, .on)
        }
        switch lines.left {
        case .none: break
        case .light: canvas.box(0, hLightTop, leftRight, hLightBottom, .on)
        case .heavy: canvas.box(0, hHeavyTop, leftRight, hHeavyBottom, .on)
        case .double:
            canvas.box(0, hDoubleTop, lines.up == .double ? vLightLeft : leftRight, hLightTop, .on)
            canvas.box(0, hLightBottom, lines.down == .double ? vLightLeft : leftRight, hDoubleBottom, .on)
        }
    }

    static func lightDiagonalUpperRightToLowerLeft(_ metrics: Metrics, _ canvas: Canvas) {
        let width = Double(metrics.cellWidth)
        let height = Double(metrics.cellHeight)
        // Overshoot the corners slightly, keeping the slope.
        let slopeX = min(1, width / height)
        let slopeY = min(1, height / width)
        canvas.line(CGPoint(x: width + 0.5 * slopeX, y: -0.5 * slopeY),
                    CGPoint(x: -0.5 * slopeX, y: height + 0.5 * slopeY),
                    thickness: Double(Thickness.light.height(metrics.boxThickness)))
    }

    static func lightDiagonalUpperLeftToLowerRight(_ metrics: Metrics, _ canvas: Canvas) {
        let width = Double(metrics.cellWidth)
        let height = Double(metrics.cellHeight)
        let slopeX = min(1, width / height)
        let slopeY = min(1, height / width)
        canvas.line(CGPoint(x: -0.5 * slopeX, y: -0.5 * slopeY),
                    CGPoint(x: width + 0.5 * slopeX, y: height + 0.5 * slopeY),
                    thickness: Double(Thickness.light.height(metrics.boxThickness)))
    }

    static func arc(_ metrics: Metrics, _ canvas: Canvas, _ corner: Corner, _ thickness: Thickness) {
        let thick = thickness.height(metrics.boxThickness)
        let width = Double(metrics.cellWidth)
        let height = Double(metrics.cellHeight)
        let floatThick = Double(thick)
        let centerX = Double(max(0, Int(metrics.cellWidth) - thick) / 2) + floatThick / 2
        let centerY = Double(max(0, Int(metrics.cellHeight) - thick) / 2) + floatThick / 2
        let r = min(width, height) / 2
        // Fraction from the center for the middle control points.
        let s = 0.25

        let path = CGMutablePath()
        let up = corner == .tl || corner == .tr
        let leftward = corner == .tl || corner == .bl
        let ySign: Double = up ? -1 : 1
        let xSign: Double = leftward ? -1 : 1
        path.move(to: CGPoint(x: centerX, y: up ? 0 : height))
        path.addLine(to: CGPoint(x: centerX, y: centerY + ySign * r))
        path.addCurve(to: CGPoint(x: centerX + xSign * r, y: centerY),
                      control1: CGPoint(x: centerX, y: centerY + ySign * s * r),
                      control2: CGPoint(x: centerX + xSign * s * r, y: centerY))
        path.addLine(to: CGPoint(x: leftward ? 0 : width, y: centerY))
        canvas.stroke(path, lineWidth: floatThick)
    }

    /// Dashes that tile horizontally into an even line: half gaps at both
    /// ends, so N dashes have N gaps in all.
    private static func dashHorizontal(_ metrics: Metrics, _ canvas: Canvas, _ count: Int, _ thick: Int, _ desiredGap: Int) {
        let cellWidth = Int(metrics.cellWidth)
        // One pixel for each gap and dash at least; otherwise draw solid.
        guard cellWidth >= count * 2 else {
            hlineMiddle(metrics, canvas, .light)
            return
        }
        // Gaps never take more than half the space.
        let gap = min(desiredGap, cellWidth / (2 * count))
        let totalDash = cellWidth - count * gap
        let dash = totalDash / count
        var extra = totalDash % count
        let y = max(0, Int(metrics.cellHeight) - thick) / 2
        var x = gap / 2
        for _ in 0..<count {
            // Leftover pixels go to dashes, where they're less obvious.
            var x1 = x + dash
            if extra > 0 {
                extra -= 1
                x1 += 1
            }
            hline(canvas, x, x1, y, thick)
            x = x1 + gap
        }
    }

    /// Dashes that tile vertically, with one full gap at the bottom so they
    /// join solid characters without visible half gaps.
    private static func dashVertical(_ metrics: Metrics, _ canvas: Canvas, _ count: Int, _ thick: Int, _ desiredGap: Int) {
        let cellHeight = Int(metrics.cellHeight)
        guard cellHeight >= count * 2 else {
            vlineMiddle(metrics, canvas, .light)
            return
        }
        let gap = min(desiredGap, cellHeight / (2 * count))
        let totalDash = cellHeight - count * gap
        let dash = totalDash / count
        var extra = totalDash % count
        let x = max(0, Int(metrics.cellWidth) - thick) / 2
        var y = 0
        for _ in 0..<count {
            var y1 = y + dash
            if extra > 0 {
                extra -= 1
                y1 += 1
            }
            vline(canvas, y, y1, x, thick)
            y = y1 + gap
        }
    }
}
