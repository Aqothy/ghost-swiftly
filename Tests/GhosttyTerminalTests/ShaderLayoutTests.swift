import Foundation
import Metal
import Testing
@testable import GhosttyTerminal

/// The Swift structs the CPU writes must match what the Metal compiler laid
/// out for shaders.metal, member by member.
struct ShaderLayoutTests {
    let device: MTLDevice

    init() throws {
        device = try #require(MTLCreateSystemDefaultDevice())
    }

    private func reflection(_ vertex: String, _ fragment: String, vertexDescriptor: MTLVertexDescriptor? = nil)
        throws -> MTLRenderPipelineReflection {
        let library = try Pipelines.library(device)
        let descriptor = try Pipelines.descriptor(
            library, FrameRenderer.pixelFormat, vertex, fragment, blending: true, vertexDescriptor: vertexDescriptor)
        var reflection: MTLRenderPipelineReflection?
        _ = try device.makeRenderPipelineState(descriptor: descriptor, options: .bufferTypeInfo, reflection: &reflection)
        return try #require(reflection)
    }

    @Test func uniformsMatchTheShaderStruct() throws {
        let start = ContinuousClock.now
        let reflection = try reflection("cell_text_vertex", "cell_text_fragment",
                                        vertexDescriptor: CellText.vertexDescriptor)
        print("shader compile + pipeline: \(ContinuousClock.now - start)")

        let binding = try #require(reflection.vertexBindings.first { $0.index == 1 } as? MTLBufferBinding)
        let members = try #require(binding.bufferStructType?.members)
        let swift: [String: Int?] = [
            "projection_matrix": MemoryLayout<Uniforms>.offset(of: \.projectionMatrix),
            "screen_size": MemoryLayout<Uniforms>.offset(of: \.screenSize),
            "cell_size": MemoryLayout<Uniforms>.offset(of: \.cellSize),
            "grid_size": MemoryLayout<Uniforms>.offset(of: \.gridSize),
            "grid_padding": MemoryLayout<Uniforms>.offset(of: \.gridPadding),
            "padding_extend": MemoryLayout<Uniforms>.offset(of: \.paddingExtend),
            "min_contrast": MemoryLayout<Uniforms>.offset(of: \.minContrast),
            "cursor_pos": MemoryLayout<Uniforms>.offset(of: \.cursorPos),
            "cursor_color": MemoryLayout<Uniforms>.offset(of: \.cursorColor),
            "bg_color": MemoryLayout<Uniforms>.offset(of: \.bgColor),
            "cursor_wide": MemoryLayout<Uniforms>.offset(of: \.cursorWide),
            "use_display_p3": MemoryLayout<Uniforms>.offset(of: \.useDisplayP3),
            "use_linear_blending": MemoryLayout<Uniforms>.offset(of: \.useLinearBlending),
            "use_linear_correction": MemoryLayout<Uniforms>.offset(of: \.useLinearCorrection),
        ]
        #expect(Set(members.map(\.name)) == Set(swift.keys))
        for member in members {
            #expect(swift[member.name] == member.offset, "\(member.name)")
        }
        #expect(binding.bufferDataSize <= MemoryLayout<Uniforms>.stride)
    }

    @Test func cellTextMatchesTheVertexInputs() throws {
        let library = try Pipelines.library(device)
        let function = try #require(library.makeFunction(name: "cell_text_vertex"))
        let attributes = try #require(function.vertexAttributes)
        let expected: [String: MTLDataType] = [
            "glyph_pos": .uint2, "glyph_size": .uint2, "bearings": .int2, "grid_pos": .ushort2,
            "color": .uchar4, "atlas": .uchar, "bools": .uchar,
        ]
        for attribute in attributes {
            #expect(expected[attribute.name] == attribute.attributeType, "\(attribute.name)")
        }
        #expect(MemoryLayout<CellText>.stride == 32)
    }
}
