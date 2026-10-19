// Ported from ghostty src/renderer/generic.zig @ 81598385d608dda4946093d6d6a234d204a2f225
// Ported from ghostty src/renderer/Thread.zig @ 81598385d608dda4946093d6d6a234d204a2f225
// Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors. MIT License.
//
// The render loop: take an update, rebuild changed cells, draw. A
// CAMetalDisplayLink paces it and pauses whenever there's nothing to draw.

import Foundation
import GhosttyVT
import Metal
import OSLog
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
    /// Off screen nothing draws: the link stays paused until shown again.
    private var visible = true
    private var preedit: Preedit?
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

    /// What the view lays out and places the IME by, when it changes.
    private let onScreenChange: @Sendable (DrawnScreen) -> Void
    private var lastScreen: DrawnScreen?

    /// The fonts to draw with.
    struct FontRequest: Sendable, Equatable {
        var family: String?
        var size: DesiredSize
    }

    /// The first font's metrics, for the view's first layout.
    nonisolated let initialMetrics: Metrics

    init(layer: SharedLayer, font: FontRequest, onScreenChange: @escaping @Sendable (DrawnScreen) -> Void) throws {
        let thread = RenderThread(name: "ghostty.renderer")
        self.thread = thread
        self.layer = layer.layer
        frameRenderer = try FrameRenderer(device: layer.layer.device ?? MTLCreateSystemDefaultDevice()!)
        let grid = FontGrid.make(family: font.family, size: font.size)
        initialMetrics = grid.metrics
        builder = CellBuilder(grid: grid)
        self.onScreenChange = onScreenChange
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
        guard visible else { return }
        idleTicks = 0
        displayLink?.isPaused = false
    }

    func setVisible(_ visible: Bool) {
        self.visible = visible
        if visible {
            needsDraw = true
            wake()
        } else {
            displayLink?.isPaused = true
        }
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

    func setPreedit(_ preedit: Preedit?) {
        self.preedit = preedit
        builder.setPreedit(preedit, focused: focused, blinkVisible: blinkVisible)
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
        builder.setPreedit(preedit, focused: focused, blinkVisible: blinkVisible)
        renderState.redrawAll()
        wake()
        return grid.metrics
    }

    // MARK: Frames

    fileprivate func tick(_ drawable: CAMetalDrawable) {
        if let update = renderState.takeUpdate() {
            signposter.withIntervalSignpost("Build", "\(update.rows.count) rows") {
                builder.apply(update, focused: focused, blinkVisible: blinkVisible)
            }
            needsDraw = true
            let screen = DrawnScreen(
                grid: update.grid,
                cursor: update.cursor.viewport.map { DrawnScreen.Cell(x: $0.x, y: $0.y) })
            if screen != lastScreen {
                lastScreen = screen
                onScreenChange(screen)
            }
        }
        let size = CGSize(width: drawable.texture.width, height: drawable.texture.height)
        if needsDraw || size != lastDrawnSize {
            let geometry = ScreenGeometry(width: Int(size.width), height: Int(size.height), padding: padding)
            let drawn = signposter.withIntervalSignpost("Encode") {
                frameRenderer.draw(builder, geometry: geometry, into: drawable)
            }
            if drawn {
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

/// The screen as last drawn, for the view's layout and IME placement.
struct DrawnScreen: Equatable, Sendable {
    struct Cell: Equatable, Sendable {
        var x: Int
        var y: Int
    }

    var grid: GridSize
    /// The cursor's viewport cell; nil when scrolled out of view.
    var cursor: Cell?
}

/// Frame timing for Instruments: Build (cells from an update) and Encode
/// (buffers and commands) intervals, and each frame's GPU time.
let signposter = OSSignposter(subsystem: "ghost-swiftly", category: "Renderer")

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
