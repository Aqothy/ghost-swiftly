// Ported from ghostty src/renderer/generic.zig @ 81598385d608dda4946093d6d6a234d204a2f225
// Ported from ghostty src/renderer/Metal.zig @ 81598385d608dda4946093d6d6a234d204a2f225
// Ported from ghostty src/renderer/metal/Device.zig @ 81598385d608dda4946093d6d6a234d204a2f225
// Ported from ghostty src/renderer/metal/buffer.zig @ 81598385d608dda4946093d6d6a234d204a2f225
// Ported from ghostty src/renderer/metal/Texture.zig @ 81598385d608dda4946093d6d6a234d204a2f225
// Ported from ghostty src/renderer/size.zig @ 81598385d608dda4946093d6d6a234d204a2f225
// Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors. MIT License.
//
// drawFrame and the swap chain, drawing into a CAMetalLayer drawable rather
// than Ghostty's IOSurface targets. Native alpha blending (Ghostty's Apple
// default): a bgra8Unorm target and non-linear shaders.

import Metal
import OSLog
import QuartzCore
import Synchronization

/// Pixel geometry of the drawable.
struct ScreenGeometry: Equatable {
    /// Drawable size in pixels.
    var width: Int
    var height: Int
    /// The explicit padding around the grid in pixels.
    var padding: Padding

    struct Padding: Equatable {
        var top = 0
        var bottom = 0
        var right = 0
        var left = 0
    }
}

/// Draws CellBuilder's cells with Ghostty's shaders.
final class FrameRenderer {
    /// Ghostty's swap_chain_count: build the next frame while two draw.
    private static let swapChainCount = 3

    /// The GPU copy of everything one frame reads.
    private final class FrameState {
        var uniforms: MTLBuffer
        var cells: MTLBuffer
        var cellsBg: MTLBuffer
        var grayscale: MTLTexture?
        var grayscaleModified = -1
        var color: MTLTexture?
        var colorModified = -1

        init(_ device: MTLDevice, _ options: MTLResourceOptions) {
            uniforms = device.makeBuffer(length: MemoryLayout<Uniforms>.stride, options: options)!
            cells = device.makeBuffer(length: MemoryLayout<CellText>.stride, options: options)!
            cellsBg = device.makeBuffer(length: MemoryLayout<CellBg>.stride, options: options)!
        }
    }

    let device: MTLDevice
    static let pixelFormat = MTLPixelFormat.bgra8Unorm
    private let queue: MTLCommandQueue
    private let pipelines: Pipelines
    private let bufferOptions: MTLResourceOptions
    private let textureStorage: MTLStorageMode
    private var frames: [FrameState]
    private var frameIndex = 0
    /// Frames the GPU hasn't finished; completion handlers decrement it.
    private final class InFlight: Sendable {
        let count = Atomic<Int>(0)
    }

    private let inFlight = InFlight()
    private var fgScratch: [CellText] = []

    init(device: MTLDevice) throws {
        self.device = device
        guard let queue = device.makeCommandQueue() else { throw Pipelines.LoadError(message: "no command queue") }
        self.queue = queue
        pipelines = try Pipelines(device: device, pixelFormat: Self.pixelFormat)
        #if os(macOS)
        // Discrete GPUs need managed buffers; and only Apple GPUs allow
        // shared textures, even Intel ones with unified memory.
        let storage: MTLResourceOptions = device.hasUnifiedMemory ? .storageModeShared : .storageModeManaged
        textureStorage = device.supportsFamily(.apple1) ? .shared : .managed
        #else
        let storage = MTLResourceOptions.storageModeShared
        textureStorage = .shared
        #endif
        bufferOptions = [storage, .cpuCacheModeWriteCombined]
        frames = (0..<Self.swapChainCount).map { _ in FrameState(device, [storage, .cpuCacheModeWriteCombined]) }
    }

    /// Draws a frame into the drawable. Skips it, returning false, when the
    /// GPU still holds every frame state.
    @discardableResult
    func draw(_ builder: CellBuilder, geometry: ScreenGeometry, into drawable: CAMetalDrawable) -> Bool {
        draw(builder, geometry: geometry, into: drawable.texture) { $0.present(drawable) }
    }

    /// Draws a frame into a texture; `finish` presents or waits on the
    /// command buffer before it is committed.
    @discardableResult
    func draw(_ builder: CellBuilder, geometry: ScreenGeometry, into target: MTLTexture,
              finish: (MTLCommandBuffer) -> Void) -> Bool {
        guard inFlight.count.load(ordering: .acquiring) < Self.swapChainCount else { return false }
        frameIndex = (frameIndex + 1) % Self.swapChainCount
        let frame = frames[frameIndex]

        var uniforms = builder.uniforms
        let metrics = builder.grid.metrics
        Self.applyScreenSize(&uniforms, geometry, builder.contents, metrics)

        write(&frame.uniforms, [uniforms])
        write(&frame.cellsBg, builder.contents.bgCells)
        fgScratch.removeAll(keepingCapacity: true)
        for row in builder.contents.fgRows { fgScratch.append(contentsOf: row) }
        write(&frame.cells, fgScratch)
        sync(builder.grid.grayscaleAtlas, &frame.grayscale, &frame.grayscaleModified, .r8Unorm)
        sync(builder.grid.colorAtlas, &frame.color, &frame.colorModified, .bgra8Unorm_srgb)

        guard let commands = queue.makeCommandBuffer() else { return false }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return false }

        // Buffer 0 is the step's vertex/instance buffer, 1 the uniforms and
        // 2.. the rest, on both stages (Ghostty's RenderPass.step).
        encoder.setRenderPipelineState(pipelines.bgColor)
        bind(encoder, frame.uniforms, at: 1)
        bind(encoder, frame.cellsBg, at: 2)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        encoder.setRenderPipelineState(pipelines.cellBg)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        if !fgScratch.isEmpty {
            encoder.setRenderPipelineState(pipelines.cellText)
            bind(encoder, frame.cells, at: 0)
            encoder.setVertexTexture(frame.grayscale, index: 0)
            encoder.setFragmentTexture(frame.grayscale, index: 0)
            encoder.setVertexTexture(frame.color, index: 1)
            encoder.setFragmentTexture(frame.color, index: 1)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: fgScratch.count)
        }
        encoder.endEncoding()

        inFlight.count.add(1, ordering: .relaxed)
        commands.addCompletedHandler { [inFlight] commands in
            inFlight.count.subtract(1, ordering: .releasing)
            let microseconds = Int((commands.gpuEndTime - commands.gpuStartTime) * 1_000_000)
            signposter.emitEvent("GPU", "\(microseconds) us")
        }
        finish(commands)
        commands.commit()
        return true
    }

    /// Ghostty's updateScreenSizeUniforms, with balanced padding off (its
    /// default): the leftover space goes to the right and bottom.
    private static func applyScreenSize(_ uniforms: inout Uniforms, _ geometry: ScreenGeometry, _ contents: CellContents,
                                        _ metrics: Metrics) {
        let padding = geometry.padding
        let terminalWidth = geometry.width - padding.left - padding.right
        let terminalHeight = geometry.height - padding.top - padding.bottom
        let gridWidth = contents.columns * Int(metrics.cellWidth)
        let gridHeight = contents.rows * Int(metrics.cellHeight)
        let leftoverWidth = max(0, geometry.width - (gridWidth + padding.left + padding.right))
        let leftoverHeight = max(0, geometry.height - (gridHeight + padding.top + padding.bottom))

        uniforms.projectionMatrix = ortho2d(
            left: -Float(padding.left),
            right: Float(terminalWidth + padding.right),
            bottom: Float(terminalHeight + padding.bottom),
            top: -Float(padding.top))
        uniforms.gridPadding = SIMD4(
            Float(padding.top), Float(leftoverWidth + padding.right),
            Float(leftoverHeight + padding.bottom), Float(padding.left))
        uniforms.screenSize = SIMD2(Float(geometry.width), Float(geometry.height))
        uniforms.cellSize = SIMD2(Float(metrics.cellWidth), Float(metrics.cellHeight))
    }

    private func bind(_ encoder: MTLRenderCommandEncoder, _ buffer: MTLBuffer, at index: Int) {
        encoder.setVertexBuffer(buffer, offset: 0, index: index)
        encoder.setFragmentBuffer(buffer, offset: 0, index: index)
    }

    /// Copies values into a buffer, growing it as needed.
    private func write<T>(_ buffer: inout MTLBuffer, _ values: [T]) {
        let length = max(1, values.count) * MemoryLayout<T>.stride
        if buffer.length < length {
            // Grow geometrically so a slowly growing screen doesn't reallocate
            // every frame.
            buffer = device.makeBuffer(length: max(length, buffer.length * 2), options: bufferOptions)!
        }
        values.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            buffer.contents().copyMemory(from: base, byteCount: bytes.count)
        }
        #if os(macOS)
        if buffer.storageMode == .managed { buffer.didModifyRange(0..<max(1, values.count * MemoryLayout<T>.stride)) }
        #endif
    }

    /// Uploads an atlas when it changed, reallocating the texture when it grew.
    private func sync(_ atlas: Atlas, _ texture: inout MTLTexture?, _ modified: inout Int, _ format: MTLPixelFormat) {
        guard atlas.modified != modified || texture == nil else { return }
        let size = Int(atlas.size)
        if texture == nil || texture!.width != size {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: format, width: size, height: size, mipmapped: false)
            descriptor.usage = .shaderRead
            descriptor.storageMode = textureStorage
            descriptor.cpuCacheMode = .writeCombined
            texture = device.makeTexture(descriptor: descriptor)
        }
        let bytesPerRow = size * atlas.format.depth
        atlas.data.withUnsafeBytes { bytes in
            texture?.replace(region: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0,
                             withBytes: bytes.baseAddress!, bytesPerRow: bytesPerRow)
        }
        modified = atlas.modified
    }
}
