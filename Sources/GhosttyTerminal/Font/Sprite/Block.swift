// Ported from ghostty src/font/sprite/draw/block.zig @ 81598385d608dda4946093d6d6a234d204a2f225
// Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors. MIT License.
//
// Block Elements, U+2580...U+259F: ▀▁▂▃▄▅▆▇█▉▊▋▌▍▎▏▐░▒▓▔▕▖▗▘▙▚▛▜▝▞▟

import Foundation

extension Draw {
    static func blockElement(_ cp: UInt32, _ canvas: Canvas, _ metrics: Metrics) {
        switch cp {
        case 0x2580: block(metrics, canvas, .upper, 1, 0.5)
        case 0x2581: block(metrics, canvas, .lower, 1, 0.125)
        case 0x2582: block(metrics, canvas, .lower, 1, 0.25)
        case 0x2583: block(metrics, canvas, .lower, 1, 0.375)
        case 0x2584: block(metrics, canvas, .lower, 1, 0.5)
        case 0x2585: block(metrics, canvas, .lower, 1, 0.625)
        case 0x2586: block(metrics, canvas, .lower, 1, 0.75)
        case 0x2587: block(metrics, canvas, .lower, 1, 0.875)
        case 0x2588: fullBlockShade(metrics, canvas, .on)
        case 0x2589: block(metrics, canvas, .left, 0.875, 1)
        case 0x258a: block(metrics, canvas, .left, 0.75, 1)
        case 0x258b: block(metrics, canvas, .left, 0.625, 1)
        case 0x258c: block(metrics, canvas, .left, 0.5, 1)
        case 0x258d: block(metrics, canvas, .left, 0.375, 1)
        case 0x258e: block(metrics, canvas, .left, 0.25, 1)
        case 0x258f: block(metrics, canvas, .left, 0.125, 1)
        case 0x2590: block(metrics, canvas, .right, 0.5, 1)
        case 0x2591: fullBlockShade(metrics, canvas, .light)
        case 0x2592: fullBlockShade(metrics, canvas, .medium)
        case 0x2593: fullBlockShade(metrics, canvas, .dark)
        case 0x2594: block(metrics, canvas, .upper, 1, 0.125)
        case 0x2595: block(metrics, canvas, .right, 0.125, 1)
        case 0x2596: quadrant(metrics, canvas, [.bl])
        case 0x2597: quadrant(metrics, canvas, [.br])
        case 0x2598: quadrant(metrics, canvas, [.tl])
        case 0x2599: quadrant(metrics, canvas, [.tl, .bl, .br])
        case 0x259a: quadrant(metrics, canvas, [.tl, .br])
        case 0x259b: quadrant(metrics, canvas, [.tl, .tr, .bl])
        case 0x259c: quadrant(metrics, canvas, [.tl, .tr, .br])
        case 0x259d: quadrant(metrics, canvas, [.tr])
        case 0x259e: quadrant(metrics, canvas, [.tr, .bl])
        case 0x259f: quadrant(metrics, canvas, [.tr, .bl, .br])
        default: break
        }
    }

    static func block(_ metrics: Metrics, _ canvas: Canvas, _ alignment: Alignment, _ width: Double, _ height: Double) {
        blockShade(metrics, canvas, alignment, width, height, .on)
    }

    static func blockShade(
        _ metrics: Metrics, _ canvas: Canvas, _ alignment: Alignment, _ width: Double, _ height: Double, _ shade: Shade
    ) {
        let cellWidth = Int(metrics.cellWidth)
        let cellHeight = Int(metrics.cellHeight)
        let w = Int((Double(metrics.cellWidth) * width).rounded())
        let h = Int((Double(metrics.cellHeight) * height).rounded())
        let x = switch alignment.horizontal {
        case .left: 0
        case .right: cellWidth - w
        case .center: (cellWidth - w) / 2
        }
        let y = switch alignment.vertical {
        case .top: 0
        case .bottom: cellHeight - h
        case .middle: (cellHeight - h) / 2
        }
        canvas.rect(x: x, y: y, width: w, height: h, shade.color)
    }

    static func fullBlockShade(_ metrics: Metrics, _ canvas: Canvas, _ shade: Shade) {
        canvas.box(0, 0, Int(metrics.cellWidth), Int(metrics.cellHeight), shade.color)
    }

    private static func quadrant(_ metrics: Metrics, _ canvas: Canvas, _ quads: Quads) {
        if quads.contains(.tl) { fill(metrics, canvas, .zero, .half, .zero, .half) }
        if quads.contains(.tr) { fill(metrics, canvas, .half, .full, .zero, .half) }
        if quads.contains(.bl) { fill(metrics, canvas, .zero, .half, .half, .full) }
        if quads.contains(.br) { fill(metrics, canvas, .half, .full, .half, .full) }
    }
}
