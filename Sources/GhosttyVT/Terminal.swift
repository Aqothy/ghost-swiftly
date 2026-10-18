import Foundation
import GhosttyVt

/// A terminal emulator: screen, scrollback, modes and the VT parser, without
/// I/O or rendering.
///
/// The actor is the one owner of the terminal's state. Feed it program output
/// in order; it reports what the program asked for through ``events``. It
/// never answers the program: queries such as device attributes get no reply
/// from here, so the host that owns the program must answer them.
public actor Terminal {
    public struct Configuration: Sendable, Hashable {
        /// The most scrollback to keep, in bytes of terminal pages (Ghostty's
        /// `scrollback-limit`). A restored snapshot brings its own limit.
        public var scrollbackLimit: Int

        public init(scrollbackLimit: Int = 10_000_000) {
            self.scrollbackLimit = scrollbackLimit
        }
    }

    /// Effects in the order the program produced them. One consumer.
    public nonisolated let events: AsyncStream<TerminalEvent>

    private var handle: OpaquePointer
    private let effects: Effects
    /// History still to restore from the last snapshot. It borrows `handle`.
    private var restoring: SnapshotRestore?
    private let keyEncoder: OpaquePointer
    private let keyEvent: OpaquePointer
    private let mouseEncoder: OpaquePointer
    private let mouseEvent: OpaquePointer
    /// The view drawing this terminal, if any.
    private var renderState: RenderState?
    /// Counts render holds so an expired timer can't end a later hold.
    private var renderHoldGeneration = 0
    /// Set when output may have changed the mouse modes. Reloading them from
    /// the terminal also forgets the last reported cell
    /// (`ghostty_mouse_encoder_setopt_from_terminal`), so it isn't done per
    /// event.
    private var mouseModesStale = true

    public init(grid: Grid, configuration: Configuration = .init()) throws(GhosttyError) {
        var handle: OpaquePointer?
        try check(ghostty_terminal_new(nil, &handle, grid.columns, grid.rows))
        guard let handle else { throw .invalidValue }
        var limit = configuration.scrollbackLimit
        ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, &limit)

        var keyEncoder: OpaquePointer?
        var keyEvent: OpaquePointer?
        var mouseEncoder: OpaquePointer?
        var mouseEvent: OpaquePointer?
        guard ghostty_key_encoder_new(nil, &keyEncoder) == GHOSTTY_SUCCESS, let keyEncoder,
              ghostty_key_event_new(nil, &keyEvent) == GHOSTTY_SUCCESS, let keyEvent,
              ghostty_mouse_encoder_new(nil, &mouseEncoder) == GHOSTTY_SUCCESS, let mouseEncoder,
              ghostty_mouse_event_new(nil, &mouseEvent) == GHOSTTY_SUCCESS, let mouseEvent
        else {
            ghostty_key_encoder_free(keyEncoder)
            ghostty_key_event_free(keyEvent)
            ghostty_mouse_encoder_free(mouseEncoder)
            ghostty_mouse_event_free(mouseEvent)
            ghostty_terminal_free(handle)
            throw .outOfMemory
        }
        var trackLastCell = true
        ghostty_mouse_encoder_setopt(mouseEncoder, GHOSTTY_MOUSE_ENCODER_OPT_TRACK_LAST_CELL, &trackLastCell)

        let (events, continuation) = AsyncStream.makeStream(of: TerminalEvent.self)
        self.events = events
        self.handle = handle
        self.effects = Effects(continuation: continuation)
        self.keyEncoder = keyEncoder
        self.keyEvent = keyEvent
        self.mouseEncoder = mouseEncoder
        self.mouseEvent = mouseEvent
        effects.install(on: handle)
        effects.renderHold = { [weak self] held in
            // Effects only fire inside calls on `handle`, on this executor.
            self?.assumeIsolated { $0.renderHoldChanged(held) }
        }
    }

    isolated deinit {
        // The decoder borrows the terminal, so it goes first.
        restoring = nil
        ghostty_terminal_free(handle)
        ghostty_key_encoder_free(keyEncoder)
        ghostty_key_event_free(keyEvent)
        ghostty_mouse_encoder_free(mouseEncoder)
        ghostty_mouse_event_free(mouseEvent)
        effects.continuation.finish()
    }

    // MARK: Output

    /// Parses program output. Malformed input never fails; it is handled the
    /// way a real terminal would.
    public func feed(_ bytes: some ContiguousBytes) {
        bytes.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress, !buffer.isEmpty else { return }
            ghostty_terminal_vt_write(handle, base.assumingMemoryBound(to: UInt8.self), buffer.count)
        }
        mouseModesStale = true
        renderState?.capture(handle)
    }

    /// Resizes the grid, reflowing the primary screen. `cellWidth` and
    /// `cellHeight` are the cell size in pixels, which only size reports and
    /// image protocols read.
    public func resize(to grid: Grid, cellWidth: UInt32 = 1, cellHeight: UInt32 = 1) throws(GhosttyError) {
        try check(ghostty_terminal_resize(handle, grid.columns, grid.rows, cellWidth, cellHeight))
        renderState?.capture(handle)
    }

    /// Replaces the whole terminal with a snapshot's renderable state (its
    /// READY marker: screens, modes, cursor and unfinished parser input).
    /// Older scrollback follows, one page per ``restoreHistoryPage()`` call;
    /// output may be fed in between. Restoring again abandons the history of
    /// the previous snapshot.
    public func restore(snapshot: some ContiguousBytes) throws(GhosttyError) {
        let restore = try SnapshotRestore(snapshot: snapshot)
        let restored = try restore.ready()
        restoring = nil
        ghostty_terminal_free(handle)
        handle = restored
        restoring = restore
        effects.install(on: restored)
        mouseModesStale = true
        renderState?.capture(handle)
    }

    /// Prepends the next page of the last snapshot's history.
    public func restoreHistoryPage() throws(GhosttyError) -> HistoryPage {
        guard let restoring else { return .finished }
        let page: HistoryPage
        do {
            page = try restoring.next()
        } catch {
            // A decode error poisons the decoder (ghostty snapshot.h); the
            // terminal keeps the history restored so far.
            self.restoring = nil
            throw error
        }
        if page == .finished { self.restoring = nil }
        renderState?.capture(handle)
        return page
    }

    // MARK: State

    public var grid: Grid {
        Grid(columns: value(GHOSTTY_TERMINAL_DATA_COLS, as: UInt16.self),
             rows: value(GHOSTTY_TERMINAL_DATA_ROWS, as: UInt16.self))
    }

    /// The cursor's cell in the active area, zero-based.
    public var cursor: (x: UInt16, y: UInt16) {
        (value(GHOSTTY_TERMINAL_DATA_CURSOR_X, as: UInt16.self),
         value(GHOSTTY_TERMINAL_DATA_CURSOR_Y, as: UInt16.self))
    }

    public var title: String { string(GHOSTTY_TERMINAL_DATA_TITLE) }

    public var pwd: String { string(GHOSTTY_TERMINAL_DATA_PWD) }

    /// Rows of scrollback above the active area.
    public var scrollbackRows: Int { value(GHOSTTY_TERMINAL_DATA_SCROLLBACK_ROWS, as: Int.self) }

    public func isEnabled(_ mode: Mode) -> Bool {
        var config = GhosttyTerminalModeConfig(mode: mode.ghostty, value: false)
        guard ghostty_terminal_get(handle, GHOSTTY_TERMINAL_DATA_MODE, &config) == GHOSTTY_SUCCESS else {
            return false
        }
        return config.value
    }

    /// The active screen and its scrollback as text, with trailing whitespace
    /// trimmed.
    public func text() throws(GhosttyError) -> String {
        var options = GhosttyFormatterTerminalOptions()
        options.size = MemoryLayout<GhosttyFormatterTerminalOptions>.size
        options.emit = GHOSTTY_FORMATTER_FORMAT_PLAIN
        options.trim = true
        options.extra.size = MemoryLayout<GhosttyFormatterTerminalExtra>.size
        options.extra.screen.size = MemoryLayout<GhosttyFormatterScreenExtra>.size
        var formatter: OpaquePointer?
        try check(ghostty_formatter_terminal_new(nil, &formatter, handle, options))
        defer { ghostty_formatter_free(formatter) }
        var pointer: UnsafeMutablePointer<UInt8>?
        var length = 0
        try check(ghostty_formatter_format_alloc(formatter, nil, &pointer, &length))
        defer { ghostty_free(nil, pointer, length) }
        guard let pointer else { return "" }
        return String(decoding: UnsafeBufferPointer(start: pointer, count: length), as: UTF8.self)
    }

    // MARK: Input encoding

    /// Encodes a key event for the program, using the terminal's current
    /// keyboard modes and Kitty keyboard flags. Empty when the key sends
    /// nothing.
    public func encode(_ event: KeyEvent, optionAsAlt: OptionAsAlt = .none) -> [UInt8] {
        ghostty_key_encoder_setopt_from_terminal(keyEncoder, handle)
        var option = optionAsAlt.ghostty
        ghostty_key_encoder_setopt(keyEncoder, GHOSTTY_KEY_ENCODER_OPT_MACOS_OPTION_AS_ALT, &option)

        let action: GhosttyKeyAction = switch event.action {
        case .press: GHOSTTY_KEY_ACTION_PRESS
        case .repeat: GHOSTTY_KEY_ACTION_REPEAT
        case .release: GHOSTTY_KEY_ACTION_RELEASE
        }
        ghostty_key_event_set_action(keyEvent, action)
        ghostty_key_event_set_key(keyEvent, event.key.ghostty)
        ghostty_key_event_set_mods(keyEvent, event.modifiers.rawValue)
        ghostty_key_event_set_consumed_mods(keyEvent, event.consumedModifiers.rawValue)
        ghostty_key_event_set_composing(keyEvent, event.composing)
        ghostty_key_event_set_unshifted_codepoint(keyEvent, event.unshiftedCodepoint?.value ?? 0)
        var text = event.text
        return text.withUTF8 { utf8 in
            // The event borrows the text, so encoding happens inside.
            utf8.withMemoryRebound(to: CChar.self) { chars in
                ghostty_key_event_set_utf8(keyEvent, chars.baseAddress, chars.count)
                defer { ghostty_key_event_set_utf8(keyEvent, nil, 0) }
                return encoded { buffer, capacity, written in
                    ghostty_key_encoder_encode(keyEncoder, keyEvent, buffer, capacity, written)
                }
            }
        }
    }

    /// Encodes a mouse event as a report for the program, per its mouse
    /// tracking mode and format. Empty when the program doesn't want it.
    public func encode(_ event: MouseEvent, geometry: MouseGeometry, anyButtonPressed: Bool) -> [UInt8] {
        if mouseModesStale {
            ghostty_mouse_encoder_setopt_from_terminal(mouseEncoder, handle)
            mouseModesStale = false
        }
        var size = GhosttyMouseEncoderSize(
            size: MemoryLayout<GhosttyMouseEncoderSize>.size,
            screen_width: geometry.screenWidth, screen_height: geometry.screenHeight,
            cell_width: geometry.cellWidth, cell_height: geometry.cellHeight,
            padding_top: geometry.paddingTop, padding_bottom: geometry.paddingBottom,
            padding_right: geometry.paddingRight, padding_left: geometry.paddingLeft)
        ghostty_mouse_encoder_setopt(mouseEncoder, GHOSTTY_MOUSE_ENCODER_OPT_SIZE, &size)
        var pressed = anyButtonPressed
        ghostty_mouse_encoder_setopt(mouseEncoder, GHOSTTY_MOUSE_ENCODER_OPT_ANY_BUTTON_PRESSED, &pressed)

        let action: GhosttyMouseAction = switch event.action {
        case .press: GHOSTTY_MOUSE_ACTION_PRESS
        case .release: GHOSTTY_MOUSE_ACTION_RELEASE
        case .motion: GHOSTTY_MOUSE_ACTION_MOTION
        }
        ghostty_mouse_event_set_action(mouseEvent, action)
        if let button = event.button {
            ghostty_mouse_event_set_button(mouseEvent, button.ghostty)
        } else {
            ghostty_mouse_event_clear_button(mouseEvent)
        }
        ghostty_mouse_event_set_mods(mouseEvent, event.modifiers.rawValue)
        ghostty_mouse_event_set_position(mouseEvent, GhosttyMousePosition(x: Float(event.x), y: Float(event.y)))
        return encoded { buffer, capacity, written in
            ghostty_mouse_encoder_encode(mouseEncoder, mouseEvent, buffer, capacity, written)
        }
    }

    /// Encodes a focus change, or nothing unless the program enabled focus
    /// reports (mode 1004).
    public func encodeFocus(_ focused: Bool) -> [UInt8] {
        guard isEnabled(.focusEvents) else { return [] }
        return encoded { buffer, capacity, written in
            ghostty_focus_encode(focused ? GHOSTTY_FOCUS_GAINED : GHOSTTY_FOCUS_LOST, buffer, capacity, written)
        }
    }

    /// Encodes pasted text, bracketed if the program enabled bracketed paste
    /// (mode 2004), with unsafe control bytes replaced.
    ///
    /// Returns nil, writing nothing, when the text could run commands the
    /// user didn't see: a line break outside a bracketed paste, or the
    /// bracketed paste terminator inside one (Ghostty's `isSafeWith`,
    /// `src/input/paste.zig`). Confirm with the user and pass `allowUnsafe`.
    public func encodePaste(_ text: String, allowUnsafe: Bool = false) -> [UInt8]? {
        let bracketed = isEnabled(.bracketedPaste)
        var data = Array(text.utf8)
        if !allowUnsafe {
            let safe = bracketed
                ? !data.contains(Array("\u{1b}[201~".utf8))
                : data.withUnsafeBufferPointer { buffer in
                    buffer.withMemoryRebound(to: CChar.self) { ghostty_paste_is_safe($0.baseAddress, $0.count) }
                }
            guard safe else { return nil }
        }
        return data.withUnsafeMutableBufferPointer { input in
            input.withMemoryRebound(to: CChar.self) { input in
                encoded { buffer, capacity, written in
                    ghostty_paste_encode(input.baseAddress, input.count, bracketed, buffer, capacity, written)
                }
            }
        }
    }

    // MARK: Rendering

    /// Makes `renderState` follow this terminal, replacing any previous one.
    package func attach(_ renderState: RenderState) {
        self.renderState = renderState
        renderState.capture(handle)
    }

    package func detach(_ renderState: RenderState) {
        if self.renderState === renderState { self.renderState = nil }
    }

    private func renderHoldChanged(_ held: Bool) {
        renderHoldGeneration += 1
        renderState?.setHeld(held, handle)
        guard held else { return }
        // The terminal has no clock, so a program that crashes mid-hold would
        // freeze the screen; end the hold after a second, as Ghostty does.
        // Setting the mode directly never fires the callback (ghostty
        // terminal.h, GhosttyTerminalRenderHoldFn "Timeouts").
        let generation = renderHoldGeneration
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            await self?.expireRenderHold(generation)
        }
    }

    private func expireRenderHold(_ generation: Int) {
        guard generation == renderHoldGeneration else { return }
        renderHoldGeneration += 1
        var mode = GhosttyTerminalModeConfig(mode: Mode.synchronizedOutput.ghostty, value: false)
        ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_MODE, &mode)
        renderState?.setHeld(false, handle)
        renderState?.capture(handle)
    }

    // MARK: Helpers

    private func value<T: FixedWidthInteger>(_ data: GhosttyTerminalData, as _: T.Type) -> T {
        var result: T = 0
        _ = ghostty_terminal_get(handle, data, &result)
        return result
    }

    private func string(_ data: GhosttyTerminalData) -> String {
        var value = GhosttyString()
        guard ghostty_terminal_get(handle, data, &value) == GHOSTTY_SUCCESS else { return "" }
        return String(ghostty: value)
    }
}

/// Runs a libghostty-vt encoder into a stack buffer, retrying once with the
/// size it asks for when the output doesn't fit.
private func encoded(
    _ encode: (UnsafeMutablePointer<CChar>?, Int, UnsafeMutablePointer<Int>) -> GhosttyResult
) -> [UInt8] {
    var written = 0
    var output = [UInt8](repeating: 0, count: 128)
    var result = output.withUnsafeMutableBufferPointer { buffer in
        buffer.withMemoryRebound(to: CChar.self) { encode($0.baseAddress, $0.count, &written) }
    }
    if result == GHOSTTY_OUT_OF_SPACE {
        output = [UInt8](repeating: 0, count: written)
        result = output.withUnsafeMutableBufferPointer { buffer in
            buffer.withMemoryRebound(to: CChar.self) { encode($0.baseAddress, $0.count, &written) }
        }
    }
    guard result == GHOSTTY_SUCCESS else { return [] }
    return Array(output.prefix(written))
}
