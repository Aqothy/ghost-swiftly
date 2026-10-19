import Foundation
import GhosttyVT
import Metal
import QuartzCore

/// The pixel layout of a terminal in a view.
struct SurfaceLayout: Equatable {
    /// The view's size in pixels.
    var viewWidth: Int
    var viewHeight: Int
    var cellWidth: Int
    var cellHeight: Int
    /// Padding on each side, in pixels.
    var padding: Int

    /// The largest grid that fits the view.
    var preferredGrid: GridSize {
        GridSize(columns: UInt16(clamping: max(1, (viewWidth - 2 * padding) / max(1, cellWidth))),
             rows: UInt16(clamping: max(1, (viewHeight - 2 * padding) / max(1, cellHeight))))
    }

    /// The drawable for a grid: the view, grown to fit a grid that doesn't.
    func drawableSize(for grid: GridSize) -> (width: Int, height: Int) {
        (max(viewWidth, Int(grid.columns) * cellWidth + 2 * padding),
         max(viewHeight, Int(grid.rows) * cellHeight + 2 * padding))
    }

    /// How much to shrink the drawable to fit the view, 1 when it fits.
    func fitScale(for grid: GridSize) -> Double {
        let drawable = drawableSize(for: grid)
        return min(1, Double(viewWidth) / Double(drawable.width), Double(viewHeight) / Double(drawable.height))
    }
}

/// The platform-independent part of a terminal view: renderer, layout and
/// the ordered input pipeline. The platform view forwards events here.
@MainActor
final class TerminalSurface {
    let terminal: Terminal
    weak var io: TerminalIO?
    private(set) var configuration: TerminalConfiguration
    let metalLayer = CAMetalLayer()
    private var renderer: Renderer?
    private(set) var metrics: Metrics?
    private var scale = 1.0
    private var viewSize = CGSize.zero
    /// The terminal's grid, as the renderer last saw it.
    private(set) var grid: GridSize?
    /// The grid this view last asked for; holding it means the view sized
    /// the terminal.
    private var requestedGrid: GridSize?
    private var inputs: AsyncStream<Input>.Continuation?
    private var focused = false

    enum Input {
        case key(KeyEvent)
        case text(String)
        case focus(Bool)
    }

    init(terminal: Terminal, io: TerminalIO?, configuration: TerminalConfiguration) {
        self.terminal = terminal
        self.io = io
        self.configuration = configuration
        metalLayer.device = MTLCreateSystemDefaultDevice()
        metalLayer.pixelFormat = FrameRenderer.pixelFormat
        // Ghostty's targets are Display P3; its shaders convert sRGB colors.
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.displayP3)
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = true
        metalLayer.anchorPoint = .zero
        // Scaling a host grid that doesn't fit.
        metalLayer.minificationFilter = .linear
        metalLayer.magnificationFilter = .linear
        startInput()
        Task { await terminal.setDefaultColors(Self.defaultColors(configuration.theme)) }
    }

    /// Call when the surface goes away.
    func close() {
        inputs?.finish()
        if let renderer {
            Task {
                await terminal.detach(renderer.renderState)
                await renderer.stop()
            }
        }
        renderer = nil
    }

    // MARK: Geometry

    /// The view's size in points and its backing scale changed.
    func layout(size: CGSize, scale: Double) {
        let fontChanged = scale != self.scale || metrics == nil
        viewSize = size
        self.scale = scale
        if fontChanged { reloadFont() }
        applyLayout()
    }

    private func reloadFont() {
        let font = Renderer.FontRequest(
            family: configuration.font.family, size: DesiredSize(points: configuration.font.size, scale: scale))
        metalLayer.contentsScale = scale
        guard let renderer else {
            startRenderer(font)
            return
        }
        Task {
            metrics = await renderer.setFont(font)
            applyLayout()
        }
    }

    private func startRenderer(_ font: Renderer.FontRequest) {
        do {
            let renderer = try Renderer(layer: SharedLayer(metalLayer), font: font) { [weak self] grid in
                Task { @MainActor in self?.gridChanged(grid) }
            }
            self.renderer = renderer
            metrics = renderer.initialMetrics
            let colors = Self.rendererColors(configuration.theme)
            let state = renderer.renderState
            let focused = focused
            Task {
                await renderer.start()
                await renderer.setColors(colors)
                // Focus can arrive before the first layout starts the renderer.
                if focused { await renderer.setFocused(true) }
                await terminal.attach(state)
            }
        } catch {
            assertionFailure("renderer failed to start: \(error)")
        }
    }

    private var currentLayout: SurfaceLayout? {
        guard let metrics else { return nil }
        return SurfaceLayout(
            viewWidth: Int((viewSize.width * scale).rounded()),
            viewHeight: Int((viewSize.height * scale).rounded()),
            cellWidth: Int(metrics.cellWidth),
            cellHeight: Int(metrics.cellHeight),
            padding: Int((configuration.padding * scale).rounded()))
    }

    var preferredGrid: GridSize? { currentLayout?.preferredGrid }

    private func applyLayout() {
        guard let layout = currentLayout, layout.viewWidth > 0, layout.viewHeight > 0 else { return }
        let padding = layout.padding
        if let renderer {
            Task { await renderer.setPadding(.init(top: padding, bottom: padding, right: padding, left: padding)) }
        }

        switch configuration.gridPolicy {
        case .fitView:
            let preferred = layout.preferredGrid
            if preferred != requestedGrid {
                requestedGrid = preferred
                let cellWidth = UInt32(layout.cellWidth)
                let cellHeight = UInt32(layout.cellHeight)
                Task { try? await terminal.resize(to: preferred, cellWidth: cellWidth, cellHeight: cellHeight) }
                io?.requestResize(preferred)
            }
            sizeLayer(layout, grid: preferred)
        case .host:
            let preferred = layout.preferredGrid
            // Keep the host in sync while this view holds the size.
            if let grid, grid == requestedGrid, preferred != grid {
                requestedGrid = preferred
                io?.requestResize(preferred)
            }
            sizeLayer(layout, grid: grid ?? preferred)
        }
    }

    private func sizeLayer(_ layout: SurfaceLayout, grid: GridSize) {
        let drawable = layout.drawableSize(for: grid)
        let fit = layout.fitScale(for: grid)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Unscaled, a drawable that briefly lags a live resize is clipped
        // rather than stretched, as in Ghostty; a host grid that doesn't fit
        // is scaled down to the layer.
        metalLayer.contentsGravity = fit < 1 ? .resize : .topLeft
        metalLayer.drawableSize = CGSize(width: drawable.width, height: drawable.height)
        metalLayer.frame = CGRect(
            x: 0, y: 0,
            width: Double(drawable.width) / scale * fit,
            height: Double(drawable.height) / scale * fit)
        CATransaction.commit()
    }

    private func gridChanged(_ grid: GridSize) {
        self.grid = grid
        if case .host = configuration.gridPolicy { applyLayout() }
    }

    // MARK: Input

    func send(_ input: Input) {
        inputs?.yield(input)
    }

    /// One task encodes inputs in order, so bytes reach the I/O in the order
    /// the user produced them, after any resize they claim.
    private func startInput() {
        let (stream, continuation) = AsyncStream.makeStream(of: Input.self)
        inputs = continuation
        let terminal = terminal
        Task { [weak self] in
            for await input in stream {
                guard let self else { return }
                switch input {
                case .key(let event):
                    let bytes = await terminal.encode(event, optionAsAlt: configuration.optionAsAlt)
                    guard !bytes.isEmpty else { continue }
                    claimSizeBeforeTyping()
                    io?.send(bytes)
                case .text(let text):
                    let bytes = Array(text.utf8)
                    guard !bytes.isEmpty else { continue }
                    claimSizeBeforeTyping()
                    io?.send(bytes)
                case .focus(let focused):
                    let bytes = await terminal.encodeFocus(focused)
                    if !bytes.isEmpty { io?.send(bytes) }
                }
            }
        }
    }

    /// Typing takes the size: a view drawing another view's grid asks for
    /// its own before the keystroke reaches the program.
    private func claimSizeBeforeTyping() {
        guard case .host = configuration.gridPolicy, let preferred = preferredGrid, grid != preferred else { return }
        requestedGrid = preferred
        io?.requestResize(preferred)
    }

    func setFocused(_ focused: Bool) {
        guard focused != self.focused else { return }
        self.focused = focused
        if let renderer { Task { await renderer.setFocused(focused) } }
        send(.focus(focused))
    }

    // MARK: Configuration

    func update(_ configuration: TerminalConfiguration) {
        guard configuration != self.configuration else { return }
        let old = self.configuration
        self.configuration = configuration
        if configuration.theme != old.theme {
            let colors = Self.rendererColors(configuration.theme)
            Task { await terminal.setDefaultColors(Self.defaultColors(configuration.theme)) }
            if let renderer { Task { await renderer.setColors(colors) } }
        }
        if configuration.font != old.font { reloadFont() }
        applyLayout()
    }

    private static func defaultColors(_ theme: TerminalConfiguration.Theme) -> Terminal.DefaultColors {
        Terminal.DefaultColors(foreground: theme.foreground, background: theme.background, palette: theme.palette)
    }

    private static func rendererColors(_ theme: TerminalConfiguration.Theme) -> RendererColors {
        RendererColors(cursor: theme.cursor, cursorText: theme.cursorText,
                       selectionBackground: theme.selectionBackground, selectionForeground: theme.selectionForeground)
    }
}
