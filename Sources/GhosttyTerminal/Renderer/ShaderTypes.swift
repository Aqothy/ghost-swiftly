// Ported from ghostty src/renderer/metal/shaders.zig @ 81598385d608dda4946093d6d6a234d204a2f225
// Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors. MIT License.
//
// The CPU side of shaders.metal. Layouts must match the MSL structs byte for
// byte; ShaderLayoutTests checks them against the compiled shaders'
// reflection.

import Metal
import simd

/// The uniforms every shader reads (MSL `Uniforms`).
struct Uniforms {
    /// World (pixel) coordinates to normalized device coordinates.
    var projectionMatrix = simd_float4x4()
    /// The render target's size in pixels.
    var screenSize = SIMD2<Float>()
    /// One cell in pixels.
    var cellSize = SIMD2<Float>()
    /// Columns and rows.
    var gridSize = SIMD2<UInt16>()
    /// Blank space around the grid in pixels: top, right, bottom, left.
    var gridPadding = SIMD4<Float>()
    /// Which directions cell backgrounds extend into the padding (left,
    /// right, up, down, LSB first). Ghostty's default extends none.
    var paddingExtend: UInt8 = 0
    /// The WCAG 2.0 minimum contrast for text; 1 disables it.
    var minContrast: Float = 1
    var cursorPos = SIMD2<UInt16>(.max, .max)
    var cursorColor = SIMD4<UInt8>()
    /// The whole surface's background.
    var bgColor = SIMD4<UInt8>()
    /// The cursor covers two cells.
    var cursorWide = false
    /// Colors are already Display P3 rather than sRGB.
    var useDisplayP3 = false
    /// The target is sRGB, so shaders output linear colors.
    var useLinearBlending = false
    /// Weight correction for linear blending.
    var useLinearCorrection = false
}

/// One glyph quad for the text shader (MSL `CellTextVertexIn`), drawn per
/// instance.
struct CellText: Equatable {
    enum Atlas: UInt8 {
        case grayscale = 0
        case color = 1
    }

    struct Bools: OptionSet, Equatable {
        let rawValue: UInt8
        /// Don't apply minimum contrast (graphics elements).
        static let noMinContrast = Bools(rawValue: 1 << 0)
        /// This is the cursor glyph.
        static let isCursorGlyph = Bools(rawValue: 1 << 1)
    }

    /// Top-left of the glyph in its atlas.
    var glyphPos = SIMD2<UInt32>()
    var glyphSize = SIMD2<UInt32>()
    /// Left and top bearings.
    var bearings = SIMD2<Int16>()
    var gridPos: SIMD2<UInt16>
    var color: SIMD4<UInt8>
    var atlas: UInt8
    var bools: UInt8 = 0

    init(atlas: Atlas, bools: Bools = [], gridPos: SIMD2<UInt16>, color: SIMD4<UInt8>, glyph: Glyph,
         bearingOffset: SIMD2<Int32> = .zero) {
        self.atlas = atlas.rawValue
        self.bools = bools.rawValue
        self.gridPos = gridPos
        self.color = color
        glyphPos = SIMD2(glyph.atlasX, glyph.atlasY)
        glyphSize = SIMD2(glyph.width, glyph.height)
        bearings = SIMD2(Int16(clamping: glyph.offsetX + bearingOffset.x),
                         Int16(clamping: glyph.offsetY + bearingOffset.y))
    }

    /// The vertex layout of the text pipeline's per-instance buffer.
    static var vertexDescriptor: MTLVertexDescriptor {
        let descriptor = MTLVertexDescriptor()
        let attributes: [(MTLVertexFormat, Int)] = [
            (.uint2, MemoryLayout<CellText>.offset(of: \.glyphPos)!),
            (.uint2, MemoryLayout<CellText>.offset(of: \.glyphSize)!),
            (.short2, MemoryLayout<CellText>.offset(of: \.bearings)!),
            (.ushort2, MemoryLayout<CellText>.offset(of: \.gridPos)!),
            (.uchar4, MemoryLayout<CellText>.offset(of: \.color)!),
            (.uchar, MemoryLayout<CellText>.offset(of: \.atlas)!),
            (.uchar, MemoryLayout<CellText>.offset(of: \.bools)!),
        ]
        for (index, (format, offset)) in attributes.enumerated() {
            descriptor.attributes[index].format = format
            descriptor.attributes[index].offset = offset
            descriptor.attributes[index].bufferIndex = 0
        }
        descriptor.layouts[0].stride = MemoryLayout<CellText>.stride
        descriptor.layouts[0].stepFunction = .perInstance
        return descriptor
    }
}

/// One cell's background for the background shader (MSL `uchar4`).
typealias CellBg = SIMD4<UInt8>

/// Ghostty's `math.ortho2d`.
func ortho2d(left: Float, right: Float, bottom: Float, top: Float) -> simd_float4x4 {
    let w = right - left
    let h = top - bottom
    return simd_float4x4(columns: (
        SIMD4(2 / w, 0, 0, 0),
        SIMD4(0, 2 / h, 0, 0),
        SIMD4(0, 0, -1, 0),
        SIMD4(-(right + left) / w, -(top + bottom) / h, 0, 1)))
}
