// Ported from ghostty src/font/Glyph.zig @ 81598385d608dda4946093d6d6a234d204a2f225
// Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors. MIT License.

/// A glyph rasterized into an atlas.
struct Glyph: Equatable, Sendable {
    var width: UInt32
    var height: UInt32
    /// Left bearing.
    var offsetX: Int32
    /// Top bearing: from the bottom of the cell to the top of the glyph.
    var offsetY: Int32
    /// The atlas position of the top-left corner, in pixels.
    var atlasX: UInt32
    var atlasY: UInt32

    static let empty = Glyph(width: 0, height: 0, offsetX: 0, offsetY: 0, atlasX: 0, atlasY: 0)

    /// The size and position of a glyph.
    struct Size: Equatable {
        var width: Double
        var height: Double
        var x: Double
        var y: Double
    }

    struct RenderOptions {
        /// The metrics defining the grid, usually the primary face's.
        var gridMetrics: Metrics
        /// The number of grid cells this glyph takes up.
        var cellWidth: UInt8?
        var constraint: Constraint = .none
        /// The cells the glyph is free to take up when constrained: usually 1,
        /// 2 when there's whitespace to the right.
        var constraintWidth: UInt8 = 1
        /// Draw with a thicker stroke ("font-thicken").
        var thicken = false
        var thickenStrength: UInt8 = 255
    }

    /// Sizing and alignment rules for a glyph within its cell(s).
    struct Constraint: Equatable, Sendable {
        static let none = Constraint()

        enum SizeRule: Sendable {
            case none
            /// Scale down if needed to fit, preserving aspect ratio.
            case fit
            /// Scale up or down to exactly match, preserving aspect ratio.
            case cover
            /// Fit, but scale up to cover one cell if smaller. (Nerd Font rule.)
            case fitCover1
            /// Stretch to exactly fit both directions.
            case stretch
        }

        enum Align: Sendable {
            case none
            case start
            case end
            case center
            /// Centered on the first cell even for multi-cell constraints.
            /// (Nerd Font rule.)
            case center1
        }

        enum Height: Sendable {
            /// The primary face's full line height.
            case cell
            /// The icon height from the grid metrics.
            case icon
        }

        var size: SizeRule = .none
        var alignVertical: Align = .none
        var alignHorizontal: Align = .none
        var padTop = 0.0
        var padLeft = 0.0
        var padRight = 0.0
        var padBottom = 0.0
        // Size and bearings relative to the bounding box of the scale group.
        var relativeWidth = 1.0
        var relativeHeight = 1.0
        var relativeX = 0.0
        var relativeY = 0.0
        /// Maximum aspect ratio (width/height) when stretching.
        var maxXYRatio: Double?
        /// Maximum number of cells horizontally to use.
        var maxConstraintWidth: UInt8 = 2
        /// The height metric when the constraint width is 1.
        var height: Height = .cell

        var doesAnything: Bool {
            size != .none || alignHorizontal != .none || alignVertical != .none
        }

        /// Applies this constraint to a glyph's size, given the cells available.
        func constrain(_ glyph: Size, metrics: Metrics, constraintWidth: UInt8) -> Size {
            guard doesAnything else { return glyph }
            guard size == .stretch else {
                return constrainInner(glyph, metrics: metrics, constraintWidth: constraintWidth)
            }
            // Stretched glyphs align across cell boundaries, which works best
            // scaled and aligned to the grid rather than the face.
            var m = metrics
            m.faceWidth = Double(m.cellWidth)
            m.faceHeight = Double(m.cellHeight)
            m.faceY = 0
            // Negative padding only avoids rounding gaps when aligning to the
            // face, which stretched glyphs don't.
            var c = self
            c.padBottom = max(0, c.padBottom)
            c.padTop = max(0, c.padTop)
            c.padLeft = max(0, c.padLeft)
            c.padRight = max(0, c.padRight)
            return c.constrainInner(glyph, metrics: m, constraintWidth: constraintWidth)
        }

        private func constrainInner(_ glyph: Size, metrics: Metrics, constraintWidth: UInt8) -> Size {
            // For extra wide faces, never stretch glyphs across two cells
            // (mirrors font_patcher).
            let minConstraintWidth: UInt8 = size == .stretch && metrics.faceWidth > 0.9 * metrics.faceHeight
                ? 1
                : min(maxConstraintWidth, constraintWidth)

            let groupWidth = glyph.width / relativeWidth
            let groupHeight = glyph.height / relativeHeight
            var group = Size(
                width: groupWidth,
                height: groupHeight,
                x: glyph.x - groupWidth * relativeX,
                y: glyph.y - groupHeight * relativeY)

            // Scale, preserving the center of the group's bounding box.
            let (widthFactor, heightFactor) = scaleFactors(group, metrics: metrics, minConstraintWidth: minConstraintWidth)
            let centerX = group.x + group.width / 2
            let centerY = group.y + group.height / 2
            group.width *= widthFactor
            group.height *= heightFactor
            group.x = centerX - group.width / 2
            group.y = centerY - group.height / 2

            group.y = alignedY(group, metrics: metrics)
            group.x = alignedX(group, metrics: metrics, minConstraintWidth: minConstraintWidth)

            return Size(
                width: widthFactor * glyph.width,
                height: heightFactor * glyph.height,
                x: group.x + group.width * relativeX,
                y: group.y + group.height * relativeY)
        }

        private func scaleFactors(_ group: Size, metrics: Metrics, minConstraintWidth: UInt8) -> (Double, Double) {
            if size == .none { return (1, 1) }
            let multiCell = minConstraintWidth > 1
            let padWidthFactor = Double(minConstraintWidth) - (padLeft + padRight)
            let padHeightFactor = 1 - (padBottom + padTop)
            let targetWidth = padWidthFactor * metrics.faceWidth
            let heightMetric: Double = switch height {
            case .cell: metrics.faceHeight
            case .icon: multiCell ? metrics.iconHeight : metrics.iconHeightSingle
            }
            let targetHeight = padHeightFactor * heightMetric

            var widthFactor = targetWidth / group.width
            var heightFactor = targetHeight / group.height

            switch size {
            case .none:
                break
            case .fit:
                heightFactor = min(1, widthFactor, heightFactor)
                widthFactor = heightFactor
            case .cover:
                heightFactor = min(widthFactor, heightFactor)
                widthFactor = heightFactor
            case .fitCover1:
                // Like font_patcher's "pa" mode, but multi-cell icons scale to
                // the same size as single-cell ones instead of shrinking.
                heightFactor = min(widthFactor, heightFactor)
                if multiCell, heightFactor > 1 {
                    let (_, singleHeightFactor) = scaleFactors(group, metrics: metrics, minConstraintWidth: 1)
                    heightFactor = max(1, singleHeightFactor)
                }
                widthFactor = heightFactor
            case .stretch:
                break
            }

            if let maxXYRatio, group.width * widthFactor > group.height * heightFactor * maxXYRatio {
                widthFactor = group.height * heightFactor * maxXYRatio / group.width
            }
            return (widthFactor, heightFactor)
        }

        private func alignedY(_ group: Size, metrics: Metrics) -> Double {
            if size == .none, alignVertical == .none { return group.y }
            // face_height offset by face_y accounts for the asymmetry of the
            // pixel cell around the face.
            let padBottomDy = padBottom * metrics.faceHeight
            let padTopDy = padTop * metrics.faceHeight
            let startY = metrics.faceY + padBottomDy
            let endY = metrics.faceY + (metrics.faceHeight - group.height - padTopDy)
            let centerY = (startY + endY) / 2
            switch alignVertical {
            case .none: return endY < startY ? centerY : max(startY, min(group.y, endY))
            case .start: return startY
            case .end: return endY
            case .center, .center1: return centerY
            }
        }

        private func alignedX(_ group: Size, metrics: Metrics, minConstraintWidth: UInt8) -> Double {
            if size == .none, alignHorizontal == .none { return group.x }
            // Multi-cell constraints align across the first cell's left edge
            // to the last face cell's right edge; centering the face in the
            // grid cell happens after constraining.
            let fullFaceSpan = metrics.faceWidth + Double((UInt32(minConstraintWidth) - 1) * metrics.cellWidth)
            let padLeftDx = padLeft * metrics.faceWidth
            let padRightDx = padRight * metrics.faceWidth
            let startX = padLeftDx
            let endX = fullFaceSpan - group.width - padRightDx
            switch alignHorizontal {
            case .none: return max(startX, min(group.x, endX))
            case .start: return startX
            case .end: return max(startX, endX)
            case .center: return max(startX, (startX + endX) / 2)
            case .center1:
                let end1X = metrics.faceWidth - group.width - padRightDx
                return max(startX, (startX + end1X) / 2)
            }
        }
    }
}
