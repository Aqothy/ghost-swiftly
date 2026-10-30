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
    /// The screen as the renderer last drew it.
    private(set) var screen: DrawnScreen?
    /// The grid this view last reported to the I/O.
    private var reportedGrid: GridSize?
    /// While the view's size is animating (the iOS keyboard), a host's view
    /// draws each step but reports its grid once, at the end.
    private var sizeSettling = false
    private var inputs: AsyncStream<Input>.Continuation?
    /// Receives what the program asks of the terminal while this view shows it.
    private var events: Task<Void, Never>?
    private(set) var focused = false
    private var visible = true
    private var preedit: Preedit?
    private var autoscroll: Task<Void, Never>?
    /// Magnification of a host grid drawn scaled down to fit: 1 shows it
    /// all, up to its native size.
    private var zoom = 1.0
    /// Where the zoomed drawing sits, in view points (zero or negative).
    private var panOffset = CGPoint.zero
    /// Asks the user whether to paste text that could run commands they
    /// didn't see; the platform view shows the prompt.
    var confirmUnsafePaste: (@MainActor (String) async -> Bool)?
    /// The system's double-click time.
    var clickInterval: Duration = .milliseconds(500)

    /// User input, applied in order.
    enum Input {
        /// A key from the keyboard.
        case key(KeyEvent)
        /// Text committed by an input method, dictation or the software
        /// keyboard: typed, never pasted.
        case text(String)
        case paste(String)
        /// A button at a point in the view. `local` runs when the terminal
        /// handled it itself rather than reporting it (a right click's menu).
        case mouseButton(MouseButtonAction, MouseEvent.Button, Modifiers, CGPoint, local: (@MainActor () -> Void)?)
        /// The pointer moved to a point in the view, or left it (nil).
        case mouseMoved(Modifiers, CGPoint?)
        /// Positive `y` scrolls up; precise deltas are points, others wheel
        /// ticks.
        case scroll(x: Double, y: Double, precise: Bool)
        /// A force click or long press: selects the word under the press.
        case deepPress
        case focus(Bool)
        /// Hands the selected text, as Ghostty copies it, to `copy`; after
        /// the input before it, so a quick drag and copy gets the drag.
        case copy(@MainActor (String) -> Void)
        case selectAll
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
        events = Task { [weak self, terminal] in
            for await event in await terminal.events() {
                self?.handle(event)
            }
        }
        Task { await terminal.setDefaultColors(Self.defaultColors(configuration.theme)) }
    }

    private func handle(_ event: TerminalEvent) {
        if case .clipboardWrite(let write) = event {
            write.perform()
        } else {
            io?.handle(event)
        }
    }

    /// Call when the surface goes away.
    func close() {
        inputs?.finish()
        events?.cancel()
        autoscroll?.cancel()
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
            let renderer = try Renderer(layer: SharedLayer(metalLayer), font: font) { [weak self] screen in
                Task { @MainActor in self?.screenChanged(screen) }
            }
            self.renderer = renderer
            metrics = renderer.initialMetrics
            let colors = Self.rendererColors(configuration.theme)
            let state = renderer.renderState
            let focused = focused
            let visible = visible
            Task {
                await renderer.start()
                await renderer.setColors(colors)
                // Focus and visibility can change before the first layout
                // starts the renderer.
                if focused { await renderer.setFocused(true) }
                if !visible { await renderer.setVisible(false) }
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

    /// The grid being drawn: the terminal's once the renderer has seen it.
    private var drawnGrid: GridSize? { screen?.grid ?? currentLayout?.preferredGrid }

    private func applyLayout() {
        guard let layout = currentLayout, layout.viewWidth > 0, layout.viewHeight > 0 else { return }
        let padding = layout.padding
        if let renderer {
            Task { await renderer.setPadding(.init(top: padding, bottom: padding, right: padding, left: padding)) }
        }

        switch configuration.gridPolicy {
        case .fitView:
            let preferred = layout.preferredGrid
            if preferred != reportedGrid {
                reportedGrid = preferred
                let cellWidth = UInt32(layout.cellWidth)
                let cellHeight = UInt32(layout.cellHeight)
                Task { try? await terminal.resize(to: preferred, cellWidth: cellWidth, cellHeight: cellHeight) }
                io?.requestResize(preferred)
            }
            sizeLayer(layout, grid: preferred)
        case .host:
            let preferred = layout.preferredGrid
            if !sizeSettling, preferred != reportedGrid {
                reportedGrid = preferred
                io?.requestResize(preferred)
            }
            sizeLayer(layout, grid: screen?.grid ?? preferred)
        }
    }

    /// The drawable's scale in the view: the fit, magnified by the zoom up
    /// to native size.
    private func displayScale(_ layout: SurfaceLayout, _ grid: GridSize) -> Double {
        min(1, layout.fitScale(for: grid) * zoom)
    }

    private func sizeLayer(_ layout: SurfaceLayout, grid: GridSize) {
        let drawable = layout.drawableSize(for: grid)
        let shown = displayScale(layout, grid)
        let size = CGSize(width: Double(drawable.width) / scale * shown, height: Double(drawable.height) / scale * shown)
        // Keep a zoomed drawing covering the view.
        panOffset.x = min(0, max(viewSize.width - size.width, panOffset.x))
        panOffset.y = min(0, max(viewSize.height - size.height, panOffset.y))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Unscaled, a drawable that briefly lags a live resize is clipped
        // rather than stretched, as in Ghostty; a host grid that doesn't fit
        // is scaled down to the layer.
        metalLayer.contentsGravity = shown < 1 ? .resize : .topLeft
        metalLayer.drawableSize = CGSize(width: drawable.width, height: drawable.height)
        metalLayer.frame = CGRect(origin: panOffset, size: size)
        CATransaction.commit()
    }

    /// Pinch zoom of a host grid drawn scaled down, around a view point.
    func zoom(by factor: Double, around point: CGPoint) {
        guard let layout = currentLayout, let grid = drawnGrid else { return }
        let fit = layout.fitScale(for: grid)
        guard fit < 1 else { return }
        let before = displayScale(layout, grid)
        zoom = min(1 / fit, max(1, zoom * factor))
        let ratio = displayScale(layout, grid) / before
        // Keep the content under the fingers in place.
        panOffset = CGPoint(x: point.x - (point.x - panOffset.x) * ratio, y: point.y - (point.y - panOffset.y) * ratio)
        sizeLayer(layout, grid: grid)
    }

    /// Moves a zoomed drawing by a translation in view points.
    func pan(by translation: CGPoint) {
        guard let layout = currentLayout, let grid = drawnGrid, zoom > 1 else { return }
        panOffset.x += translation.x
        panOffset.y += translation.y
        sizeLayer(layout, grid: grid)
    }

    private func screenChanged(_ screen: DrawnScreen) {
        let gridChanged = screen.grid != self.screen?.grid
        self.screen = screen
        if gridChanged, case .host = configuration.gridPolicy { applyLayout() }
    }

    /// Drawable pixels per view point, including a host grid's scaling.
    private var pixelsPerPoint: Double {
        guard let layout = currentLayout, let grid = drawnGrid else { return scale }
        return scale / displayScale(layout, grid)
    }

    /// A point in the view as surface pixels, which the mouse encoder and
    /// selection read.
    private func surfacePosition(_ point: CGPoint) -> (x: Double, y: Double) {
        let origin = metalLayer.frame.origin
        return ((point.x - origin.x) * pixelsPerPoint, (point.y - origin.y) * pixelsPerPoint)
    }

    private var mouseGeometry: MouseGeometry? {
        guard let layout = currentLayout, let grid = drawnGrid else { return nil }
        let drawable = layout.drawableSize(for: grid)
        let padding = UInt32(layout.padding)
        return MouseGeometry(
            screenWidth: UInt32(drawable.width), screenHeight: UInt32(drawable.height),
            cellWidth: UInt32(layout.cellWidth), cellHeight: UInt32(layout.cellHeight),
            paddingTop: padding, paddingBottom: padding, paddingLeft: padding, paddingRight: padding)
    }

    /// Where an input method anchors its candidates: the cursor cell in view
    /// points, as wide as the preedit (Ghostty's `imePoint`).
    var cursorRect: CGRect? {
        guard let layout = currentLayout, let cell = screen?.cursor else { return nil }
        let perPoint = pixelsPerPoint
        let origin = metalLayer.frame.origin
        let columns = preedit?.codepoints.reduce(0) { $0 + ($1.wide ? 2 : 1) } ?? 0
        return CGRect(
            x: origin.x + Double(cell.x * layout.cellWidth + layout.padding) / perPoint,
            y: origin.y + Double(cell.y * layout.cellHeight + layout.padding) / perPoint,
            width: Double(columns * layout.cellWidth) / perPoint,
            height: Double(layout.cellHeight) / perPoint)
    }

    // MARK: Input

    func send(_ input: Input) {
        inputs?.yield(input)
    }

    /// One task applies inputs in order, so bytes reach the I/O in the order
    /// the user produced them, after any resize they claim.
    private func startInput() {
        let (stream, continuation) = AsyncStream.makeStream(of: Input.self)
        inputs = continuation
        Task { [weak self] in
            for await input in stream {
                guard let self else { return }
                await apply(input)
            }
        }
    }

    private func apply(_ input: Input) async {
        switch input {
        case .key(let event):
            typed(await terminal.type(event, optionAsAlt: optionAsAlt))
        case .text(let text):
            typed(await terminal.type(KeyEvent(key: .unidentified, text: text), optionAsAlt: optionAsAlt))
        case .paste(let text):
            var bytes = await terminal.encodePaste(text)
            if bytes == nil, await confirmUnsafePaste?(text) == true {
                bytes = await terminal.encodePaste(text, allowUnsafe: true)
            }
            if let bytes { typed(bytes) }
        case .mouseButton(let action, let button, let modifiers, let point, let local):
            if action == .press { io?.activate() }
            guard let geometry = mouseGeometry else { return }
            let position = surfacePosition(point)
            let outcome = await terminal.mouseButton(
                action, button, modifiers: modifiers, x: position.x, y: position.y,
                geometry: geometry, clickInterval: clickInterval)
            switch outcome {
            case .reported(let bytes): if !bytes.isEmpty { io?.send(bytes) }
            case .local: local?()
            }
            if action == .release, button == .left { autoscroll?.cancel() }
        case .mouseMoved(let modifiers, let point):
            guard let geometry = mouseGeometry else { return }
            let position = point.map(surfacePosition) ?? (x: -1, y: -1)
            let bytes = await terminal.mouseMoved(modifiers: modifiers, x: position.x, y: position.y, geometry: geometry)
            if !bytes.isEmpty { io?.send(bytes) }
            if await terminal.selectionAutoscrolls { startAutoscroll() }
        case .scroll(let x, let y, let precise):
            guard let geometry = mouseGeometry else { return }
            // Precise deltas are points; the terminal wants pixels.
            let factor = precise ? pixelsPerPoint : 1
            let bytes = await terminal.scroll(x: x * factor, y: y * factor, precise: precise, geometry: geometry)
            if !bytes.isEmpty { io?.send(bytes) }
        case .deepPress:
            await terminal.deepPress()
        case .focus(let focused):
            let bytes = await terminal.encodeFocus(focused)
            if !bytes.isEmpty { io?.send(bytes) }
        case .copy(let copy):
            if let text = await terminal.selectionText(), !text.isEmpty { copy(text) }
        case .selectAll:
            await terminal.selectAll()
        }
    }

    private func typed(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        io?.activate()
        io?.send(bytes)
    }

    /// Scrolls while a selection drag is past the top or bottom, every 15 ms
    /// (Ghostty's `selection_scroll_ms`).
    private func startAutoscroll() {
        guard autoscroll == nil else { return }
        autoscroll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(15))
                guard let self, let geometry = mouseGeometry, await terminal.selectionAutoscrolls else { break }
                await terminal.selectionAutoscrollTick(geometry: geometry)
            }
            self?.autoscroll = nil
        }
    }

    private var optionAsAlt: OptionAsAlt {
        configuration.optionAsAlt ?? KeyboardLayout.optionAsAlt
    }

    /// Shows the input method's uncommitted text at the cursor; nil or empty
    /// removes it.
    func setPreedit(_ text: String?) {
        let codepoints = (text ?? "").unicodeScalars.compactMap { scalar -> Preedit.Codepoint? in
            // Zero-width preedit can't be drawn (Ghostty skips it too).
            let width = scalar.terminalWidth
            return width > 0 ? Preedit.Codepoint(codepoint: scalar.value, wide: width >= 2) : nil
        }
        let preedit = codepoints.isEmpty ? nil : Preedit(codepoints: codepoints)
        guard preedit != self.preedit else { return }
        // Composing clears the selection, as typing does.
        Task { await terminal.clearSelection() }
        self.preedit = preedit
        if let renderer { Task { await renderer.setPreedit(preedit) } }
    }

    func setFocused(_ focused: Bool) {
        guard focused != self.focused else { return }
        self.focused = focused
        if let renderer { Task { await renderer.setFocused(focused) } }
        if focused { io?.activate() }
        send(.focus(focused))
    }

    /// A tap that isn't a mouse button (iOS) still activates the view.
    func tapped() {
        io?.activate()
    }

    /// Off screen (occluded, or the app in the background): stop drawing,
    /// which iOS also requires of background apps.
    func setVisible(_ visible: Bool) {
        guard visible != self.visible else { return }
        self.visible = visible
        if let renderer { Task { await renderer.setVisible(visible) } }
    }

    /// The view's size is animating; when it stops, a host's view reports
    /// the grid it settled at.
    func setSizeSettling(_ settling: Bool) {
        guard settling != sizeSettling else { return }
        sizeSettling = settling
        if !settling { applyLayout() }
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
