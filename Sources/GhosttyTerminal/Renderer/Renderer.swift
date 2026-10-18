// Ported from ghostty src/renderer/generic.zig @ 81598385d608dda4946093d6d6a234d204a2f225
// Ported from ghostty src/renderer/Thread.zig @ 81598385d608dda4946093d6d6a234d204a2f225
// Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors. MIT License.
//
// The render loop: take an update, rebuild changed cells, draw. A
// CAMetalDisplayLink paces it and pauses whenever there's nothing to draw.

import Foundation
import GhosttyVT
import Metal
import QuartzCore
import Synchronization

/// Draws one view's terminal, on its own thread.
actor Renderer {
    nonisolated let thread: RenderThread
    nonisolated var unownedExecutor: UnownedSerialExecutor { thread.asUnownedSerialExecutor() }

    /// Shared with the terminal, which begins updates on it.
    nonisolated let renderState: RenderState
    private let layer: CAMetalLayer
    private var builder: CellBuilder
    private let frameRenderer: FrameRenderer
    private var displayLink: CAMetalDisplayLink?
    private var displayLinkDelegate: DisplayLinkDelegate?
    private var padding = ScreenGeometry.Padding()
    private var focused = false
    private var blinkVisible = true
    private var blinkTimer: Timer?
    /// The cells changed since the last frame that drew.
    private var needsDraw = true
    private var lastDrawnSize = CGSize.zero
    /// Ticks in a row with nothing to draw; the link pauses after a few so
    /// an idle terminal costs nothing.
    private var idleTicks = 0
    /// Set while a wake is on its way, so a flood of output queues one.
    private nonisolated let wakeQueued = Atomic<Bool>(false)

    /// Ghostty's cursor blink interval, in seconds.
    private static let blinkInterval: TimeInterval = 0.6

    /// The terminal's grid when it changes, for layout.
    private let onGridChange: @Sendable (Grid) -> Void
    private var lastGrid: Grid?

    /// The fonts to draw with.
    struct FontRequest: Sendable, Equatable {
        var family: String?
        var size: DesiredSize
    }

    /// The first font's metrics, for the view's first layout.
    nonisolated let initialMetrics: Metrics

    init(layer: SharedLayer, font: FontRequest, onGridChange: @escaping @Sendable (Grid) -> Void) throws {
        let thread = RenderThread(name: "ghostty.renderer")
        self.thread = thread
        self.layer = layer.layer
        frameRenderer = try FrameRenderer(device: layer.layer.device ?? MTLCreateSystemDefaultDevice()!)
        let grid = FontGrid.make(family: font.family, size: font.size)
        initialMetrics = grid.metrics
        builder = CellBuilder(grid: grid)
        self.onGridChange = onGridChange
        let wake = WakeTarget()
        renderState = try RenderState { wake.wake() }
        wake.renderer = self
    }

    /// Bridges RenderState's wake callback, set before the renderer finishes
    /// initializing, to the renderer.
    private final class WakeTarget: @unchecked Sendable {
        weak var renderer: Renderer?

        func wake() {
            renderer?.requestWake()
        }
    }

    nonisolated func requestWake() {
        guard wakeQueued.compareExchange(expected: false, desired: true, ordering: .acquiringAndReleasing).exchanged
        else { return }
        Task { await self.wake() }
    }

    /// Starts drawing. Call once.
    func start() {
        let link = CAMetalDisplayLink(metalLayer: layer)
        let delegate = DisplayLinkDelegate(renderer: self)
        link.delegate = delegate
        // Up to the display's maximum, which is 120 Hz on ProMotion.
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .current, forMode: .default)
        displayLink = link
        displayLinkDelegate = delegate
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        blinkTimer?.invalidate()
        blinkTimer = nil
        thread.stop()
    }

    private func wake() {
        wakeQueued.store(false, ordering: .releasing)
        idleTicks = 0
        displayLink?.isPaused = false
    }

    // MARK: Inputs from the view

    func setPadding(_ padding: ScreenGeometry.Padding) {
        self.padding = padding
        needsDraw = true
        wake()
    }

    func setFocused(_ focused: Bool) {
        self.focused = focused
        blinkVisible = true
        restartBlink()
        builder.rebuildCursor(focused: focused, blinkVisible: blinkVisible)
        needsDraw = true
        wake()
    }

    func setColors(_ colors: RendererColors) {
        builder.rendererColors = colors
        renderState.redrawAll()
        wake()
    }

    /// Switches fonts (a new family or size); every row is rebuilt.
    /// Returns the new metrics.
    func setFont(_ font: FontRequest) -> Metrics {
        let grid = FontGrid.make(family: font.family, size: font.size)
        let colors = builder.rendererColors
        builder = CellBuilder(grid: grid)
        builder.rendererColors = colors
        renderState.redrawAll()
        wake()
        return grid.metrics
    }

    // MARK: Frames

    fileprivate func tick(_ drawable: CAMetalDrawable) {
        if let update = renderState.takeUpdate() {
            builder.apply(update, focused: focused, blinkVisible: blinkVisible)
            needsDraw = true
            if update.grid != lastGrid {
                lastGrid = update.grid
                onGridChange(update.grid)
            }
        }
        let size = CGSize(width: drawable.texture.width, height: drawable.texture.height)
        if needsDraw || size != lastDrawnSize {
            let geometry = ScreenGeometry(width: Int(size.width), height: Int(size.height), padding: padding)
            if frameRenderer.draw(builder, geometry: geometry, into: drawable) {
                needsDraw = false
                lastDrawnSize = size
            }
            idleTicks = 0
            return
        }
        // Nothing changed: stop the link until the next wake.
        idleTicks += 1
        if idleTicks >= 2 { displayLink?.isPaused = true }
    }

    private func restartBlink() {
        blinkTimer?.invalidate()
        blinkTimer = nil
        guard focused else { return }
        let timer = Timer(timeInterval: Self.blinkInterval, repeats: true) { [weak self] _ in
            self?.assumeIsolated { $0.blink() }
        }
        RunLoop.current.add(timer, forMode: .default)
        blinkTimer = timer
    }

    private func blink() {
        // Only a blinking cursor (DEC mode 12) needs frames.
        guard builder.cursorBlinks else { return }
        blinkVisible.toggle()
        builder.rebuildCursor(focused: focused, blinkVisible: blinkVisible)
        needsDraw = true
        wake()
    }
}

/// The view's Metal layer, shared with its renderer: the view sets its
/// geometry on the main thread, and the renderer's display link takes
/// drawables from it on the render thread, which CAMetalLayer allows.
struct SharedLayer: @unchecked Sendable {
    let layer: CAMetalLayer

    init(_ layer: CAMetalLayer) {
        self.layer = layer
    }
}

/// CAMetalDisplayLink needs an NSObject delegate; this forwards ticks, which
/// arrive on the render thread's run loop, to the renderer.
private final class DisplayLinkDelegate: NSObject, CAMetalDisplayLinkDelegate, @unchecked Sendable {
    private weak var renderer: Renderer?

    init(renderer: Renderer) {
        self.renderer = renderer
    }

    func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
        // The callback is on the render thread, so the drawable never leaves it.
        let drawable = SameThread(value: update.drawable)
        renderer?.assumeIsolated { $0.tick(drawable.value) }
    }
}

private struct SameThread<Value>: @unchecked Sendable {
    let value: Value
}
