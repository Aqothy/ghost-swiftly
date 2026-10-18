import AppKit
import GhosttyVT
import Metal
import Testing
@testable import GhosttyTerminal

/// Draws a terminal the way a view would, into an image.
@MainActor
enum OffscreenRender {
    static func image(_ terminal: Terminal, family: String? = nil, points: Double = 13, scale: Double = 2,
                      theme: TerminalConfiguration.Theme = .init()) async throws -> CGImage {
        let grid = FontGrid.make(family: family, size: DesiredSize(points: points, scale: scale))
        let builder = CellBuilder(grid: grid)
        let state = try RenderState {}
        await terminal.setDefaultColors(Terminal.DefaultColors(
            foreground: theme.foreground, background: theme.background, palette: theme.palette))
        await terminal.attach(state)
        let update = try #require(state.takeUpdate())
        builder.apply(update, focused: true, blinkVisible: true)

        let padding = Int((2 * scale).rounded())
        let width = Int(update.grid.columns) * Int(grid.metrics.cellWidth) + 2 * padding
        let height = Int(update.grid.rows) * Int(grid.metrics.cellHeight) + 2 * padding
        let device = try #require(MTLCreateSystemDefaultDevice())
        let renderer = try FrameRenderer(device: device)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: FrameRenderer.pixelFormat, width: width, height: height, mipmapped: false)
        descriptor.usage = [MTLTextureUsage.renderTarget, MTLTextureUsage.shaderRead]
        descriptor.storageMode = MTLStorageMode.shared
        let texture = try #require(device.makeTexture(descriptor: descriptor))
        var commands: MTLCommandBuffer?
        renderer.draw(builder, geometry: ScreenGeometry(
            width: width, height: height,
            padding: .init(top: padding, bottom: padding, right: padding, left: padding)),
                      into: texture) { commands = $0 }
        await commands?.completed()

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(&pixels, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.displayP3)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue
                | CGImageAlphaInfo.premultipliedFirst.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    static func write(_ image: CGImage, to path: String) {
        let rep = NSBitmapImageRep(cgImage: image)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
