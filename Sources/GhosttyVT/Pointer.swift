// Ported from ghostty src/Surface.zig @ 81598385d608dda4946093d6d6a234d204a2f225
// Ported from ghostty src/surface_mouse.zig @ 81598385d608dda4946093d6d6a234d204a2f225
// Ported from ghostty src/renderer/size.zig @ 81598385d608dda4946093d6d6a234d204a2f225
// Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors. MIT License.
//
// Pointer, scroll and typing side effects as Ghostty's Surface handles them
// (scrollCallback, mouseButtonCallback, cursorPosCallback,
// selectionScrollTick and the end of keyCallback): mouse reports while the
// program tracks the mouse, otherwise local selection and viewport
// scrolling. Ghostty's defaults: mouse-shift-capture false (the program's
// XTSHIFTESCAPE isn't exposed by libghostty-vt), scroll multipliers 1
// (precision) and 3 (discrete), selection-clear-on-typing, scroll-to-bottom
// on keystroke, right-click-action context-menu, copy-on-select none.

import GhosttyVt

/// A mouse button going down or up.
package enum MouseButtonAction: Sendable {
    case press
    case release
}

/// What a mouse button did.
package enum MouseButtonOutcome: Sendable, Equatable {
    /// The program tracks the mouse and gets these bytes.
    case reported([UInt8])
    /// The view handled it: selection, or a context menu for a right click.
    case local
}

/// The view's mouse and selection state for one terminal.
final class Pointer {
    private let gesture: OpaquePointer
    private let pressEvent: OpaquePointer
    private let dragEvent: OpaquePointer
    private let releaseEvent: OpaquePointer
    private let autoscrollEvent: OpaquePointer
    private let deepPressEvent: OpaquePointer

    /// Buttons held now (Ghostty's `click_state`).
    var pressed: Set<MouseEvent.Button> = []
    /// The modifiers of the last pointer event.
    var modifiers: Modifiers = []
    /// The last pointer position in surface pixels; negative when outside.
    var position = (x: -1.0, y: -1.0)
    /// Scroll short of a whole row or column, in pixels.
    var pendingScroll = (x: 0.0, y: 0.0)
    /// The last left press, which shift-click extension waits out.
    var lastLeftPress: ContinuousClock.Instant?
    /// Gesture times are nanoseconds since this.
    private let origin = ContinuousClock.now

    init() throws(GhosttyError) {
        var gesture: OpaquePointer?
        var events: [OpaquePointer?] = Array(repeating: nil, count: 5)
        let types = [GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_PRESS, GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_DRAG,
                     GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_RELEASE, GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_AUTOSCROLL_TICK,
                     GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_DEEP_PRESS]
        var ok = ghostty_selection_gesture_new(nil, &gesture) == GHOSTTY_SUCCESS
        for index in types.indices where ok {
            ok = ghostty_selection_gesture_event_new(nil, &events[index], types[index]) == GHOSTTY_SUCCESS
        }
        guard ok, let gesture, let press = events[0], let drag = events[1], let release = events[2],
              let autoscroll = events[3], let deepPress = events[4]
        else {
            events.forEach { ghostty_selection_gesture_event_free($0) }
            ghostty_selection_gesture_free(gesture, nil)
            throw .outOfMemory
        }
        self.gesture = gesture
        pressEvent = press
        dragEvent = drag
        releaseEvent = release
        autoscrollEvent = autoscroll
        deepPressEvent = deepPress
    }

    /// Frees the gesture, releasing what it tracks in `terminal`.
    func free(_ terminal: OpaquePointer?) {
        for event in [pressEvent, dragEvent, releaseEvent, autoscrollEvent, deepPressEvent] {
            ghostty_selection_gesture_event_free(event)
        }
        ghostty_selection_gesture_free(gesture, terminal)
    }

    /// Forgets the click sequence (Ghostty's `selection_gesture.reset`).
    func reset(_ terminal: OpaquePointer) {
        ghostty_selection_gesture_reset(gesture, terminal)
    }

    func clickCount(_ terminal: OpaquePointer) -> UInt8 {
        var count: UInt8 = 0
        _ = ghostty_selection_gesture_get(gesture, terminal, GHOSTTY_SELECTION_GESTURE_DATA_CLICK_COUNT, &count)
        return count
    }

    func autoscroll(_ terminal: OpaquePointer) -> GhosttySelectionGestureAutoscroll {
        var autoscroll = GHOSTTY_SELECTION_GESTURE_AUTOSCROLL_NONE
        _ = ghostty_selection_gesture_get(gesture, terminal, GHOSTTY_SELECTION_GESTURE_DATA_AUTOSCROLL, &autoscroll)
        return autoscroll
    }

    func press(_ terminal: OpaquePointer, ref: GhosttyGridRef, at position: (x: Double, y: Double),
               time: ContinuousClock.Instant, interval: Duration, cellWidth: Double, outputOnTriple: Bool)
        -> GhosttySelection? {
        var ref = ref
        var surface = GhosttySurfacePosition(x: position.x, y: position.y)
        var nanoseconds = UInt64((time - origin).nanoseconds)
        var repeatInterval = UInt64(interval.nanoseconds)
        var distance = cellWidth
        var behaviors = GhosttySelectionGestureBehaviors(
            single_click: GHOSTTY_SELECTION_GESTURE_BEHAVIOR_CELL,
            double_click: GHOSTTY_SELECTION_GESTURE_BEHAVIOR_WORD,
            triple_click: outputOnTriple ? GHOSTTY_SELECTION_GESTURE_BEHAVIOR_OUTPUT
                : GHOSTTY_SELECTION_GESTURE_BEHAVIOR_LINE)
        ghostty_selection_gesture_event_set(pressEvent, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REF, &ref)
        ghostty_selection_gesture_event_set(pressEvent, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_POSITION, &surface)
        ghostty_selection_gesture_event_set(pressEvent, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_TIME_NS, &nanoseconds)
        ghostty_selection_gesture_event_set(
            pressEvent, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REPEAT_INTERVAL_NS, &repeatInterval)
        ghostty_selection_gesture_event_set(pressEvent, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REPEAT_DISTANCE, &distance)
        ghostty_selection_gesture_event_set(pressEvent, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_BEHAVIORS, &behaviors)
        return apply(pressEvent, terminal)
    }

    func release(_ terminal: OpaquePointer, ref: GhosttyGridRef?) {
        if var ref {
            ghostty_selection_gesture_event_set(releaseEvent, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REF, &ref)
        } else {
            ghostty_selection_gesture_event_set(releaseEvent, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REF, nil)
        }
        _ = apply(releaseEvent, terminal)
    }

    func drag(_ terminal: OpaquePointer, ref: GhosttyGridRef, at position: (x: Double, y: Double),
              rectangle: Bool, geometry: GhosttySelectionGestureGeometry) -> GhosttySelection? {
        var ref = ref
        var surface = GhosttySurfacePosition(x: position.x, y: position.y)
        var rectangle = rectangle
        var geometry = geometry
        ghostty_selection_gesture_event_set(dragEvent, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REF, &ref)
        ghostty_selection_gesture_event_set(dragEvent, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_POSITION, &surface)
        ghostty_selection_gesture_event_set(dragEvent, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_RECTANGLE, &rectangle)
        ghostty_selection_gesture_event_set(dragEvent, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_GEOMETRY, &geometry)
        return apply(dragEvent, terminal)
    }

    func autoscrollTick(_ terminal: OpaquePointer, viewport: GhosttyPointCoordinate, at position: (x: Double, y: Double),
                        rectangle: Bool, geometry: GhosttySelectionGestureGeometry) -> GhosttySelection? {
        var viewport = viewport
        var surface = GhosttySurfacePosition(x: position.x, y: position.y)
        var rectangle = rectangle
        var geometry = geometry
        ghostty_selection_gesture_event_set(autoscrollEvent, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_VIEWPORT, &viewport)
        ghostty_selection_gesture_event_set(autoscrollEvent, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_POSITION, &surface)
        ghostty_selection_gesture_event_set(autoscrollEvent, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_RECTANGLE, &rectangle)
        ghostty_selection_gesture_event_set(autoscrollEvent, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_GEOMETRY, &geometry)
        return apply(autoscrollEvent, terminal)
    }

    func deepPress(_ terminal: OpaquePointer) -> GhosttySelection? {
        apply(deepPressEvent, terminal)
    }

    private func apply(_ event: OpaquePointer, _ terminal: OpaquePointer) -> GhosttySelection? {
        var selection = GhosttySelection()
        selection.size = MemoryLayout<GhosttySelection>.size
        return ghostty_selection_gesture_event(gesture, terminal, event, &selection) == GHOSTTY_SUCCESS
            ? selection : nil
    }
}

extension Terminal {
    // MARK: Keys

    /// Encodes a key the user typed. Typing a key that sends something
    /// clears the selection and scrolls to the bottom, as in Ghostty.
    package func type(_ event: KeyEvent, optionAsAlt: OptionAsAlt) -> [UInt8] {
        let bytes = encode(event, optionAsAlt: optionAsAlt)
        if !bytes.isEmpty, !event.key.isModifier {
            setSelection(nil)
            scrollViewport(GHOSTTY_SCROLL_VIEWPORT_BOTTOM)
            renderState?.capture(handle)
        }
        return bytes
    }

    // MARK: Buttons

    /// A button went down or up at a surface position. Returns the bytes for
    /// the program: a mouse report, or nothing when the press selects.
    /// `clickInterval` is the system's double-click time.
    package func mouseButton(
        _ action: MouseButtonAction, _ button: MouseEvent.Button, modifiers: Modifiers,
        x: Double, y: Double, geometry: MouseGeometry, clickInterval: Duration
    ) -> MouseButtonOutcome {
        switch action {
        case .press: pointer.pressed.insert(button)
        case .release: pointer.pressed.remove(button)
        }
        pointer.modifiers = modifiers
        pointer.position = (x, y)
        let shiftCapture = false

        // Shift-click past the double-click time extends the selection.
        if button == .left, action == .press, modifiers.contains(.shift), !shiftCapture,
           pointer.clickCount(handle) > 0, hasSelection,
           let last = pointer.lastLeftPress, ContinuousClock.now - last > clickInterval {
            _ = mouseMoved(modifiers: modifiers, x: x, y: y, geometry: geometry)
            return .local
        }

        if button == .left, action == .release {
            pointer.release(handle, ref: ref(at: x, y, geometry))
        }

        if isMouseReporting, !(modifiers.contains(.shift) && !shiftCapture) {
            setSelection(nil)
            // A press that began while reporting must not select once
            // reporting stops.
            pointer.reset(handle)
            renderState?.capture(handle)
            return .reported(report(MouseEvent(action: action == .press ? .press : .release, button: button,
                                               modifiers: modifiers, x: x, y: y), geometry))
        }

        if button == .left, action == .press {
            pointer.lastLeftPress = .now
            guard let ref = ref(at: x, y, geometry) else { return .local }
            let selection = pointer.press(
                handle, ref: ref, at: (x, y), time: .now, interval: clickInterval,
                cellWidth: Double(geometry.cellWidth), outputOnTriple: modifiers.contains(.super))
            if let selection {
                setSelection(selection)
            } else if pointer.clickCount(handle) == 1, hasSelection {
                setSelection(nil)
            }
            renderState?.capture(handle)
        }

        // Right-click selects the word under it for the context menu,
        // keeping a selection that already contains the click.
        if button == .right, action == .press, let ref = ref(at: x, y, geometry),
           !selectionContains(viewportPoint(at: x, y, geometry)) {
            var options = GhosttyTerminalSelectWordOptions()
            options.size = MemoryLayout<GhosttyTerminalSelectWordOptions>.size
            options.ref = ref
            var selection = GhosttySelection()
            selection.size = MemoryLayout<GhosttySelection>.size
            setSelection(ghostty_terminal_select_word(handle, &options, &selection) == GHOSTTY_SUCCESS
                ? selection : nil)
            renderState?.capture(handle)
        }
        return .local
    }

    /// A force click (macOS) or long press (iOS) after a press: selects the
    /// word under the press.
    package func deepPress() {
        guard let selection = pointer.deepPress(handle) else { return }
        setSelection(selection)
        renderState?.capture(handle)
    }

    // MARK: Motion

    /// The pointer moved to a surface position, outside the surface when
    /// negative. Returns a motion report for the program, if it wants one.
    package func mouseMoved(modifiers: Modifiers, x: Double, y: Double, geometry: MouseGeometry) -> [UInt8] {
        pointer.modifiers = modifiers
        pointer.position = (x, y)

        // Shift overrides the program's mouse grab while a button is held,
        // so the user can select (taken from Kitty).
        if isMouseReporting, !(modifiers.contains(.shift) && !pointer.pressed.isEmpty) {
            let button = MouseEvent.Button.reportOrder.first { pointer.pressed.contains($0) }
            return report(MouseEvent(action: .motion, button: button, modifiers: modifiers, x: x, y: y), geometry)
        }

        guard pointer.pressed.contains(.left), pointer.clickCount(handle) > 0,
              let ref = ref(at: x, y, geometry)
        else { return [] }
        setSelection(pointer.drag(handle, ref: ref, at: (x, y), rectangle: modifiers.contains(.alt),
                                  geometry: gestureGeometry(geometry)))
        renderState?.capture(handle)
        return []
    }

    /// Whether a selection drag past the top or bottom wants the viewport
    /// to keep scrolling; call ``selectionAutoscrollTick(geometry:)`` every
    /// 15 ms while it does (Ghostty's `selection_scroll_ms`).
    package var selectionAutoscrolls: Bool {
        pointer.autoscroll(handle) != GHOSTTY_SELECTION_GESTURE_AUTOSCROLL_NONE
    }

    package func selectionAutoscrollTick(geometry: MouseGeometry) {
        guard selectionAutoscrolls else { return }
        let position = pointer.position
        let cell = viewportCell(at: position.x, position.y, geometry)
        let selection = pointer.autoscrollTick(
            handle, viewport: GhosttyPointCoordinate(x: cell.x, y: UInt32(cell.y)), at: position,
            rectangle: pointer.modifiers.contains(.alt), geometry: gestureGeometry(geometry))
        guard pointer.clickCount(handle) > 0 else { return }
        setSelection(selection)
        renderState?.capture(handle)
    }

    // MARK: Scrolling

    /// Scroll wheel or trackpad deltas: positive `y` scrolls up. Precise
    /// deltas are pixels; others are wheel ticks. Returns bytes for the
    /// program: wheel reports, or arrow keys on the alternate screen.
    package func scroll(x: Double, y: Double, precise: Bool, geometry: MouseGeometry) -> [UInt8] {
        let cellHeight = Double(geometry.cellHeight)
        let cellWidth = Double(geometry.cellWidth)
        var rows = 0
        if y != 0 {
            // Ghostty's mouse-scroll-multiplier defaults; macOS reports slow
            // discrete scrolls as fractions of a tick, so round them out.
            let pixels = precise ? y : (y > 0 ? max(y, 1) : min(y, -1)) * cellHeight * 3
            let pending = pointer.pendingScroll.y + pixels
            if abs(pending) < cellHeight {
                pointer.pendingScroll.y = pending
            } else {
                let amount = pending / cellHeight
                pointer.pendingScroll.y = pending - amount * cellHeight
                rows = Int(amount.rounded(.towardZero))
            }
        }
        var columns = 0
        if x != 0 {
            if !precise {
                columns = Int(x.rounded())
            } else {
                let pending = pointer.pendingScroll.x + x
                if abs(pending) < cellWidth {
                    pointer.pendingScroll.x = pending
                } else {
                    let amount = pending / cellWidth
                    pointer.pendingScroll.x = pending - amount * cellWidth
                    columns = Int(amount.rounded(.towardZero))
                }
            }
        }

        if isMouseReporting { setSelection(nil) }

        // The alternate screen with alternate scroll (1007) and no mouse
        // tracking gets arrow keys.
        if isEnabled(.alternateScreen), !isMouseReporting, isEnabled(.alternateScroll) {
            guard rows != 0 else { return [] }
            setSelection(nil)
            renderState?.capture(handle)
            let application = isEnabled(.cursorKeys)
            let sequence = Array((rows > 0 ? (application ? "\u{1b}OA" : "\u{1b}[A")
                                           : (application ? "\u{1b}OB" : "\u{1b}[B")).utf8)
            return Array(repeating: sequence, count: abs(rows)).flatMap { $0 }
        }

        if isMouseReporting {
            let position = pointer.position
            var bytes: [UInt8] = []
            for _ in 0..<abs(rows) {
                bytes += report(MouseEvent(action: .press, button: rows > 0 ? .four : .five,
                                           modifiers: pointer.modifiers, x: position.x, y: position.y), geometry)
            }
            for _ in 0..<abs(columns) {
                bytes += report(MouseEvent(action: .press, button: columns > 0 ? .six : .seven,
                                           modifiers: pointer.modifiers, x: position.x, y: position.y), geometry)
            }
            return bytes
        }

        if rows != 0 {
            var behavior = GhosttyTerminalScrollViewport()
            behavior.tag = GHOSTTY_SCROLL_VIEWPORT_DELTA
            behavior.value.delta = -rows
            ghostty_terminal_scroll_viewport(handle, behavior)
            renderState?.capture(handle)
        }
        return []
    }

    // MARK: Selection

    package var hasSelection: Bool {
        var selection = GhosttySelection()
        selection.size = MemoryLayout<GhosttySelection>.size
        return ghostty_terminal_get(handle, GHOSTTY_TERMINAL_DATA_SELECTION, &selection) == GHOSTTY_SUCCESS
    }

    /// The selected text as Ghostty copies it: unwrapped, with trailing
    /// spaces trimmed (clipboard-trim-trailing-spaces).
    package func selectionText() -> String? {
        var options = GhosttyTerminalSelectionFormatOptions()
        options.size = MemoryLayout<GhosttyTerminalSelectionFormatOptions>.size
        options.emit = GHOSTTY_FORMATTER_FORMAT_PLAIN
        options.unwrap = true
        options.trim = true
        var pointer: UnsafeMutablePointer<UInt8>?
        var length = 0
        guard ghostty_terminal_selection_format_alloc(handle, nil, options, &pointer, &length) == GHOSTTY_SUCCESS
        else { return nil }
        defer { ghostty_free(nil, pointer, length) }
        guard let pointer else { return "" }
        return String(decoding: UnsafeBufferPointer(start: pointer, count: length), as: UTF8.self)
    }

    package func clearSelection() {
        setSelection(nil)
        renderState?.capture(handle)
    }

    package func selectAll() {
        var selection = GhosttySelection()
        selection.size = MemoryLayout<GhosttySelection>.size
        guard ghostty_terminal_select_all(handle, &selection) == GHOSTTY_SUCCESS else { return }
        setSelection(selection)
        renderState?.capture(handle)
    }

    // MARK: Helpers

    private var isMouseReporting: Bool {
        var tracking = false
        _ = ghostty_terminal_get(handle, GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING, &tracking)
        return tracking
    }

    private func report(_ event: MouseEvent, _ geometry: MouseGeometry) -> [UInt8] {
        encode(event, geometry: geometry, anyButtonPressed: !pointer.pressed.isEmpty)
    }

    private func setSelection(_ selection: GhosttySelection?) {
        if var selection {
            ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_SELECTION, &selection)
        } else {
            ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_SELECTION, nil)
        }
    }

    private func selectionContains(_ point: GhosttyPoint) -> Bool {
        var selection = GhosttySelection()
        selection.size = MemoryLayout<GhosttySelection>.size
        guard ghostty_terminal_get(handle, GHOSTTY_TERMINAL_DATA_SELECTION, &selection) == GHOSTTY_SUCCESS
        else { return false }
        var contains = false
        return ghostty_terminal_selection_contains(handle, &selection, point, &contains) == GHOSTTY_SUCCESS
            && contains
    }

    private func scrollViewport(_ tag: GhosttyTerminalScrollViewportTag) {
        var behavior = GhosttyTerminalScrollViewport()
        behavior.tag = tag
        ghostty_terminal_scroll_viewport(handle, behavior)
    }

    /// The viewport cell under a surface position, clamped to the grid
    /// (Ghostty's `posToViewport`).
    private func viewportCell(at x: Double, _ y: Double, _ geometry: MouseGeometry) -> (x: UInt16, y: UInt16) {
        let grid = grid
        let column = Int(max(0, x - Double(geometry.paddingLeft)) / Double(max(1, geometry.cellWidth)))
        let row = Int(max(0, y - Double(geometry.paddingTop)) / Double(max(1, geometry.cellHeight)))
        return (UInt16(min(column, Int(grid.columns) - 1)), UInt16(min(row, Int(grid.rows) - 1)))
    }

    private func viewportPoint(at x: Double, _ y: Double, _ geometry: MouseGeometry) -> GhosttyPoint {
        let cell = viewportCell(at: x, y, geometry)
        var point = GhosttyPoint()
        point.tag = GHOSTTY_POINT_TAG_VIEWPORT
        point.value.coordinate = GhosttyPointCoordinate(x: cell.x, y: UInt32(cell.y))
        return point
    }

    private func ref(at x: Double, _ y: Double, _ geometry: MouseGeometry) -> GhosttyGridRef? {
        var ref = GhosttyGridRef()
        ref.size = MemoryLayout<GhosttyGridRef>.size
        return ghostty_terminal_grid_ref(handle, viewportPoint(at: x, y, geometry), &ref) == GHOSTTY_SUCCESS
            ? ref : nil
    }

    private func gestureGeometry(_ geometry: MouseGeometry) -> GhosttySelectionGestureGeometry {
        GhosttySelectionGestureGeometry(
            columns: UInt32(grid.columns), cell_width: max(1, geometry.cellWidth),
            padding_left: geometry.paddingLeft, screen_height: max(1, geometry.screenHeight))
    }
}

extension MouseEvent.Button {
    /// The order Ghostty picks the button a motion report carries: the
    /// first held, in its button enum's order.
    static let reportOrder: [MouseEvent.Button] = [
        .left, .right, .middle, .four, .five, .six, .seven, .eight, .nine, .ten, .eleven,
    ]
}

private extension Duration {
    var nanoseconds: Int64 {
        components.seconds * 1_000_000_000 + components.attoseconds / 1_000_000_000
    }
}

extension Key {
    /// Ghostty's `Key.modifier`.
    var isModifier: Bool {
        switch self {
        case .shiftLeft, .shiftRight, .controlLeft, .controlRight, .altLeft, .altRight, .metaLeft, .metaRight: true
        default: false
        }
    }
}
