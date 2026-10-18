// Ported from ghostty src/renderer/metal/shaders.zig @ 81598385d608dda4946093d6d6a234d204a2f225
// Ported from ghostty src/renderer/metal/Pipeline.zig @ 81598385d608dda4946093d6d6a234d204a2f225
// Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors. MIT License.
//
// The bg_color, cell_bg and cell_text pipelines; not image or bg_image.

import Foundation
import Metal

/// The compiled render pipelines.
struct Pipelines {
    let bgColor: MTLRenderPipelineState
    let cellBg: MTLRenderPipelineState
    let cellText: MTLRenderPipelineState

    struct LoadError: Error {
        let message: String
    }

    init(device: MTLDevice, pixelFormat: MTLPixelFormat) throws {
        let library = try Self.library(device)
        bgColor = try Self.pipeline(device, library, pixelFormat, "full_screen_vertex", "bg_color_fragment",
                                    blending: false)
        cellBg = try Self.pipeline(device, library, pixelFormat, "full_screen_vertex", "cell_bg_fragment",
                                   blending: true)
        cellText = try Self.pipeline(device, library, pixelFormat, "cell_text_vertex", "cell_text_fragment",
                                     blending: true, vertexDescriptor: CellText.vertexDescriptor)
    }

    /// Compiles shaders.metal, shipped as source so building the package
    /// needs no Metal toolchain. Metal caches the compiled result.
    static func library(_ device: MTLDevice) throws -> MTLLibrary {
        guard let url = Bundle.module.url(forResource: "shaders", withExtension: "metal") else {
            throw LoadError(message: "shaders.metal is missing from the bundle")
        }
        let options = MTLCompileOptions()
        // The build's -fmetal-math-mode=fast, as Xcode compiles Ghostty's.
        options.mathMode = .fast
        return try device.makeLibrary(source: String(contentsOf: url, encoding: .utf8), options: options)
    }

    static func descriptor(
        _ library: MTLLibrary, _ pixelFormat: MTLPixelFormat, _ vertex: String, _ fragment: String,
        blending: Bool, vertexDescriptor: MTLVertexDescriptor? = nil
    ) throws -> MTLRenderPipelineDescriptor {
        guard let vertexFunction = library.makeFunction(name: vertex),
              let fragmentFunction = library.makeFunction(name: fragment) else {
            throw LoadError(message: "missing shader \(vertex)/\(fragment)")
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.vertexDescriptor = vertexDescriptor
        let attachment = descriptor.colorAttachments[0]!
        attachment.pixelFormat = pixelFormat
        attachment.isBlendingEnabled = blending
        if blending {
            // Premultiplied alpha.
            attachment.rgbBlendOperation = .add
            attachment.alphaBlendOperation = .add
            attachment.sourceRGBBlendFactor = .one
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
            attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        }
        return descriptor
    }

    private static func pipeline(
        _ device: MTLDevice, _ library: MTLLibrary, _ pixelFormat: MTLPixelFormat, _ vertex: String,
        _ fragment: String, blending: Bool, vertexDescriptor: MTLVertexDescriptor? = nil
    ) throws -> MTLRenderPipelineState {
        try device.makeRenderPipelineState(descriptor: descriptor(
            library, pixelFormat, vertex, fragment, blending: blending, vertexDescriptor: vertexDescriptor))
    }
}
